using System;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
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
        const double GapDip = 6, MaxHeightDip = 150, TallMaxHeightDip = 340, CloseExtraDip = 16;

        static readonly TimeSpan FadeDuration = TimeSpan.FromMilliseconds(250);

        readonly IntPtr _hwnd;
        int _fadeId; // bumped by show/hide so a fade that was overtaken does not hide the new bubble

        public BubbleWindow()
        {
            InitializeComponent();
            _hwnd = new WindowInteropHelper(this).EnsureHandle();
            int ex = Native.GetWindowLong(_hwnd, Native.GWL_EXSTYLE);
            Native.SetWindowLong(_hwnd, Native.GWL_EXSTYLE,
                ex | Native.WS_EX_NOACTIVATE | Native.WS_EX_TOOLWINDOW | WS_EX_TRANSPARENT);
        }

        /// <summary>Raised when the close button of a closable bubble is clicked.</summary>
        public event Action? CloseRequested;

        /// <summary>A closable bubble takes clicks; the others are click-through so they never get in the way.</summary>
        void SetClickable(bool clickable)
        {
            int ex = Native.GetWindowLong(_hwnd, Native.GWL_EXSTYLE);
            Native.SetWindowLong(_hwnd, Native.GWL_EXSTYLE, clickable ? ex & ~WS_EX_TRANSPARENT : ex | WS_EX_TRANSPARENT);
            IsHitTestVisible = clickable;
            CloseButton.Visibility = clickable ? Visibility.Visible : Visibility.Collapsed;
            Scroller.Margin = new Thickness(0, 0, clickable ? CloseExtraDip : 0, 0);
        }

        void Close_MouseLeftButtonUp(object sender, MouseButtonEventArgs e) => CloseRequested?.Invoke();

        /// <summary>
        /// Shows <paramref name="text"/> above <paramref name="anchor"/> (screen pixels), or below it when there is no room.
        /// A <paramref name="tall"/> bubble (a summary) is taller and reads from its first line instead of following the newest ones.
        /// A <paramref name="closable"/> bubble has a close button and takes clicks (it stays until closed).
        /// </summary>
        public void ShowText(string text, System.Drawing.Rectangle anchor, bool tall = false, bool closable = false)
        {
            if (anchor.IsEmpty) return;
            CancelFade();
            SetClickable(closable);
            Scroller.MaxHeight = tall ? TallMaxHeightDip : MaxHeightDip;
            Body.Text = text;
            if (tall) Scroller.ScrollToTop();
            else Scroller.ScrollToBottom(); // long text: keep the newest lines in view

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

        /// <summary>Fades the bubble out, then hides it (the close button and the 5 s auto-close); a show or hide meanwhile cancels the fade.</summary>
        public void FadeOut()
        {
            if (!IsVisible) return;
            int id = ++_fadeId;
            SetClickable(false); // already closing: no more clicks
            var fade = new DoubleAnimation(0, FadeDuration);
            fade.Completed += (_, _) => { if (_fadeId == id) HideBubble(); };
            BeginAnimation(OpacityProperty, fade);
        }

        /// <summary>Stops a running fade and makes the window fully opaque again.</summary>
        void CancelFade()
        {
            _fadeId++;
            BeginAnimation(OpacityProperty, null);
            Opacity = 1;
        }

        public void HideBubble()
        {
            CancelFade();
            SetClickable(false);
            Body.Text = "";
            if (IsVisible) Hide();
        }
    }
}
