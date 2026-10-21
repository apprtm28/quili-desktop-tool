using System;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using ParaphraseTool.Core;
using ParaphraseTool.Platform;

namespace ParaphraseTool.UI
{
    /// <summary>
    /// A small always-on-top button that never takes keyboard focus from the field it sits on. Hovering it
    /// expands a pill to the left with the available actions.
    /// </summary>
    public partial class OverlayWindow : Window
    {
        const double CollapsedDip = 28, ExpandedDip = 102, MarginDip = 6;
        const double StepPerTick = 0.2;

        readonly IntPtr _hwnd;
        readonly DispatcherTimer _animation = new() { Interval = TimeSpan.FromMilliseconds(15) };

        // Position of the round button (screen pixels); the pill grows to the left of it.
        int _x, _y, _size;
        double _expansion;      // 0 = collapsed, 1 = fully expanded
        bool _hovered;

        public event Action<TextAction>? ActionRequested;
        public bool IsBusy { get; private set; }

        public OverlayWindow()
        {
            InitializeComponent();
            _hwnd = new WindowInteropHelper(this).EnsureHandle();
            int ex = Native.GetWindowLong(_hwnd, Native.GWL_EXSTYLE);
            Native.SetWindowLong(_hwnd, Native.GWL_EXSTYLE, ex | Native.WS_EX_NOACTIVATE | Native.WS_EX_TOOLWINDOW);
            _animation.Tick += (_, _) => Animate();
        }

        public void SetBusy(bool busy)
        {
            IsBusy = busy;
            Robot.Visibility = busy ? Visibility.Collapsed : Visibility.Visible;
            Spinner.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
            Spin.BeginAnimation(RotateTransform.AngleProperty, busy
                ? new DoubleAnimation(0, 360, TimeSpan.FromSeconds(0.9)) { RepeatBehavior = RepeatBehavior.Forever }
                : null);
            Chip.Cursor = busy ? Cursors.Wait : Cursors.Hand;
            _animation.Start(); // collapse while busy, re-expand if still hovered afterwards
        }

        /// <summary>Places the button at the bottom-right inside <paramref name="bounds"/> (screen pixels).</summary>
        public void ShowAt(Rect bounds)
        {
            double scale = VisualTreeHelper.GetDpi(this).DpiScaleX;
            _size = (int)Math.Round(CollapsedDip * scale);
            int margin = (int)Math.Round(MarginDip * scale);

            int x = (int)bounds.Right - _size - margin;
            int y = (int)bounds.Bottom - _size - margin;

            var screen = System.Windows.Forms.Screen.FromRectangle(new System.Drawing.Rectangle(
                (int)bounds.X, (int)bounds.Y, (int)bounds.Width, (int)bounds.Height)).WorkingArea;
            _x = Math.Max(screen.Left, Math.Min(x, screen.Right - _size));
            _y = Math.Max(screen.Top, Math.Min(y, screen.Bottom - _size));

            // WPF only renders a window's content once it has been shown through WPF (ShowActivated=False
            // in the XAML keeps it from stealing focus); SetWindowPos alone just shows an empty shell.
            if (!IsVisible) Show();

            ApplyLayout();
            DebugLog.Write($"overlay placed at {_x},{_y} size {_size} visible={IsVisible}");
        }

        public void HideOverlay()
        {
            _animation.Stop();
            _hovered = false;
            _expansion = 0;
            Hide();
        }

        void ApplyLayout()
        {
            double scale = VisualTreeHelper.GetDpi(this).DpiScaleX;
            int expandedPx = (int)Math.Round(ExpandedDip * scale);
            int width = _size + (int)Math.Round((expandedPx - _size) * _expansion);

            Pill.Opacity = _expansion;
            ParaphraseAction.Opacity = _expansion;
            TranslateAction.Opacity = _expansion;
            Native.SetWindowPos(_hwnd, Native.HWND_TOPMOST, _x - (width - _size), _y, width, _size,
                Native.SWP_NOACTIVATE | Native.SWP_SHOWWINDOW);
        }

        void Animate()
        {
            double target = _hovered && !IsBusy ? 1 : 0;
            if (Math.Abs(target - _expansion) <= StepPerTick)
            {
                _expansion = target;
                _animation.Stop();
            }
            else
            {
                _expansion += _expansion < target ? StepPerTick : -StepPerTick;
            }
            ApplyLayout();
        }

        void Root_MouseEnter(object sender, MouseEventArgs e)
        {
            _hovered = true;
            _animation.Start();
        }

        void Root_MouseLeave(object sender, MouseEventArgs e)
        {
            _hovered = false;
            _animation.Start();
        }

        // The round button ("Text Tool") and the Paraphrase action both paraphrase; EN translates to English.
        void Chip_MouseLeftButtonUp(object sender, MouseButtonEventArgs e) => Trigger(TextAction.Paraphrase);
        void Action_MouseLeftButtonUp(object sender, MouseButtonEventArgs e) => Trigger(TextAction.Paraphrase);
        void Translate_MouseLeftButtonUp(object sender, MouseButtonEventArgs e) => Trigger(TextAction.TranslateToEnglish);

        void Trigger(TextAction action)
        {
            if (!IsBusy) ActionRequested?.Invoke(action);
        }
    }
}
