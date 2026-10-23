using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;

namespace Quili.Platform
{
    /// <summary>
    /// Turns the text runs of one container of a captured Slack thread into a line, marking message headers so the
    /// summarizer can tell who said what. A header is the author's name followed by its time ("Rahman Just now",
    /// "Deka Dwi 20 minutes ago"); it is written <c>Author [time]</c>, and the message text follows on the lines below.
    /// Slack's accessibility tree has no font weight to measure, so the header is recognised by its shape instead: a few
    /// short runs, then a run that is a time, with the time not first (a lone "15:21" is a hover time, not a header), and
    /// the name coming from a button (Slack makes author names buttons) or at least looking like a name.
    /// </summary>
    static class ThreadFormat
    {
        /// <summary>The author part may be a name plus a status or badge, but never a long run of text.</summary>
        const int MaxNameRuns = 3, MaxNameLength = 100;

        /// <summary>Times as Slack shows them (lowercased): "just now", "22 minutes ago", "2:53 pm", "14:08", "yesterday at 14:08".</summary>
        static readonly Regex TimePattern = new(
            @"^(just now|(yesterday|today)( at .+)?|\d+ (second|minute|hour|day|week|month|year)s? ago|\d{1,2}:\d{2}(\s?[ap]m)?|(mon|tue|wed|thu|fri|sat|sun)[a-z]*( at .+)?|[a-z]{3,9} \d{1,2}(st|nd|rd|th)?(,? \d{4})?( at .+)?)$",
            RegexOptions.Compiled);

        public static bool IsTime(string run) => TimePattern.IsMatch(run.ToLowerInvariant());

        /// <summary>Capitalised words, so a message fragment such as "see you at" is not mistaken for an author.</summary>
        static bool LooksLikeName(string text)
        {
            var words = text.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            return words.Length <= 6 && words.All(w => !char.IsLetter(w[0]) || char.IsUpper(w[0]));
        }

        /// <summary>A line that starts a message: <c>Author [time]</c>, optionally followed by the first words of the message.</summary>
        public static bool IsHeader(string line)
        {
            int open = line.IndexOf(" [", StringComparison.Ordinal);
            if (open < 1 || open > MaxNameLength) return false;
            int close = line.IndexOf(']', open + 2);
            return close > 0 && IsTime(line.Substring(open + 2, close - open - 2));
        }

        /// <summary>
        /// The lines as one string per message, each wrapped in <c>{{</c> and <c>}}</c>: a message runs from its header line
        /// to the next header. Braces inside a message are escaped (<c>\{</c>, <c>\}</c>) so they cannot be mistaken for the
        /// wrapper. Lines before the first header (no known author) form a message of their own.
        /// </summary>
        public static List<string> Messages(IEnumerable<string> lines)
        {
            var groups = new List<List<string>>();
            foreach (var line in lines)
            {
                if (groups.Count == 0 || IsHeader(line)) groups.Add(new List<string>());
                groups[^1].Add(line.Replace("{", "\\{").Replace("}", "\\}"));
            }
            return groups.Select(g => "{{" + string.Join("\n", g) + "}}").ToList();
        }

        /// <summary>
        /// One line for <paramref name="runs"/> (already trimmed, non-empty), as a header when it has the shape of one.
        /// <paramref name="firstIsButton"/> says the first run came from a button, which is how Slack renders an author's name.
        /// </summary>
        public static string Line(IReadOnlyList<string> allRuns, bool firstIsButton)
        {
            // "Also sent to the channel" is a label above the author's name, not part of it.
            var runs = allRuns.Where(r => !r.Equals("also sent to the channel", StringComparison.OrdinalIgnoreCase)).ToList();
            if (runs.Count == 0) return string.Join(" ", allRuns);
            int t = -1;
            for (int i = 0; i < runs.Count; i++)
                if (IsTime(runs[i])) { t = i; break; }
            if (t < 1 || t > MaxNameRuns || runs[0].StartsWith("@")) return string.Join(" ", runs);

            var name = string.Join(" ", runs.Take(t));
            if (name.Length > MaxNameLength || !(firstIsButton || LooksLikeName(name))) return string.Join(" ", runs);
            var rest = string.Join(" ", runs.Skip(t + 1));
            return $"{name} [{runs[t]}]" + (rest.Length == 0 ? "" : $" {rest}");
        }
    }
}
