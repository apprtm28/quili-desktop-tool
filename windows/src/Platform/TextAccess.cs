using System;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Automation;
using System.Windows.Automation.Text;
using Quili.Core;

namespace Quili.Platform
{
    public sealed record FieldText(string Text, bool IsSelection, TextPatternRange? Range = null);

    /// <summary>
    /// Reads and replaces the text of a focused field. Reading prefers UI Automation; replacing and the read
    /// fallback go through the clipboard + Ctrl+A/C/V, which works in Chromium/Electron editors where
    /// ValuePattern.SetValue does not trigger the page's input handlers.
    /// Clipboard methods must be called on the UI (STA) thread.
    /// </summary>
    public static class TextAccess
    {
        /// <summary>Text to paraphrase: the selection if there is one, otherwise the whole field.</summary>
        public static async Task<FieldText> ReadAsync(AutomationElement el)
        {
            var uia = await Task.Run(() => TryReadUia(el));

            if (!string.IsNullOrWhiteSpace(uia.Selection))
            {
                // Web editors report emoji images as U+FFFC; the clipboard copy carries the real characters.
                if (TextHygiene.IsUnreliable(uia.Selection))
                {
                    DebugLog.Write($"UIA selection damaged ({TextHygiene.Describe(uia.Selection)}); reading via clipboard");
                    var copied = await CopyAsync();
                    if (!string.IsNullOrWhiteSpace(copied)) return new FieldText(copied, true, uia.SelectionRange);
                }
                return new FieldText(uia.Selection, true, uia.SelectionRange);
            }

            // Without a TextPattern UIA can't report the selection, so probe with Ctrl+C.
            if (!uia.SelectionKnown)
            {
                var copied = await CopyAsync();
                if (!string.IsNullOrWhiteSpace(copied)) return new FieldText(copied, true);
            }

            if (!string.IsNullOrWhiteSpace(uia.Whole))
            {
                if (!TextHygiene.IsUnreliable(uia.Whole)) return new FieldText(uia.Whole, false);
                DebugLog.Write($"UIA text damaged ({TextHygiene.Describe(uia.Whole)}); reading via clipboard");
                Native.CtrlKey('A');
                var copied = await CopyAsync();
                return new FieldText(string.IsNullOrWhiteSpace(copied) ? uia.Whole : copied, false);
            }

            Native.CtrlKey('A');
            return new FieldText(await CopyAsync(), false);
        }

        static (string? Selection, TextPatternRange? SelectionRange, string? Whole, bool SelectionKnown) TryReadUia(AutomationElement el)
        {
            string? selection = null, whole = null;
            TextPatternRange? range = null;
            bool known = false;
            try
            {
                if (el.TryGetCurrentPattern(TextPattern.Pattern, out var tp))
                {
                    var pattern = (TextPattern)tp;
                    var ranges = pattern.GetSelection();
                    known = true;
                    if (ranges.Length > 0)
                    {
                        selection = string.Concat(ranges.Select(r => r.GetText(-1)));
                        if (ranges.Length == 1) range = ranges[0];
                    }
                    whole = pattern.DocumentRange.GetText(-1);
                }
                if (string.IsNullOrEmpty(whole) && el.TryGetCurrentPattern(ValuePattern.Pattern, out var vp))
                    whole = ((ValuePattern)vp).Current.Value;
            }
            catch (Exception) { }
            return (selection, range, whole, known);
        }

        /// <summary>Ctrl+C and return what landed on the clipboard (empty if nothing was selected).</summary>
        static async Task<string> CopyAsync()
        {
            var backup = GetClipboardText();
            TrySetClipboard("");
            Native.CtrlKey('C');
            await Task.Delay(200);
            var text = GetClipboardText() ?? "";
            if (backup != null) TrySetClipboard(backup);
            return text;
        }

        /// <summary>Pastes over the original selection, or over the whole field when nothing was selected.</summary>
        public static async Task ReplaceAsync(FieldText field, string text, AutomationElement el)
        {
            // The user may have moved the selection while the request ran; put it back or give up.
            if (field.IsSelection && !await RestoreSelectionAsync(field, el))
            {
                TrySetClipboard(text);
                throw new InvalidOperationException(
                    "The selection changed while paraphrasing. The result was copied to the clipboard.");
            }

            var backup = GetClipboardText();
            if (!TrySetClipboard(text))
                throw new InvalidOperationException("Could not access the clipboard.");
            DebugLog.Write($"pasting (selectionOnly={field.IsSelection})");
            if (!field.IsSelection) Native.CtrlKey('A');
            Native.CtrlKey('V');
            await Task.Delay(400); // let the target app read the clipboard before restoring it

            // Confirm the paste landed; if not, leave the result on the clipboard so it isn't lost.
            var after = await Task.Run(() => TryReadUia(el).Whole);
            if (!string.IsNullOrEmpty(after) && !Key(after).Contains(Key(text, 15)))
            {
                DebugLog.Write("paste did not land (field text unchanged)");
                throw new InvalidOperationException(
                    "The text could not be replaced in this field. The result was copied to the clipboard; paste it with Ctrl+V.");
            }
            DebugLog.Write("paste verified");
            if (backup != null) TrySetClipboard(backup);
        }

        static async Task<bool> RestoreSelectionAsync(FieldText field, AutomationElement el)
        {
            if (field.Range != null)
            {
                try
                {
                    await Task.Run(() => field.Range.Select());
                    var now = await Task.Run(() => TryReadUia(el).Selection);
                    if (!string.IsNullOrEmpty(now) && Key(now, 30) == Key(field.Text, 30))
                    {
                        DebugLog.Write("selection restored via UIA range");
                        return true;
                    }
                    DebugLog.Write("UIA range select did not reproduce the selection; comparing via clipboard");
                }
                catch (Exception ex) { DebugLog.Write($"range select failed: {ex.GetType().Name}"); }
            }
            // No usable range: only proceed if the current selection is still the same text.
            var copied = await CopyAsync();
            var same = Normalize(copied) == Normalize(field.Text);
            DebugLog.Write($"selection still the same via clipboard: {same}");
            return same;
        }

        /// <summary>Letters/digits only, so emoji placeholders and whitespace differences don't matter when comparing.</summary>
        static string Key(string s, int max = int.MaxValue) =>
            new string(s.Where(char.IsLetterOrDigit).Take(max).ToArray()).ToLowerInvariant();

        static string Normalize(string s) => s.Replace("\r\n", "\n").Trim();

        public static bool TrySetClipboard(string text)
        {
            for (int i = 0; i < 5; i++)
            {
                try
                {
                    if (text.Length == 0) System.Windows.Clipboard.Clear();
                    else System.Windows.Clipboard.SetText(text);
                    return true;
                }
                catch (System.Runtime.InteropServices.COMException) { System.Threading.Thread.Sleep(40); }
            }
            return false;
        }

        static string? GetClipboardText()
        {
            for (int i = 0; i < 5; i++)
            {
                try { return System.Windows.Clipboard.ContainsText() ? System.Windows.Clipboard.GetText() : null; }
                catch (System.Runtime.InteropServices.COMException) { System.Threading.Thread.Sleep(40); }
            }
            return null;
        }
    }
}
