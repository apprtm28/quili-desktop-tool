using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Windows.Automation;
using Quili.Core;

namespace Quili.Platform
{
    /// <summary>The visible text of the chat thread open in a Slack window. Truncated: older lines were dropped to stay under the server's size cap.</summary>
    public sealed record ThreadText(string Text, bool Truncated);

    /// <summary>
    /// Reads the thread pane of the Slack desktop app (an Electron app, so its web content is exposed through UI
    /// Automation once an accessibility client is detected). Nothing is written to Slack and no Slack API or token
    /// is involved: it sees only what the window renders. Runs off the UI thread: UIA calls into another process
    /// can be slow.
    ///
    /// Slack's tree is not documented, so the reader is defensive: it looks for a group labelled "thread", and
    /// otherwise takes the smallest region around the focused message box that holds several lines of text. The
    /// debug log records counts and control types only, never message text.
    /// </summary>
    public static class ThreadReader
    {
        public const string SlackProcessName = "slack";

        /// <summary>Under the server's SUMMARIZE_MAX_CHARS (40000).</summary>
        public const int MaxChars = 38_000;

        const int MaxNodes = 25_000, MaxDepth = 60, MinLines = 3;
        static readonly TimeSpan TimeLimit = TimeSpan.FromSeconds(6);

        /// <summary>Control types that carry no conversation text; their subtrees are skipped.</summary>
        static readonly HashSet<ControlType> Skipped = new()
        {
            ControlType.Button, ControlType.Image, ControlType.ScrollBar, ControlType.Menu, ControlType.MenuItem,
            ControlType.SplitButton, ControlType.CheckBox, ControlType.RadioButton, ControlType.Slider,
            ControlType.ProgressBar, ControlType.TabItem,
        };

        sealed class Budget
        {
            int _nodes = MaxNodes;
            readonly DateTime _deadline = DateTime.UtcNow + TimeLimit;
            public bool Spend() => --_nodes > 0 && DateTime.UtcNow < _deadline;
        }

        public static bool IsSlack(IntPtr hwnd)
        {
            try
            {
                Native.GetWindowThreadProcessId(hwnd, out var pid);
                if (pid == 0) return false;
                using var process = Process.GetProcessById((int)pid);
                return string.Equals(process.ProcessName, SlackProcessName, StringComparison.OrdinalIgnoreCase);
            }
            catch (Exception) { return false; }
        }

        public static ThreadText? Read(IntPtr hwnd)
        {
            try
            {
                var window = AutomationElement.FromHandle(hwnd);
                int slackPid = window.Current.ProcessId;
                AutomationElement? focused = null;
                try
                {
                    // Only a message box in Slack itself is of use; focus may sit in the taskbar after a tray click.
                    var f = AutomationElement.FocusedElement;
                    if (f != null && f.Current.ProcessId == slackPid) focused = f;
                }
                catch (Exception) { }

                var budget = new Budget();
                List<string>? lines;
                string how = "group";
                var pane = FindThreadPane(window, budget);
                if (pane != null) lines = Collect(pane, focused);
                else if ((lines = RegionAround(focused, window)) != null) how = "around the message box";
                else
                {
                    DebugLog.Write($"thread: no thread pane found; structure {Structure(window, 0)}");
                    return null;
                }

                lines = Dedupe(lines!);
                DebugLog.Write($"thread: read {lines.Count} lines via {how}");
                if (lines.Count == 0) return null;

                // Keep the newest messages when the thread is longer than the server accepts.
                int total = lines.Sum(l => l.Length + 1), dropped = 0;
                while (total > MaxChars && dropped < lines.Count - 1)
                {
                    total -= lines[dropped].Length + 1;
                    dropped++;
                }
                if (dropped > 0) DebugLog.Write($"thread: dropped the oldest {dropped} lines to fit {MaxChars} chars");
                return new ThreadText(string.Join("\n", lines.Skip(dropped)), dropped > 0);
            }
            catch (Exception ex)
            {
                DebugLog.Write($"thread: read failed: {ex.GetType().Name}: {ex.Message}");
                return null;
            }
        }

        // ---- Finding the thread pane ----

        /// <summary>A group/pane whose label says "Thread" (or the Indonesian "Utas").</summary>
        static AutomationElement? FindThreadPane(AutomationElement window, Budget budget)
        {
            var queue = new Queue<AutomationElement>();
            queue.Enqueue(window);
            while (queue.Count > 0 && budget.Spend())
            {
                var el = queue.Dequeue();
                try
                {
                    var type = el.Current.ControlType;
                    if (type == ControlType.Group || type == ControlType.Pane || type == ControlType.Custom)
                    {
                        var label = (el.Current.Name ?? "").ToLowerInvariant();
                        if (label.Contains("thread") || label.Contains("utas")) return el;
                    }
                }
                catch (Exception) { continue; }
                foreach (var child in Children(el)) queue.Enqueue(child);
            }
            return null;
        }

