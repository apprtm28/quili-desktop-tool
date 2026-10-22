using System;
using System.Threading;
using System.Windows;
using System.Windows.Automation;

namespace Quili.Platform
{
    /// <summary>
    /// The open Slack thread, marked by Slack's own "Summarize thread" button: <see cref="Bounds"/> is that button (screen
    /// pixels), and the floating Summarize button goes beside it.
    /// </summary>
    public sealed record ThreadPane(IntPtr Window, Rect Bounds);

    /// <summary>
    /// Follows the open thread's Summarize-thread button while Slack is in front, so the floating button can sit beside it.
    /// Polling runs on a background thread because UI Automation calls into another process can be slow.
    ///
    /// Staying smooth: once the button is found only that one element is re-measured, every 30 ms while it is moving and
    /// every 120 ms otherwise, so a dragged window is followed closely. The found element is kept while Slack is behind
    /// another window or minimized (the floating button just hides), so coming back is instant instead of a fresh search
    /// of Slack's whole tree. Only when no button is known is the tree searched, at most every couple of seconds (at
    /// once when Slack comes to the front).
    /// </summary>
    public sealed class ThreadWatcher : IDisposable
    {
        static readonly TimeSpan SearchInterval = TimeSpan.FromSeconds(2);
        const int MovingMs = 30, IdleMs = 120;

        readonly Thread _thread;
        volatile bool _stop;
        ThreadReader.Anchor? _cached;
        DateTime _lastSearch = DateTime.MinValue;
        bool _wasFront;
        IntPtr _slackCheckedWindow;   // IsSlack is a process lookup, so it is only redone when the foreground window changes
        bool _slackCheckedResult;

        public volatile bool Paused;

        /// <summary>Raised on the polling thread; null means no thread pane is open (or Slack is not in front).</summary>
        public event Action<ThreadPane?>? PaneChanged;

        public ThreadWatcher()
        {
            _thread = new Thread(Loop) { IsBackground = true, Name = "ThreadWatcher" };
        }

        public void Start() => _thread.Start();
        public void Dispose() => _stop = true;

        void Loop()
        {
            ThreadPane? last = null;
            var activeUntil = DateTime.MinValue;
            while (!_stop)
            {
                ThreadPane? current = Paused ? null : Probe();
                if (!Same(last, current))
                {
                    last = current;
                    activeUntil = DateTime.UtcNow.AddSeconds(1); // something moved: keep polling fast for a moment
                    PaneChanged?.Invoke(current);
                }
                Thread.Sleep(DateTime.UtcNow < activeUntil ? MovingMs : IdleMs);
            }
        }

        ThreadPane? Probe()
        {
            try
            {
                var hwnd = Native.GetForegroundWindow();
                if (hwnd == IntPtr.Zero || !IsSlack(hwnd))
                {
                    _wasFront = false; // hide, but keep the found button for when Slack is back
                    return null;
                }
                if (!_wasFront)
                {
                    _wasFront = true;
                    _lastSearch = DateTime.MinValue; // Slack just came to the front: look at once if nothing is known
                }
                if (Native.IsIconic(hwnd)) return null; // minimized: hide, keep the button

                if (_cached == null)
                {
                    if (DateTime.UtcNow - _lastSearch < SearchInterval) return null;
                    _lastSearch = DateTime.UtcNow;
                }
                var found = ThreadReader.DetectAnchor(hwnd, _cached);
                if (found == null) { _cached = null; return null; }
                _cached = found;
                return new ThreadPane(hwnd, found.Bounds);
            }
            catch (Exception)
            {
                _cached = null;
                return null;
            }
        }

        bool IsSlack(IntPtr hwnd)
        {
            if (hwnd != _slackCheckedWindow)
            {
                _slackCheckedWindow = hwnd;
                _slackCheckedResult = ThreadReader.IsSlack(hwnd);
            }
            return _slackCheckedResult;
        }

        static bool Same(ThreadPane? a, ThreadPane? b)
        {
            if (a == null || b == null) return a == null && b == null;
            return a.Window == b.Window && a.Bounds == b.Bounds;
        }
    }
}
