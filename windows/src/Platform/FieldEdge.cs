using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using Quili.Core;

namespace Quili.Platform
{
    /// <summary>
    /// Finds where a text field's visible edge really is. UI Automation reports the focused element's bounds,
    /// which in browsers are the inner &lt;input&gt; and not the padded, bordered box around it. A few pixels
    /// of the screen just past the element show where the box ends: the colour changes at its border.
    /// </summary>
    public static class FieldEdge
    {
        const int Inset = 3;          // start this far inside the element, so the reference colour is the field's own
        const int ColorThreshold = 30; // summed per-channel difference that counts as an edge

        /// <summary>
        /// Screen row of the first pixel past the field's bottom (<paramref name="below"/>) or top edge, or null when
        /// no colour change is found within <paramref name="maxExtraPx"/>. Columns inside <paramref name="avoid"/>
        /// (our own overlay) are skipped so it can't measure itself.
        /// </summary>
        public static int? Find(System.Windows.Rect element, bool below, int maxExtraPx, Rectangle avoid)
        {
            try
            {
                int rows = Inset + maxExtraPx + 1;
                int start = below ? (int)element.Bottom - Inset : (int)element.Top + Inset;
                int top = below ? start : start - rows + 1;

                var found = new List<int>();
                foreach (double fraction in new[] { 0.15, 0.30, 0.45 })
                {
                    int x = (int)(element.Left + element.Width * fraction);
                    if (!avoid.IsEmpty && x >= avoid.Left && x < avoid.Right) continue;

                    using var strip = new Bitmap(1, rows);
                    using (var g = Graphics.FromImage(strip))
                        g.CopyFromScreen(x, top, 0, 0, new Size(1, rows));

                    // Walk away from the element: index 0 is the row at the starting inset.
                    Color Pixel(int i) => strip.GetPixel(0, below ? i : rows - 1 - i);
                    var reference = Pixel(0);
                    for (int i = 1; i < rows; i++)
                    {
                        if (Distance(Pixel(i), reference) >= ColorThreshold)
                        {
                            found.Add(below ? start + i : start - i);
                            break;
                        }
                    }
                }

                if (found.Count == 0) return null;
                found.Sort();
                int edge = found[found.Count / 2]; // median: one column hitting text or an icon doesn't decide it
                DebugLog.Write($"field edge ({(below ? "bottom" : "top")}): element {(below ? element.Bottom : element.Top)} -> visible {edge}");
                return edge;
            }
            catch (Exception ex)
            {
                DebugLog.Write($"edge detection failed: {ex.GetType().Name}: {ex.Message}");
                return null;
            }
        }

        static int Distance(Color a, Color b) => Math.Abs(a.R - b.R) + Math.Abs(a.G - b.G) + Math.Abs(a.B - b.B);
    }
}
