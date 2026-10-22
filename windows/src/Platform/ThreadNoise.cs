using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;

namespace Quili.Platform
{
    /// <summary>
    /// What is dropped from a captured Slack thread: interface controls and chrome that are not conversation text.
    /// Two lists, applied in two places. Buttons are filtered while reading (Slack makes author names buttons too, so a
    /// button is kept unless its label is listed here), which also stops merged lines such as "Open in channel Add to-do"
    /// from forming. Lines are filtered afterwards, for chrome that arrives as plain text. Both are deliberately narrow: a
    /// real message must never be dropped.
    /// </summary>
    static class ThreadNoise
    {
        // ---- Buttons ----

        /// <summary>Labels that are noise only as the whole label (a lone word that could be part of a real name).</summary>
        static readonly HashSet<string> ExactButtons = new() { "reply", "close" };

        /// <summary>Fragments that mark a button as interface wherever they appear in its label (all lowercase).</summary>
        static readonly string[] ButtonFragments =
        {
            "summariz", "more actions", "add reaction", "reaction", "download", "forward", "save for later", "copy link",
            "also send to", "add to-do", "open in channel", "emoji", "mention someone", "record video clip",
            "record audio clip", "run shortcut", "send now",
        };

        public static bool IsInterfaceButton(string label)
        {
            var t = label.ToLowerInvariant();
            return ExactButtons.Contains(t) || ButtonFragments.Any(t.Contains);
        }

        // ---- Lines ----

        /// <summary>Whole lines that are noise (all lowercase).</summary>
        static readonly HashSet<string> ExactLines = new()
        {
            "thread", "reply…", "reply...", "add to-do", "send now",
            "emoji mention someone record video clip record audio clip run shortcut",
        };

        /// <summary>Lines that are noise by shape: "4 replies New", "Also send to #channel", "Download file.png".</summary>
        static readonly Regex[] LinePatterns =
        {
            new(@"^\d+ repl(y|ies)\b.*$", RegexOptions.Compiled),
            new(@"^also send to .+$", RegexOptions.Compiled),
            new(@"^download .+\.[a-z0-9]{1,5}$", RegexOptions.Compiled),
        };

        static readonly Regex PaneTitle = new(@"^(thread|utas) \S{1,60}$", RegexOptions.Compiled);

        /// <summary>The pane's title line, "Thread dbagroup" (or "Utas dbagroup"): the label and the channel name, not a message.</summary>
        public static bool IsPaneTitle(string line) => PaneTitle.IsMatch(line.Trim().ToLowerInvariant());

        public static bool IsInterfaceLine(string line)
        {
            var t = line.Trim().ToLowerInvariant();
            return ExactLines.Contains(t) || LinePatterns.Any(p => p.IsMatch(t));
        }
    }
}
