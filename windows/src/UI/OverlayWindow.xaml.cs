using System;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Controls;
using System.Windows.Media.Animation;
using System.Diagnostics;
using Quili.Core;
using Quili.Platform;

namespace Quili.UI
{
    /// <summary>
    /// A small always-on-top button that never takes keyboard focus from the field it sits on. Hovering it
    /// expands a pill to the left with the available actions.
    /// </summary>
    public partial class OverlayWindow : Window
    {
        const double CollapsedDip = 28, ExpandedDip = 138, MarginDip = 6, PillRadiusDip = 14, ChipRadiusDip = 13, ChipDip = 26,
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
        /// <summary>Screen rectangle (pixels) the overlay occupies; empty while hidden. The preview bubble anchors to it.</summary>
        public System.Drawing.Rectangle Area => OverlayArea;
        System.Drawing.Rectangle OverlayArea;   // where the overlay window currently is (empty until first shown)
        const int DragThresholdPx = 4;
        bool _pressed, _dragging, _dragged;
        bool _userMoved;        // the user dragged the button; keep it there until focus moves to another field
        System.Drawing.Point _pressCursor, _lastCursor;
        bool _docked;           // design 2: docked to the field, the green button has no zoom effect
        bool _animating;
        double _from, _target, _durationMs;
        long _startMs;

        public event Action<TextAction>? ActionRequested;
        public event Action? CancelRequested;
        public event Action? SettingsRequested;
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
            MakeInteractive(SettingsAction, tint: true, hoverScale: 1.1);
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
            // Idle, the green button is only a handle to drag; while busy, hovering it offers Cancel.
            Chip.Cursor = IsBusy ? (cancel ? Cursors.Hand : Cursors.Wait) : Cursors.SizeAll;
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

        enum DockStyle { Floating, Below, Above }

        /// <summary>
        /// Places the button for a focused field (screen pixels). A wide field (design 1) gets a free-floating
        /// pill inside it; a narrower one (design 2) gets the pill docked to its bottom (or top) edge. When
        /// <paramref name="sameField"/> is true and the user has dragged the button, it stays where they put it.
        /// </summary>
        public void ShowAt(Rect bounds, bool sameField = false)
        {
            if (_userMoved && sameField) return;
            _userMoved = false;

            double scale = VisualTreeHelper.GetDpi(this).DpiScaleX;
            _size = (int)Math.Round(CollapsedDip * scale);
            int margin = (int)Math.Round(MarginDip * scale);

            var screen = System.Windows.Forms.Screen.FromRectangle(new System.Drawing.Rectangle(
                (int)bounds.X, (int)bounds.Y, (int)bounds.Width, (int)bounds.Height)).WorkingArea;

            int x = (int)bounds.Right - _size - margin;
            int y;
            var style = DockStyle.Floating;

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
                // squared off on both the green button and the pill.
                // The focused element is usually the inner input; the field's visible border is a little further
                // out. Look at the screen pixels just past the element to find it, and put the top of the pill on
                // that border (falling back to a fixed offset when nothing can be measured).
                int offset = (int)Math.Round(DockOffsetDip * scale);
                int reach = (int)Math.Round(EdgeSearchDip * scale);
                style = DockStyle.Below;
                y = FieldEdge.Find(bounds, below: true, reach, OverlayArea) ?? (int)bounds.Bottom + offset;
                if (y + _size > screen.Bottom)
                {
                    int topEdge = FieldEdge.Find(bounds, below: false, reach, OverlayArea) ?? (int)bounds.Y - offset;
                    y = topEdge + 1 - _size;
                    style = DockStyle.Above;
                }
            }
            ApplyDesign(style);
            _x = Math.Max(screen.Left, Math.Min(x, screen.Right - _size));
            _y = Math.Max(screen.Top, Math.Min(y, screen.Bottom - _size));

            // WPF only renders a window's content once it has been shown through WPF (ShowActivated=False
            // in the XAML keeps it from stealing focus); SetWindowPos alone just shows an empty shell.
            if (!IsVisible) Show();

            PlaceWindow();
            ApplyLayout();
            DebugLog.Write($"overlay placed at {_x},{_y} size {_size} design={(style == DockStyle.Floating ? 1 : 2)} visible={IsVisible}");
        }