        /// <summary>Fallback: climbs from the focused message box to the smallest enclosing region with enough text.</summary>
        static List<string>? RegionAround(AutomationElement? focused, AutomationElement window)
        {
            if (focused == null) return null;
            var el = focused;
            for (int i = 0; i < 14; i++)
            {
                AutomationElement? up;
                try { up = TreeWalker.ControlViewWalker.GetParent(el); } catch (Exception) { return null; }
                if (up == null) return null;
                el = up;
                try
                {
                    if (el.Current.ControlType == ControlType.Document || Automation.Compare(el, window)) return null;
                }
                catch (Exception) { return null; }
                var lines = Collect(el, focused);
                if (lines.Count >= MinLines) return lines;
            }
            return null;
        }

        // ---- Collecting text ----

        /// <summary>Text runs under <paramref name="root"/> in document order, one line per container. Skips the message box and controls.</summary>
        static List<string> Collect(AutomationElement root, AutomationElement? skip)
        {
            var budget = new Budget();
            var lines = new List<string>();
            var runs = new List<string>();

            void Flush()
            {
                var line = string.Join(" ", runs).Trim();
                if (line.Length > 0) lines.Add(line);
                runs.Clear();
            }

            void Visit(AutomationElement el, int depth)
            {
                if (depth >= MaxDepth || !budget.Spend()) return;
                try
                {
                    if (skip != null && Automation.Compare(el, skip)) return;
                    var type = el.Current.ControlType;
                    if (Skipped.Contains(type)) return;
                    // An editable field is a message box, not part of the conversation.
                    if (type == ControlType.Edit && IsEditable(el)) return;

                    var kids = Children(el);
                    if (kids.Count == 0)
                    {
                        var text = LeafText(el, type);
                        if (text != null) runs.Add(text);
                        return;
                    }
                    foreach (var kid in kids) Visit(kid, depth + 1);
                    Flush();
                }
                catch (Exception) { /* element vanished mid-walk */ }
            }

            Visit(root, 0);
            Flush();
            return lines;
        }

        static bool IsEditable(AutomationElement el)
        {
            if (!el.TryGetCurrentPattern(ValuePattern.Pattern, out var vp)) return true;
            return !((ValuePattern)vp).Current.IsReadOnly;
        }

        /// <summary>The text of an element without children: static text, or a link or heading such as an author name or timestamp.</summary>
        static string? LeafText(AutomationElement el, ControlType type)
        {
            string? text = null;
            if (type == ControlType.Text || type == ControlType.Edit || type == ControlType.Document)
            {
                text = el.Current.Name;
                if (string.IsNullOrWhiteSpace(text) && el.TryGetCurrentPattern(ValuePattern.Pattern, out var vp))
                    text = ((ValuePattern)vp).Current.Value;
            }
            else if (type == ControlType.Hyperlink || type == ControlType.Header || type == ControlType.Group)
            {
                text = el.Current.Name;
            }
            return string.IsNullOrWhiteSpace(text) ? null : text.Trim();
        }

        static List<AutomationElement> Children(AutomationElement el)
        {
            var list = new List<AutomationElement>();
            try
            {
                for (var c = TreeWalker.ControlViewWalker.GetFirstChild(el); c != null; c = TreeWalker.ControlViewWalker.GetNextSibling(c))
                    list.Add(c);
            }
            catch (Exception) { /* element vanished mid-walk */ }
            return list;
        }

        /// <summary>Chromium often exposes a link's name and its text child separately, so adjacent duplicates are dropped.</summary>
        static List<string> Dedupe(List<string> lines)
        {
            var output = new List<string>();
            foreach (var line in lines)
                if (output.Count == 0 || output[^1] != line) output.Add(line);
            return output;
        }

        // ---- Debugging ----

        /// <summary>Control types only (no text), a few levels deep, so an unexpected Slack layout can be diagnosed from the log.</summary>
        static string Structure(AutomationElement el, int depth, int maxLevels = 5)
        {
            string name;
            try { name = el.Current.ControlType.ProgrammaticName.Replace("ControlType.", ""); }
            catch (Exception) { return "?"; }
            if (depth >= maxLevels) return name;
            var kids = Children(el);
            if (kids.Count == 0) return name;
            var shown = kids.Take(8).Select(k => Structure(k, depth + 1, maxLevels));
            return $"{name}[{string.Join(",", shown)}{(kids.Count > 8 ? $",+{kids.Count - 8}" : "")}]";
        }
    }
}
