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
        const double CollapsedDip = 28, ExpandedDip = 102, MarginDip = 6, PillRadiusDip = 14, ChipRadiusDip = 13, ChipDip = 26,
                      DockedCornerDip = 5, DockOffsetDip = 6, EdgeSearchDip = 14;   // design 2: outer corner radius, and drop to reach the field border
        const int WideFieldFactor = 10;   // field width, in button widths, from which the floating design is used
        // Time-based easing (not a fixed step per tick) so the pill glides at the display's frame rate.
        const double ExpandMs = 230, CollapseMs = 170;

        readonly IntPtr _hwnd;
        readonly Stopwatch _clock = Stopwatch.StartNew();

        // Position of the round button (screen pixels); the pill grows to the left of it.
        int _x, _y, _size;
        double _expansion;      // 0 = collapsed, 1 = fully expanded
        bool _hovered;
        System.Drawing.Rectangle OverlayArea;   // where the overlay window currently is (empty until first shown)
        bool _docked;           // design 2: docked to the field, the green button has no zoom effect
        bool _animating;
        double _from, _target, _durationMs;
        long _startMs;

        public event Action<TextAction>? ActionRequested;
        public event Action? CancelRequested;
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
            MakeInteractive(Chip, tint: false, hoverScale: 1.08, noZoom: () => _docked);

            Chip.Background = _chipBrush;
            Chip.MouseEnter += (_, _) => UpdateCancelHover();
            Chip.MouseLeave += (_, _) => { _cancelReady = true; UpdateCancelHover(); };
        }

        static readonly Color ChipGreen = Color.FromRgb(0x3D, 0xBE, 0x4A);
        static readonly Color ChipRed = Color.FromRgb(0xE5, 0x48, 0x4D);
        readonly SolidColorBrush _chipBrush = new(ChipGreen);
        bool _cancelReady; // the click that started the request must not cancel it; the pointer has to leave first

        /// <summary>While busy and hovered, the round button turns red with a cancel mark and "Cancel" tooltip.</summary>
        void UpdateCancelHover()
        {
            bool cancel = IsBusy && _cancelReady && Chip.IsMouseOver;
            _chipBrush.BeginAnimation(SolidColorBrush.ColorProperty,
                new ColorAnimation(cancel ? ChipRed : ChipGreen, TimeSpan.FromMilliseconds(120)));
            CancelMark.Visibility = cancel ? Visibility.Visible : Visibility.Collapsed;
            Spinner.Visibility = IsBusy && !cancel ? Visibility.Visible : Visibility.Collapsed;
            Chip.ToolTip = IsBusy ? (cancel ? "Cancel" : null) : "Text Tool";
            Chip.Cursor = !IsBusy || cancel ? Cursors.Hand : Cursors.Wait;
        }

        static readonly Color TintOff = Color.FromArgb(0x00, 0x3D, 0xBE, 0x4A);
        static readonly Color TintOn = Color.FromArgb(0x2E, 0x3D, 0xBE, 0x4A);

        /// <summary>
        /// Grows the button slightly (and, for the pill actions, fades in a soft green highlight) while the
        /// mouse is over it, and shrinks it a little while it is pressed. Idle while a request is running.
        /// </summary>
        void MakeInteractive(Border button, bool tint, double hoverScale, Func<bool>? noZoom = null)
        {
            double Hover() => noZoom?.Invoke() == true ? 1 : hoverScale;
            double Press() => noZoom?.Invoke() == true ? 1 : 0.88;
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

            button.MouseEnter += (_, _) => { if (!IsBusy) { Scale(Hover(), 130); Tint(TintOn); } };
            button.MouseLeave += (_, _) => { Scale(1, 130); Tint(TintOff); };
            button.MouseLeftButtonDown += (_, _) => { if (!IsBusy) Scale(Press(), 70); };
            button.MouseLeftButtonUp += (_, _) => Scale(button.IsMouseOver && !IsBusy ? Hover() : 1, 110);
        }

        public void SetBusy(bool busy)
        {
            IsBusy = busy;
            Robot.Visibility = busy ? Visibility.Collapsed : Visibility.Visible;
            Spin.BeginAnimation(RotateTransform.AngleProperty, busy
                ? new DoubleAnimation(0, 360, TimeSpan.FromSeconds(0.9)) { RepeatBehavior = RepeatBehavior.Forever }
                : null);
            _cancelReady = !Chip.IsMouseOver;
            UpdateCancelHover();
            Retarget(); // collapse while busy, re-expand if still hovered afterwards
        }

        /// <summary>Places the button at the bottom-right inside <paramref name="bounds"/> (screen pixels).</summary>
        public void ShowAt(Rect bounds)
        {
            double scale = VisualTreeHelper.GetDpi(this).DpiScaleX;
            _size = (int)Math.Round(CollapsedDip * scale);
            int margin = (int)Math.Round(MarginDip * scale);

            var screen = System.Windows.Forms.Screen.FromRectangle(new System.Drawing.Rectangle(
                (int)bounds.X, (int)bounds.Y, (int)bounds.Width, (int)bounds.Height)).WorkingArea;

            int x = (int)bounds.Right - _size - margin;
            int y;
            var pillCorners = new CornerRadius(PillRadiusDip);
            var chipCorners = new CornerRadius(ChipRadiusDip);
            _docked = bounds.Width < _size * WideFieldFactor;

            if (bounds.Width >= _size * WideFieldFactor)
            {
                // Design 1, wide field: a free-floating pill inside it, centred on short fields and at the
                // bottom-right of taller ones.
                y = bounds.Height <= _size * 3
                    ? (int)(bounds.Y + (bounds.Height - _size) / 2)
                    : (int)bounds.Bottom - _size - margin;
            }
            else
            {
                // Design 2, narrower field: the button would cover its text, so dock it to the bottom edge like
                // a tab (to the top edge when there is no room under it), with the corners that touch the field
                // squared off on both the green button and the pill. The button keeps its 1-unit inset, so it
                // fills the pill's inside from top to bottom.
                // The focused element is usually the inner input; the field's visible border is a little further
                // out. Look at the screen pixels just past the element to find it, and put the top of the pill on
                // that border (falling back to a fixed offset when nothing can be measured).
                int offset = (int)Math.Round(DockOffsetDip * scale);
                int reach = (int)Math.Round(EdgeSearchDip * scale);
                y = FieldEdge.Find(bounds, below: true, reach, OverlayArea) ?? (int)bounds.Bottom + offset;
                pillCorners = new CornerRadius(0, 0, DockedCornerDip, DockedCornerDip);
                chipCorners = new CornerRadius(0, 0, DockedCornerDip, DockedCornerDip);
                if (y + _size > screen.Bottom)
                {
                    int topEdge = FieldEdge.Find(bounds, below: false, reach, OverlayArea) ?? (int)bounds.Y - offset;
                    y = topEdge + 1 - _size;
                    pillCorners = new CornerRadius(DockedCornerDip, DockedCornerDip, 0, 0);
                    chipCorners = new CornerRadius(DockedCornerDip, DockedCornerDip, 0, 0);
                }
            }
            Pill.CornerRadius = pillCorners;
            Chip.CornerRadius = chipCorners;
            // Docked, the green button starts 1 unit below the pill's top and is 2 units shorter than the pill
            // (so it ends 1 unit above the bottom); floating, it is centred with a 1-unit inset.
            Chip.Height = _docked ? CollapsedDip - 2 : ChipDip;
            Chip.VerticalAlignment = _docked ? VerticalAlignment.Top : VerticalAlignment.Center;
            Chip.Margin = _docked ? new Thickness(1, 1, 1, 0) : new Thickness(1);
            // The hover highlight behind each action follows the same corner setting as the button and pill.
            ParaphraseAction.CornerRadius = chipCorners;
            TranslateAction.CornerRadius = chipCorners;
            _x = Math.Max(screen.Left, Math.Min(x, screen.Right - _size));
            _y = Math.Max(screen.Top, Math.Min(y, screen.Bottom - _size));

            // WPF only renders a window's content once it has been shown through WPF (ShowActivated=False
            // in the XAML keeps it from stealing focus); SetWindowPos alone just shows an empty shell.
            if (!IsVisible) Show();

            // Full width from the start (transparent pixels are click-through); the pill grows inside it.
            int expandedPx = (int)Math.Round(ExpandedDip * scale);
            Native.SetWindowPos(_hwnd, Native.HWND_TOPMOST, _x - (expandedPx - _size), _y, expandedPx, _size,
                Native.SWP_NOACTIVATE | Native.SWP_SHOWWINDOW);
            OverlayArea = new System.Drawing.Rectangle(_x - (expandedPx - _size), _y, expandedPx, _size);

            ApplyLayout();
            DebugLog.Write($"overlay placed at {_x},{_y} size {_size} visible={IsVisible}");
        }

        public void HideOverlay()
        {
            StopAnimation();
            OverlayArea = System.Drawing.Rectangle.Empty;
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
        void Chip_MouseLeftButtonUp(object sender, MouseButtonEventArgs e)
        {
            if (IsBusy)
            {
                if (_cancelReady) CancelRequested?.Invoke();
                return;
            }
            Trigger(TextAction.Paraphrase);
        }
        void Action_MouseLeftButtonUp(object sender, MouseButtonEventArgs e) => Trigger(TextAction.Paraphrase);
        void Translate_MouseLeftButtonUp(object sender, MouseButtonEventArgs e) => Trigger(TextAction.TranslateToEnglish);

        void Trigger(TextAction action)
        {
            if (!IsBusy) ActionRequested?.Invoke(action);
        }
    }
}
