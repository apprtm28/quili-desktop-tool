using System;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Controls;
using System.Windows.Media.Animation;
using System.Diagnostics;
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
        // Time-based easing (not a fixed step per tick) so the pill glides at the display's frame rate.
        const double ExpandMs = 230, CollapseMs = 170;

        readonly IntPtr _hwnd;
        readonly Stopwatch _clock = Stopwatch.StartNew();

        // Position of the round button (screen pixels); the pill grows to the left of it.
        int _x, _y, _size;
        double _expansion;      // 0 = collapsed, 1 = fully expanded
        bool _hovered;
        bool _animating;
        double _from, _target, _durationMs;
        long _startMs;

        public event Action<TextAction>? ActionRequested;
        public bool IsBusy { get; private set; }

        public OverlayWindow()
        {
            InitializeComponent();
            _hwnd = new WindowInteropHelper(this).EnsureHandle();
            int ex = Native.GetWindowLong(_hwnd, Native.GWL_EXSTYLE);
            Native.SetWindowLong(_hwnd, Native.GWL_EXSTYLE, ex | Native.WS_EX_NOACTIVATE | Native.WS_EX_TOOLWINDOW);

            // Hover / press feedback so the buttons read as clickable.
            MakeInteractive(ParaphraseAction, tint: true, hoverScale: 1.1);
            MakeInteractive(TranslateAction, tint: true, hoverScale: 1.1);
            MakeInteractive(Chip, tint: false, hoverScale: 1.08);
        }

        static readonly Color TintOff = Color.FromArgb(0x00, 0x3D, 0xBE, 0x4A);
        static readonly Color TintOn = Color.FromArgb(0x2E, 0x3D, 0xBE, 0x4A);

        /// <summary>
        /// Grows the button slightly (and, for the pill actions, fades in a soft green highlight) while the
        /// mouse is over it, and shrinks it a little while it is pressed. Idle while a request is running.
        /// </summary>
        void MakeInteractive(Border button, bool tint, double hoverScale)
        {
            var scale = new ScaleTransform(1, 1);
            button.RenderTransform = scale;
            button.RenderTransformOrigin = new Point(0.5, 0.5);

            SolidColorBrush? highlight = null;
            if (tint)
            {
                highlight = new SolidColorBrush(TintOff); // keeps the whole area clickable, just invisible
                button.Background = highlight;
                button.CornerRadius = new CornerRadius(13);
            }

            void Scale(double to, int ms)
            {
                var animation = new DoubleAnimation(to, TimeSpan.FromMilliseconds(ms))
                {
                    EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut },
                };
                scale.BeginAnimation(ScaleTransform.ScaleXProperty, animation);
                scale.BeginAnimation(ScaleTransform.ScaleYProperty, animation);
            }

            void Tint(Color to) =>
                highlight?.BeginAnimation(SolidColorBrush.ColorProperty,
                    new ColorAnimation(to, TimeSpan.FromMilliseconds(120)));

            button.MouseEnter += (_, _) => { if (!IsBusy) { Scale(hoverScale, 130); Tint(TintOn); } };
            button.MouseLeave += (_, _) => { Scale(1, 130); Tint(TintOff); };
            button.MouseLeftButtonDown += (_, _) => { if (!IsBusy) Scale(0.88, 70); };
            button.MouseLeftButtonUp += (_, _) => Scale(button.IsMouseOver && !IsBusy ? hoverScale : 1, 110);
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
            Retarget(); // collapse while busy, re-expand if still hovered afterwards
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

            // Full width from the start (transparent pixels are click-through); the pill grows inside it.
            int expandedPx = (int)Math.Round(ExpandedDip * scale);
            Native.SetWindowPos(_hwnd, Native.HWND_TOPMOST, _x - (expandedPx - _size), _y, expandedPx, _size,
                Native.SWP_NOACTIVATE | Native.SWP_SHOWWINDOW);

            ApplyLayout();
            DebugLog.Write($"overlay placed at {_x},{_y} size {_size} visible={IsVisible}");
        }

        public void HideOverlay()
        {
            StopAnimation();
            _hovered = false;
            _expansion = 0;
            _target = 0;
            Hide();
        }

        void ApplyLayout()
        {
            // Only WPF content changes here; the native window never resizes during the animation.
            PillHost.Width = CollapsedDip + (ExpandedDip - CollapsedDip) * _expansion;

            // The actions fade in a beat after the pill starts opening (and out first when closing).
            double actions = Math.Clamp((_expansion - 0.3) / 0.7, 0, 1);
            Pill.Opacity = _expansion;
            ParaphraseAction.Opacity = actions;
            TranslateAction.Opacity = actions;
        }

        /// <summary>Eases the pill toward open (hovered, idle) or closed, starting from where it is now.</summary>
        void Retarget()
        {
            double target = _hovered && !IsBusy ? 1 : 0;
            if (_animating ? target == _target : target == _expansion) return;

            _from = _expansion;
            _target = target;
            _durationMs = target > _expansion ? ExpandMs : CollapseMs;
            _startMs = _clock.ElapsedMilliseconds;
            if (!_animating)
            {
                _animating = true;
                CompositionTarget.Rendering += OnRendering; // once per frame, in step with the display
            }
        }

        void OnRendering(object? sender, EventArgs e)
        {
            double t = Math.Clamp((_clock.ElapsedMilliseconds - _startMs) / _durationMs, 0, 1);
            double eased = 1 - Math.Pow(1 - t, 3); // ease-out cubic
            _expansion = _from + (_target - _from) * eased;
            ApplyLayout();
            if (t >= 1) StopAnimation();
        }

        void StopAnimation()
        {
            if (!_animating) return;
            _animating = false;
            CompositionTarget.Rendering -= OnRendering;
        }

        void Root_MouseEnter(object sender, MouseEventArgs e)
        {
            _hovered = true;
            Retarget();
        }

        void Root_MouseLeave(object sender, MouseEventArgs e)
        {
            _hovered = false;
            Retarget();
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
