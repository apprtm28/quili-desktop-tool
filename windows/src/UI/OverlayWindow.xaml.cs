using System;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using ParaphraseTool.Core;
using ParaphraseTool.Platform;

namespace ParaphraseTool.UI
{
    /// <summary>A small always-on-top button that never takes keyboard focus from the field it sits on.</summary>
    public partial class OverlayWindow : Window
    {
        const double SizeDip = 20, MarginDip = 6;
        IntPtr _hwnd;

        public event Action? Clicked;
        public bool IsBusy { get; private set; }

        public OverlayWindow()
        {
            InitializeComponent();
            _hwnd = new WindowInteropHelper(this).EnsureHandle();
            int ex = Native.GetWindowLong(_hwnd, Native.GWL_EXSTYLE);
            Native.SetWindowLong(_hwnd, Native.GWL_EXSTYLE, ex | Native.WS_EX_NOACTIVATE | Native.WS_EX_TOOLWINDOW);
        }

        public void SetBusy(bool busy)
        {
            IsBusy = busy;
            Glyph.Text = busy ? "…" : "✦";
            Chip.Opacity = busy ? 0.6 : 1;
            Chip.Cursor = busy ? Cursors.Wait : Cursors.Hand;
        }

        /// <summary>Places the button at the bottom-right inside <paramref name="bounds"/> (screen pixels).</summary>
        public void ShowAt(Rect bounds)
        {
            double scale = VisualTreeHelper.GetDpi(this).DpiScaleX;
            int size = (int)Math.Round(SizeDip * scale);
            int margin = (int)Math.Round(MarginDip * scale);

            int x = (int)bounds.Right - size - margin;
            int y = (int)bounds.Bottom - size - margin;

            var screen = System.Windows.Forms.Screen.FromRectangle(new System.Drawing.Rectangle(
                (int)bounds.X, (int)bounds.Y, (int)bounds.Width, (int)bounds.Height)).WorkingArea;
            x = Math.Max(screen.Left, Math.Min(x, screen.Right - size));
            y = Math.Max(screen.Top, Math.Min(y, screen.Bottom - size));

            // WPF only renders a window's content once it has been shown through WPF (ShowActivated=False
            // in the XAML keeps it from stealing focus); SetWindowPos alone just shows an empty shell.
            if (!IsVisible) Show();

            Native.SetWindowPos(_hwnd, Native.HWND_TOPMOST, x, y, size, size,
                Native.SWP_NOACTIVATE | Native.SWP_SHOWWINDOW);
            DebugLog.Write($"overlay placed at {x},{y} size {size} visible={IsVisible}");
        }

        public void HideOverlay() => Hide();

        void Chip_MouseLeftButtonUp(object sender, MouseButtonEventArgs e)
        {
            if (!IsBusy) Clicked?.Invoke();
        }
    }
}
