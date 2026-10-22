using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Text.RegularExpressions;
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
    /// reader's own log lines record counts and control types only; the controller writes the thread text to the debug
    /// log when a summary is requested.
    /// </summary>
    public static class ThreadReader
    {
        public const string SlackProcessName = "slack";

        /// <summary>Under the server's SUMMARIZE_MAX_CHARS (40000).</summary>
        public const int MaxChars = 38_000;

        const int MaxNodes = 25_000, MaxDepth = 60, MinLines = 3;
        /// <summary>Around Slack's own button the header (title, channel name) holds a few lines too, so ask for more.</summary>
        const int ButtonRegionLines = 6;
        static readonly TimeSpan TimeLimit = TimeSpan.FromSeconds(6);
        /// <summary>Scrolling the pane to read all of a long thread: how far each step goes (of the visible part), the most steps, and the time allowed.</summary>
        const double ScrollStepFraction = 0.7;
        const int MaxScrollSteps = 40;
        static readonly TimeSpan ScrollTimeLimit = TimeSpan.FromSeconds(15);

        /// <summary>
        /// Control types that carry no conversation text; their subtrees are skipped. Buttons are handled separately:
        /// Slack makes author names buttons, so their label is kept unless it is a known interface button.
        /// </summary>
        static readonly HashSet<ControlType> Skipped = new()
        {
            ControlType.Image, ControlType.ScrollBar, ControlType.Menu, ControlType.MenuItem,
            ControlType.SplitButton, ControlType.CheckBox, ControlType.RadioButton, ControlType.Slider,
            ControlType.ProgressBar, ControlType.TabItem,
        };

        sealed class Budget
        {
            int _nodes;
            readonly DateTime _deadline;
            public Budget(int nodes = MaxNodes, TimeSpan? limit = null)
            {
                _nodes = nodes;
                _deadline = DateTime.UtcNow + (limit ?? TimeLimit);
            }
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

        /// <summary>
        /// Slack's own "Summarize thread" button, which the floating Summarize button goes beside; its presence is
        /// what says a thread is open. Screen pixels.
        /// </summary>
        public sealed record Anchor(AutomationElement Element, System.Windows.Rect Bounds);

        /// <summary>
        /// Slack's "Summarize thread" button in its window, null when no thread is open. Cheap enough to poll: a
        /// still-valid <paramref name="cached"/> button is just re-measured. A fresh search finds the thread pane first
        /// (a group labelled "Thread", quick to reach) and then looks for the button inside it with its own budget and a
        /// looser match; with no pane it looks for the exact button anywhere in the window. When nothing is found it logs
        /// the names of the buttons in the header, so an unexpected Slack layout can be diagnosed from the log.
        /// </summary>
        public static Anchor? DetectAnchor(IntPtr hwnd, Anchor? cached)
        {
            try
            {
                if (cached != null && LiveBounds(cached.Element) is System.Windows.Rect live) return new Anchor(cached.Element, live);
                var window = AutomationElement.FromHandle(hwnd);
                var (pane, button) = Scan(window, new Budget(12_000, TimeSpan.FromSeconds(2.5)), stopAtPane: true);
                if (button != null && LiveBounds(button) is System.Windows.Rect found) return new Anchor(button, found);
                if (pane != null)
                {
                    var inner = FindSummarizeButton(pane, new Budget(6_000, TimeSpan.FromSeconds(1.5)), loose: true);
                    if (inner != null && LiveBounds(inner) is System.Windows.Rect inside) return new Anchor(inner, inside);
                    Diagnose(pane, "thread pane");
                }
                else Diagnose(window, "window");
            }
            catch (Exception) { }
            return null;
        }

        /// <summary>The button's bounds while the element is still alive and on screen. Slack's is a small icon button, so only reject slivers.</summary>
        static System.Windows.Rect? LiveBounds(AutomationElement button)
        {
            try
            {
                var r = button.Current.BoundingRectangle;
                if (r.IsEmpty || r.Width < 12 || r.Height < 12 || button.Current.IsOffscreen) return null;
                return r;
            }
            catch (Exception) { return null; }
        }

        static bool IsButton(ControlType type) => type == ControlType.Button || type == ControlType.SplitButton;

        /// <summary>
        /// Breadth-first search under <paramref name="root"/> for Slack's "Summarize thread" button. <paramref name="loose"/>
        /// (used inside the thread pane, where the context already says it is a thread) accepts any button named "summarize".
        /// </summary>
        static AutomationElement? FindSummarizeButton(AutomationElement root, Budget budget, bool loose = false)
        {
            var queue = new Queue<AutomationElement>();
            queue.Enqueue(root);
            while (queue.Count > 0 && budget.Spend())
            {
                var el = queue.Dequeue();
                try
                {
                    if (IsButton(el.Current.ControlType) && IsSummarizeButton(el, loose)) return el;
                }
                catch (Exception) { continue; }
                foreach (var child in Children(el)) queue.Enqueue(child);
            }
            return null;
        }

        static DateTime _lastDiagnosis = DateTime.MinValue;

        /// <summary>
        /// Logs (at most every 20 s) the buttons near the top of <paramref name="root"/> as type|name|help|id|size, so the
        /// log shows how Slack names its header buttons. Only controls in the header strip are listed, never message text.
        /// </summary>
        static void Diagnose(AutomationElement root, string what)
        {
            if (DateTime.UtcNow - _lastDiagnosis < TimeSpan.FromSeconds(20)) return;
            _lastDiagnosis = DateTime.UtcNow;
            static string Cut(string? s) => (s ?? "").Substring(0, Math.Min(30, (s ?? "").Length)).Replace("|", "/");
            double top;
            try { top = root.Current.BoundingRectangle.Top; } catch (Exception) { return; }

            var budget = new Budget(4_000, TimeSpan.FromSeconds(1));
            var queue = new Queue<AutomationElement>();
            queue.Enqueue(root);
            var entries = new List<string>();
            while (queue.Count > 0 && budget.Spend() && entries.Count < 24)
            {
                var el = queue.Dequeue();
                try
                {
                    var type = el.Current.ControlType;
                    var r = el.Current.BoundingRectangle;
                    if ((IsButton(type) || type == ControlType.Hyperlink) && !r.IsEmpty && r.Top - top < 140)
                        entries.Add($"{type.ProgrammaticName.Replace("ControlType.", "")}|{Cut(el.Current.Name)}|{Cut(el.Current.HelpText)}|" +
                                    $"{Cut(el.Current.AutomationId)}|{(int)r.Width}x{(int)r.Height}");
                }
                catch (Exception) { continue; }
                foreach (var child in Children(el)) queue.Enqueue(child);
            }
            DebugLog.Write($"thread: no Summarize thread button in the {what}; header controls: {(entries.Count == 0 ? "none" : string.Join(" ; ", entries))}");
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
                    if (f != null && f.Current.ProcessId == slackPid)
                    {
                        // Only the message box (an edit field) is left out of the text. Slack can focus a message in
                        // the thread pane, and skipping that would drop it: the parent message went missing that way.
                        if (f.Current.ControlType == ControlType.Edit) focused = f;
                        else DebugLog.Write($"thread: focused element is {f.Current.ControlType.ProgrammaticName.Replace("ControlType.", "")}, not a message box; kept in the text");
                    }
                }
                catch (Exception) { }

                var budget = new Budget();
                var (pane, button) = Scan(window, budget);
                List<string>? lines = null;
                AutomationElement? root = null; // the element the lines were read from
                string how = "group";
                if (button != null && (lines = RegionAround(button, focused, window, ButtonRegionLines, out root)) != null)
                {
                    how = "around Slack's Summarize thread button";
                    (lines, root) = Widen(lines, root!, focused, window);
                }
                else if (pane != null) { lines = Collect(pane, focused); root = pane; }
                else if ((lines = RegionAround(focused, focused, window, MinLines, out root)) != null) how = "around the message box";
                else
                {
                    DebugLog.Write($"thread: no thread pane found; structure {Structure(window, 0)}");
                    return null;
                }

                lines = Cleaned(lines!);
                DebugLog.Write($"thread: read {lines.Count} lines via {how}");
                if (root != null && lines.Count > 0) lines = GatherByScrolling(root, focused, lines);
                if (root != null && DebugLog.Enabled) DebugLog.Write($"thread structure (control types and text lengths only):\n{Outline(root, 0, new[] { 250 })}");
                if (lines.Count == 0) return null;

                // One {{ ... }} group per message; keep the newest messages when the thread is longer than the server accepts.
                var messages = ThreadFormat.Messages(lines);
                int total = messages.Sum(m => m.Length + 2), dropped = 0; // plus the blank line between messages
                while (total > MaxChars && dropped < messages.Count - 1)
                {
                    total -= messages[dropped].Length + 2;
                    dropped++;
                }
                if (dropped > 0) DebugLog.Write($"thread: dropped the oldest {dropped} messages to fit {MaxChars} chars");
                return new ThreadText(string.Join("\n\n", messages.Skip(dropped)), dropped > 0);
            }
            catch (Exception ex)
            {
                DebugLog.Write($"thread: read failed: {ex.GetType().Name}: {ex.Message}");
                return null;
            }
        }

        // ---- Finding the thread ----

        /// <summary>
        /// One breadth-first pass over the window for the thread pane (a group/pane labelled "Thread", or the
        /// Indonesian "Utas") and Slack's own "Summarize thread" button. The pane is an ancestor of the button, so it
        /// has been seen by the time the button turns up, and the search stops there.
        /// </summary>
        static (AutomationElement? Pane, AutomationElement? Button) Scan(AutomationElement window, Budget budget, bool stopAtPane = false)
        {
            AutomationElement? pane = null;
            var queue = new Queue<AutomationElement>();
            queue.Enqueue(window);
            while (queue.Count > 0 && budget.Spend())
            {
                var el = queue.Dequeue();
                try
                {
                    var type = el.Current.ControlType;
                    if (pane == null && (type == ControlType.Group || type == ControlType.Pane || type == ControlType.Custom))
                    {
                        var label = (el.Current.Name ?? "").ToLowerInvariant();
                        if (HasWord(label, "thread") || HasWord(label, "utas"))
                        {
                            pane = el;
                            if (stopAtPane) return (el, null);
                        }
                    }
                    if (IsButton(type) && IsSummarizeButton(el)) return (pane, el);
                }
                catch (Exception) { continue; }
                foreach (var child in Children(el)) queue.Enqueue(child);
            }
            return (pane, null);
        }

        /// <summary>
        /// Whether <paramref name="text"/> (lowercased) contains <paramref name="word"/> as a whole word, so "thread" matches
        /// "Thread" and "Thread in #general" but not Slack's "Threads" view.
        /// </summary>
        static bool HasWord(string text, string word) =>
            System.Text.RegularExpressions.Regex.IsMatch(text, $@"(?<![\p{{L}}\p{{N}}]){word}(?![\p{{L}}\p{{N}}])");

        /// <summary>
        /// Slack's own "Summarize thread" button: a short name saying so, on the button or on a direct child (the text
        /// inside it). Only buttons count, so a message that happens to say "summarize thread" can't match.
        /// </summary>
        static bool IsSummarizeButton(AutomationElement button, bool loose = false)
        {
            bool Matches(AutomationElement el)
            {
                var label = $"{el.Current.Name} {el.Current.HelpText} {el.Current.AutomationId}".ToLowerInvariant();
                if (label.Length > 80) return false;
                if (loose) return label.Contains("summar") || label.Contains("ringkas");
                return (label.Contains("summar") && HasWord(label, "thread")) || (label.Contains("ringkas") && HasWord(label, "utas"));
            }
            try
            {
                if (Matches(button)) return true;
                foreach (var child in Children(button)) if (Matches(child)) return true;
            }
            catch (Exception) { }
            return false;
        }

        /// <summary>Fallback: climbs from <paramref name="start"/> to the smallest enclosing region with at least <paramref name="minLines"/> lines of text.</summary>
        static List<string>? RegionAround(AutomationElement? start, AutomationElement? skip, AutomationElement window, int minLines,
            out AutomationElement? region)
        {
            region = null;
            if (start == null) return null;
            var el = start;
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
                var lines = Collect(el, skip);
                if (lines.Count >= minLines) { region = el; return lines; }
            }
            return null;
        }

        /// <summary>
        /// The thread's first message (the one that started it) sits above the replies, often in a sibling of the smallest
        /// region that holds several lines. So keep climbing while the ancestor is still a side pane (at most 60% of the
        /// window wide), and read from the widest one; the channel list and the main conversation are wider than that.
        /// </summary>
        static (List<string> Lines, AutomationElement Region) Widen(List<string> lines, AutomationElement region,
            AutomationElement? skip, AutomationElement window)
        {
            double windowWidth;
            try { windowWidth = window.Current.BoundingRectangle.Width; } catch (Exception) { return (lines, region); }
            if (!(windowWidth > 0)) return (lines, region);
            var best = (Lines: lines, Region: region);
            var el = region;
            for (int i = 0; i < 8; i++)
            {
                try
                {
                    var up = TreeWalker.ControlViewWalker.GetParent(el);
                    if (up == null) break;
                    el = up;
                    if (el.Current.ControlType == ControlType.Document || Automation.Compare(el, window)) break;
                    if (el.Current.BoundingRectangle.Width > windowWidth * 0.6) break;
                }
                catch (Exception) { break; }
                var more = Collect(el, skip);
                if (more.Count >= best.Lines.Count) best = (more, el);
            }
            if (!ReferenceEquals(best.Region, region) && best.Lines.Count != lines.Count)
                DebugLog.Write($"thread: widened the region from {lines.Count} to {best.Lines.Count} lines");
            return best;
        }

        // ---- Scrolling ----

        /// <summary>
        /// Slack (Chromium) only puts the messages near the viewport into the UI Automation tree, so a long thread has to be
        /// scrolled through. This scrolls the pane (UIA ScrollPattern) to its top, reads a screenful, scrolls down a step at
        /// a time reading each, merges the views by their overlap and scrolls back to the top when done. Any
        /// problem (no scrollable element, no overlap) just leaves what was read.
        /// </summary>
        static List<string> GatherByScrolling(AutomationElement root, AutomationElement? skip, List<string> visible)
        {
            var scroller = FindScroller(root, out var pattern);
            if (scroller == null || pattern == null) return visible;
            var deadline = DateTime.UtcNow + ScrollTimeLimit;
            bool Scroll(double percent)
            {
                try { pattern.SetScrollPercent(ScrollPattern.NoScroll, Math.Max(0, Math.Min(100, percent))); return true; }
                catch (Exception) { return false; }
            }
            double Percent()
            {
                try { return pattern.Current.VerticalScrollPercent; } catch (Exception) { return 100; }
            }
            // The view once scrolling has settled (rendering takes a moment).
            List<string> SettledView()
            {
                List<string>? previous = null;
                for (int i = 0; i < 8; i++)
                {
                    System.Threading.Thread.Sleep(120);
                    var view = Cleaned(Collect(root, skip));
                    if (previous != null && SameView(previous, view)) return view;
                    previous = view;
                }
                return previous ?? new List<string>();
            }

            try
            {
                // One step is a fraction of what is visible, as a share of the whole scroll range.
                double viewSize = pattern.Current.VerticalViewSize; // percent of the content that is visible
                if (viewSize <= 0 || viewSize >= 100) return visible;
                double step = viewSize * ScrollStepFraction / (100 - viewSize) * 100;

                if (!Scroll(0)) return visible;
                var current = SettledView();
                if (current.Count == 0) return visible;
                var all = current;
                int steps = 0, retries = 0;
                while (steps < MaxScrollSteps && DateTime.UtcNow < deadline)
                {
                    double from = Percent();
                    if (from >= 99.9) break; // the bottom
                    if (!Scroll(from + step)) break;
                    var next = SettledView();
                    if (next.Count == 0 || SameView(next, current)) break;
                    var (merged, overlapped) = Merge(all, next);
                    if (overlapped || retries >= 4)
                    {
                        all = merged;
                        current = next;
                        steps++;
                    }
                    else
                    {
                        // The step jumped past what was read: go back and take smaller ones.
                        retries++;
                        Scroll(from);
                        SettledView();
                        step = Math.Max(1, step / 2);
                    }
                }
                DebugLog.Write($"thread: scrolled {steps} steps; {visible.Count} -> {all.Count} lines");
                return all;
            }
            catch (Exception ex)
            {
                DebugLog.Write($"thread: scrolling failed: {ex.GetType().Name}");
                return visible;
            }
            finally
            {
                Scroll(0); // done: back to the top, where the thread starts
            }
        }

        /// <summary>The vertically scrollable element in the pane (the tallest one), with its ScrollPattern.</summary>
        static AutomationElement? FindScroller(AutomationElement root, out ScrollPattern? pattern)
        {
            pattern = null;
            AutomationElement? best = null;
            double bestHeight = 0;
            var queue = new Queue<AutomationElement>();
            queue.Enqueue(root);
            for (int seen = 0; queue.Count > 0 && seen < 2000; seen++)
            {
                var el = queue.Dequeue();
                try
                {
                    if (el.TryGetCurrentPattern(ScrollPattern.Pattern, out var p) && p is ScrollPattern sp
                        && sp.Current.VerticallyScrollable && el.Current.BoundingRectangle.Height > bestHeight)
                    {
                        best = el;
                        pattern = sp;
                        bestHeight = el.Current.BoundingRectangle.Height;
                    }
                }
                catch (Exception) { }
                foreach (var child in Children(el)) queue.Enqueue(child);
            }
            return best;
        }

        /// <summary>Lines as compared across views: a message's relative time ("32 minutes ago") may roll over while scrolling.</summary>
        static string Normalized(string line) => Regex.Replace(line, @" \[[^\]]*\]", "");

        static bool SameView(List<string> a, List<string> b) =>
            a.Count == b.Count && a.Zip(b, (x, y) => Normalized(x) == Normalized(y)).All(same => same);

        /// <summary><paramref name="next"/> appended to <paramref name="all"/> without the lines they share: the longest tail of <paramref name="all"/> that is also the head of <paramref name="next"/>.</summary>
        static (List<string> Lines, bool Overlapped) Merge(List<string> all, List<string> next)
        {
            var a = all.Select(Normalized).ToList();
            var n = next.Select(Normalized).ToList();
            int k = Math.Min(a.Count, n.Count);
            while (k > 0 && !a.Skip(a.Count - k).SequenceEqual(n.Take(k))) k--;
            return (all.Concat(next.Skip(k)).ToList(), k > 0);
        }

        /// <summary>One read's lines with duplicates, interface chrome and the pane's title line removed.</summary>
        static List<string> Cleaned(List<string> lines)
        {
            var result = Dedupe(lines).Where(l => !ThreadNoise.IsInterfaceLine(l)).ToList();
            if (result.Count > 0 && ThreadNoise.IsPaneTitle(result[0])) result.RemoveAt(0);
            return result;
        }

        // ---- Collecting text ----

        /// <summary>Text runs under <paramref name="root"/> in document order, one line per container. Skips the message box and controls.</summary>
        static List<string> Collect(AutomationElement root, AutomationElement? skip)
        {
            var budget = new Budget();
            var lines = new List<string>();
            var runs = new List<string>();
            bool firstIsButton = false; // whether the first run of the current line came from a button (an author's name)

            void Flush()
            {
                if (runs.Count > 0) lines.Add(ThreadFormat.Line(runs, firstIsButton));
                runs.Clear();
            }

            void Visit(AutomationElement el, int depth)
            {
                if (depth >= MaxDepth || !budget.Spend()) return;
                try
                {
                    if (skip != null && Automation.Compare(el, skip)) return;
                    var type = el.Current.ControlType;
                    if (type == ControlType.Button)
                    {
                        var label = ButtonLabel(el);
                        if (label != null && !ThreadNoise.IsInterfaceButton(label))
                        {
                            if (runs.Count == 0) firstIsButton = true;
                            runs.Add(label);
                        }
                        return;
                    }
                    if (Skipped.Contains(type)) return;
                    // An editable field is a message box, not part of the conversation.
                    if (type == ControlType.Edit && IsEditable(el)) return;

                    var kids = Children(el);
                    if (kids.Count == 0)
                    {
                        var text = LeafText(el, type);
                        if (text != null)
                        {
                            if (runs.Count == 0) firstIsButton = false;
                            runs.Add(text);
                        }
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

        /// <summary>A button's label: its own name, else the text inside it (Slack's author names are buttons).</summary>
        static string? ButtonLabel(AutomationElement button)
        {
            static string? Clean(string? s)
            {
                var t = s?.Trim();
                return string.IsNullOrEmpty(t) || t.Length > 300 ? null : t;
            }
            var own = Clean(button.Current.Name);
            if (own != null) return own;
            foreach (var child in Children(button))
            {
                var inner = Clean(child.Current.Name);
                if (inner != null) return inner;
            }
            return null;
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

        /// <summary>
        /// The tree under <paramref name="el"/> as indented lines (control type, child count, and the length of the name):
        /// enough to see what a message is made of and what the reader skipped, without any message text.
        /// <paramref name="budget"/>[0] is the number of lines still allowed.
        /// </summary>
        static string Outline(AutomationElement el, int depth, int[] budget)
        {
            if (budget[0] <= 0 || depth > 16) return "";
            budget[0]--;
            string type, name;
            List<AutomationElement> kids;
            try
            {
                type = el.Current.ControlType.ProgrammaticName.Replace("ControlType.", "");
                name = (el.Current.Name ?? "").Length.ToString();
                kids = Children(el);
            }
            catch (Exception) { return ""; }
            var sb = new System.Text.StringBuilder();
            sb.Append(new string(' ', depth)).Append(type).Append(" kids=").Append(kids.Count).Append(" name=").Append(name).Append('\n');
            foreach (var kid in kids) sb.Append(Outline(kid, depth + 1, budget));
            return sb.ToString().TrimEnd('\n');
        }

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
