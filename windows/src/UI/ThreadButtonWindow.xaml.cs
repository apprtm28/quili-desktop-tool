using System;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using Quili.Platform;

namespace Quili.UI
{
    /// <summary>
    /// A small always-on-top round button that sits just left of Slack's own "Summarize thread" button. Clicking it
    /// summarizes that thread; it never takes focus from Slack.
    /// </summary>
    public partial class ThreadButtonWindow : Window
    {
        // Beside Slack's button: this far to its left (to its right when there is no room).
        const double BesideGapDip = 8;

        static readonly Brush Normal = new SolidColorBrush(Color.FromRgb(0x27, 0xAE, 0x4B));
        static readonly Brush Hover = new SolidColorBrush(Color.FromRgb(0x1B, 0x7F, 0x3A));

        readonly IntPtr _hwnd;

        public event Action? Clicked;

        /// <summary>Screen rectangle (pixels) the button occupies; empty while hidden. The summary bubble anchors to it.</summary>
        public System.Drawing.Rectangle Area { get; private set; }

        public ThreadButtonWindow()
        {
            InitializeComponent();
            _hwnd = new WindowInteropHelper(this).EnsureHandle();
            int ex = Native.GetWindowLong(_hwnd, Native.GWL_EXSTYLE);
            Native.SetWindowLong(_hwnd, Native.GWL_EXSTYLE, ex | Native.WS_EX_NOACTIVATE | Native.WS_EX_TOOLWINDOW);
        }

        /// <summary>
        /// Places the button just left of Slack's own button at <paramref name="slackButton"/> (screen pixels),
        /// vertically centred on it; on its right instead when the screen has no room on the left.
        /// </summary>
        public void ShowBeside(Rect slackButton)
        {
            if (!IsVisible) Show();

            double scale = VisualTreeHelper.GetDpi(this).DpiScaleX;
            Pill.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            int w = (int)Math.Ceiling(Pill.DesiredSize.Width * scale), h = (int)Math.Ceiling(Pill.DesiredSize.Height * scale);
            int gap = (int)Math.Round(BesideGapDip * scale);

            var area = System.Windows.Forms.Screen.FromRectangle(new System.Drawing.Rectangle(
                (int)slackButton.X, (int)slackButton.Y, (int)slackButton.Width, (int)slackButton.Height)).WorkingArea;
            int x = (int)slackButton.Left - gap - w;
            if (x < area.Left) x = (int)slackButton.Right + gap;
            x = Math.Max(area.Left, Math.Min(x, area.Right - w));
            int y = Math.Max(area.Top, Math.Min((int)(slackButton.Top + (slackButton.Height - h) / 2), area.Bottom - h));

            Area = new System.Drawing.Rectangle(x, y, w, h);
            Native.SetWindowPos(_hwnd, Native.HWND_TOPMOST, x, y, w, h, Native.SWP_NOACTIVATE | Native.SWP_SHOWWINDOW);
        }

        public void HideButton()
        {
            Area = System.Drawing.Rectangle.Empty;
            if (IsVisible) Hide();
        }

        void Pill_MouseEnter(object sender, MouseEventArgs e) => Pill.Background = Hover;
        void Pill_MouseLeave(object sender, MouseEventArgs e) => Pill.Background = Normal;
        void Pill_MouseLeftButtonUp(object sender, MouseButtonEventArgs e) => Clicked?.Invoke();
    }
}
