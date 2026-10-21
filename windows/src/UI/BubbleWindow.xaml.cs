using System;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using Quili.Platform;

namespace Quili.UI
{
    /// <summary>
    /// A small always-on-top card next to the overlay button that shows the rewritten text as it streams in,
    /// before it replaces the field's text. Click-through and never activated, so focus stays in the field.
    /// </summary>
    public partial class BubbleWindow : Window
    {
        const int WS_EX_TRANSPARENT = 0x20;
        const double GapDip = 6;

        readonly IntPtr _hwnd;

        public BubbleWindow()
        {
            InitializeComponent();
            _hwnd = new WindowInteropHelper(this).EnsureHandle();
            int ex = Native.GetWindowLong(_hwnd, Native.GWL_EXSTYLE);
            Native.SetWindowLong(_hwnd, Native.GWL_EXSTYLE,
                ex | Native.WS_EX_NOACTIVATE | Native.WS_EX_TOOLWINDOW | WS_EX_TRANSPARENT);
        }

        /// <summary>Shows <paramref name="text"/> above <paramref name="anchor"/> (screen pixels), or below it when there is no room.</summary>
        public void ShowText(string text, System.Drawing.Rectangle anchor)
        {
            if (anchor.IsEmpty) return;
            Body.Text = text;
            Scroller.ScrollToBottom(); // long text: keep the newest lines in view

            if (!IsVisible) Show();

            double scale = VisualTreeHelper.GetDpi(this).DpiScaleX;
            Card.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            int w = (int)Math.Ceiling(Card.DesiredSize.Width * scale), h = (int)Math.Ceiling(Card.DesiredSize.Height * scale);
            int gap = (int)Math.Round(GapDip * scale);

            var area = System.Windows.Forms.Screen.FromRectangle(anchor).WorkingArea;
            int x = Math.Max(area.Left, Math.Min(anchor.Right - w, area.Right - w));
            int y = anchor.Top - gap - h;
            if (y < area.Top) y = Math.Min(anchor.Bottom + gap, area.Bottom - h);

            Native.SetWindowPos(_hwnd, Native.HWND_TOPMOST, x, y, w, h, Native.SWP_NOACTIVATE | Native.SWP_SHOWWINDOW);
        }

        public void HideBubble()
        {
            Body.Text = "";
            if (IsVisible) Hide();
        }
    }
}