        /// <summary>Corners, button size and zoom for the floating pill (design 1) or the docked tab (design 2).</summary>
        void ApplyDesign(DockStyle style)
        {
            _docked = style != DockStyle.Floating;
            CornerRadius pill = style switch
            {
                DockStyle.Below => new CornerRadius(0, 0, DockedCornerDip, DockedCornerDip),
                DockStyle.Above => new CornerRadius(DockedCornerDip, DockedCornerDip, 0, 0),
                _ => new CornerRadius(PillRadiusDip),
            };
            CornerRadius button = style switch
            {
                DockStyle.Below => new CornerRadius(0, 0, DockedCornerDip, DockedCornerDip),
                DockStyle.Above => new CornerRadius(DockedCornerDip, DockedCornerDip, 0, 0),
                _ => new CornerRadius(ChipRadiusDip),
            };
            Pill.CornerRadius = pill;
            Chip.CornerRadius = button;
            // Docked, the green button starts 1 unit below the pill's top and is 2 units shorter than the pill
            // (so it ends 1 unit above the bottom); floating, it is centred with a 1-unit inset.
            Chip.Height = _docked ? CollapsedDip - 2 : ChipDip;
            Chip.VerticalAlignment = _docked ? VerticalAlignment.Top : VerticalAlignment.Center;
            Chip.Margin = _docked ? new Thickness(1, 1, 1, 0) : new Thickness(1);
            // The hover highlight behind each action follows the same corner setting as the button and pill.
            ParaphraseAction.CornerRadius = button;
            TranslateAction.CornerRadius = button;
            SettingsAction.CornerRadius = button;
        }

        /// <summary>Moves the native window to (_x, _y); it is always full width, the pill grows inside it.</summary>
        void PlaceWindow()
        {
            double scale = VisualTreeHelper.GetDpi(this).DpiScaleX;
            int expandedPx = (int)Math.Round(ExpandedDip * scale);
            Native.SetWindowPos(_hwnd, Native.HWND_TOPMOST, _x - (expandedPx - _size), _y, expandedPx, _size,
                Native.SWP_NOACTIVATE | Native.SWP_SHOWWINDOW);
            OverlayArea = new System.Drawing.Rectangle(_x - (expandedPx - _size), _y, expandedPx, _size);
        }

        public void HideOverlay()
        {
            StopAnimation();
            EndDrag();
            _userMoved = false; // focus lost: the next field starts from its default placement
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
            SettingsAction.Opacity = actions;
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

        // Dragging: press and move more than a few pixels to pick the button up. Docked (design 2) it turns into the
        // floating pill (design 1) the moment it is dragged.
        void Root_PreviewMouseDown(object sender, MouseButtonEventArgs e)
        {
            _pressed = true;
            _dragging = false;
            _dragged = false;
            _pressCursor = _lastCursor = System.Windows.Forms.Cursor.Position;
        }

        void Root_PreviewMouseMove(object sender, MouseEventArgs e)
        {
            if (!_pressed) return;
            if (e.LeftButton != MouseButtonState.Pressed) { _pressed = false; EndDrag(); return; }

            var cursor = System.Windows.Forms.Cursor.Position;
            if (!_dragging)
            {
                if (Math.Abs(cursor.X - _pressCursor.X) < DragThresholdPx && Math.Abs(cursor.Y - _pressCursor.Y) < DragThresholdPx)
                    return;
                _dragging = true;
                _dragged = true;
                _userMoved = true;
                ApplyDesign(DockStyle.Floating);
                Root.CaptureMouse();
                Root.Cursor = Cursors.SizeAll;
            }

            double scale = VisualTreeHelper.GetDpi(this).DpiScaleX;
            int expandedPx = (int)Math.Round(ExpandedDip * scale);
            var area = System.Windows.Forms.Screen.FromPoint(cursor).WorkingArea;
            _x = Math.Max(area.Left + (expandedPx - _size), Math.Min(_x + cursor.X - _lastCursor.X, area.Right - _size));
            _y = Math.Max(area.Top, Math.Min(_y + cursor.Y - _lastCursor.Y, area.Bottom - _size));
            _lastCursor = cursor;
            PlaceWindow();
        }

        void Root_PreviewMouseUp(object sender, MouseButtonEventArgs e)
        {
            _pressed = false;
            EndDrag();
        }

        void EndDrag()
        {
            if (!_dragging) return;
            _dragging = false;
            Root.ReleaseMouseCapture();
            Root.Cursor = null;
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

        // Only the action buttons start work: the sparkle paraphrases, EN translates to English. The green button
        // is a drag handle, and a click on it does something only while a request runs (cancel).
        void Chip_MouseLeftButtonUp(object sender, MouseButtonEventArgs e)
        {
            if (_dragged) return;
            if (IsBusy && _cancelReady) CancelRequested?.Invoke();
        }
        void Action_MouseLeftButtonUp(object sender, MouseButtonEventArgs e) => Trigger(TextAction.Paraphrase);
        void Translate_MouseLeftButtonUp(object sender, MouseButtonEventArgs e) => Trigger(TextAction.TranslateToEnglish);

        void Settings_MouseLeftButtonUp(object sender, MouseButtonEventArgs e)
        {
            if (_dragged) return; // the mouse-up that ends a drag is not a click
            SettingsRequested?.Invoke();
        }

        void Trigger(TextAction action)
        {
            if (_dragged) return; // the mouse-up that ends a drag is not a click
            if (!IsBusy) ActionRequested?.Invoke(action);
        }
    }
}
