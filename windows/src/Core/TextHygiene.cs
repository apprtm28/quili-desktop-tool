using System;
using System.Text;

namespace Quili.Core
{
    /// <summary>
    /// Guards against text that UI Automation hands back damaged around emoji: U+FFFC (an embedded image such
    /// as Slack's emoji), U+FFFD (a failed decode) or an unpaired UTF-16 surrogate (a read cut mid-emoji).
    /// </summary>
    public static class TextHygiene
    {
        const char ObjectReplacement = '￼', Replacement = '�';

        /// <summary>True when the text visibly lost something and the clipboard copy should be used instead.</summary>
        public static bool IsUnreliable(string? text) =>
            !string.IsNullOrEmpty(text)
            && (text.Contains(ObjectReplacement) || text.Contains(Replacement) || HasLoneSurrogate(text));

        public static string StripLoneSurrogates(string text)
        {
            if (!HasLoneSurrogate(text)) return text;
            var sb = new StringBuilder(text.Length);
            for (int i = 0; i < text.Length; i++)
            {
                char c = text[i];
                if (char.IsHighSurrogate(c) && i + 1 < text.Length && char.IsLowSurrogate(text[i + 1]))
                {
                    sb.Append(c).Append(text[++i]);
                }
                else if (!char.IsSurrogate(c))
                {
                    sb.Append(c);
                }
            }
            return sb.ToString();
        }

        static bool HasLoneSurrogate(string text)
        {
            for (int i = 0; i < text.Length; i++)
            {
                char c = text[i];
                if (char.IsHighSurrogate(c) && i + 1 < text.Length && char.IsLowSurrogate(text[i + 1])) i++;
                else if (char.IsSurrogate(c)) return true;
            }
            return false;
        }

        /// <summary>Counts only (never the text itself) for the debug log.</summary>
        public static string Describe(string text)
        {
            int symbols = 0, objects = 0, replacements = 0;
            foreach (var rune in text.EnumerateRunes())
            {
                int v = rune.Value;
                if (v == ObjectReplacement) objects++;
                else if (v == Replacement) replacements++;
                else if (v >= 0x1F000 || (v >= 0x2600 && v <= 0x27BF)) symbols++;
            }
            return $"chars={text.Length} emoji~{symbols} objectReplacement={objects} replacement={replacements} " +
                   $"loneSurrogate={HasLoneSurrogate(text)}";
        }
    }
}
