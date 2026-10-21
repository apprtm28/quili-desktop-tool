using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading;
using System.Windows;
using System.Windows.Automation;
using Quili.Core;

namespace Quili.Platform
{
    public sealed record TextTarget(AutomationElement Element, Rect Bounds);

    /// <summary>
    /// Polls UI Automation for the keyboard-focused element and reports it when it is an editable text field.
    /// Polling runs on a background thread because UIA calls into other processes can be slow.
    /// </summary>
    public sealed class FocusTracker : IDisposable
    {
        const int MinWidth = 40, MinHeight = 14;

        readonly Thread _thread;
        readonly int _ownPid = Process.GetCurrentProcess().Id;
        volatile bool _stop;
        string? _lastReason;

        public volatile bool Paused;

        /// <summary>Raised on the polling thread; null means no editable field is focused.</summary>
        public event Action<TextTarget?>? TargetChanged;

        public FocusTracker()
        {
            _thread = new Thread(Loop) { IsBackground = true, Name = "FocusTracker" };
        }

        public void Start() => _thread.Start();
        public void Dispose() => _stop = true;

        void Loop()
        {
            TextTarget? last = null;
            while (!_stop)
            {
                TextTarget? current = Paused ? null : Probe();
                if (!Same(last, current))
                {
                    last = current;
                    TargetChanged?.Invoke(current);
                }
                Thread.Sleep(250);
            }
        }

        static bool Same(TextTarget? a, TextTarget? b)
        {
            if (a == null || b == null) return a == null && b == null;
            return a.Bounds == b.Bounds && SafeCompare(a.Element, b.Element);
        }

        public static bool SameElement(AutomationElement a, AutomationElement b) => SafeCompare(a, b);

        static bool SafeCompare(AutomationElement a, AutomationElement b)
        {
            try { return Automation.Compare(a, b); } catch (Exception) { return false; }
        }

        public static bool StillFocused(AutomationElement element)
        {
            try
            {
                var focused = AutomationElement.FocusedElement;
                return focused != null && Automation.Compare(focused, element);
            }
            catch (Exception) { return false; }
        }

        /// <summary>Process that owns the foreground window, as UI Automation reports it (null if unknown).</summary>
        static int? ForegroundPid()
        {
            try
            {
                var hwnd = Native.GetForegroundWindow();
                return hwnd == IntPtr.Zero ? null : AutomationElement.FromHandle(hwnd).Current.ProcessId;
            }
            catch (Exception) { return null; }
        }

        /// <summary>
        /// Key presses (Ctrl+A/C/V) go to the foreground window, so only act when it belongs to the element's process.
        /// Chromium apps keep a "focused element" per window, so UIA can report a field in a background window.
        /// </summary>
        public static bool IsForeground(AutomationElement element)
        {
            try
            {
                var fg = ForegroundPid();
                return fg == null || fg == element.Current.ProcessId;
            }
            catch (Exception) { return false; }
        }

        /// <summary>
        /// Brings the window and field back to the front after the user switched away during the request.
        /// Windows only lets the foreground thread hand off focus, hence the AttachThreadInput dance.
        /// </summary>
        public static async System.Threading.Tasks.Task<bool> RestoreFocusAsync(AutomationElement element, IntPtr hwnd)
        {
            if (hwnd == IntPtr.Zero) return false;
            try
            {
                Native.ForceForeground(hwnd);

                await System.Threading.Tasks.Task.Delay(200);
                await System.Threading.Tasks.Task.Run(() => { try { element.SetFocus(); } catch (Exception) { } });
                await System.Threading.Tasks.Task.Delay(200);
            }
            catch (Exception ex)
            {
                DebugLog.Write($"restore focus failed: {ex.GetType().Name}: {ex.Message}");
                return false;
            }
            return IsForeground(element) && StillFocused(element);
        }

        void Report(string reason)
        {
            if (reason == _lastReason) return;
            _lastReason = reason;
            DebugLog.Write(reason);
        }

        TextTarget? Probe()
        {
            try
            {
                var el = AutomationElement.FocusedElement;
                if (el == null) { Report("no focused element"); return null; }

                var info = el.Current;
                var desc = $"{info.ControlType.ProgrammaticName} class='{info.ClassName}' pid={info.ProcessId}";
                if (info.ProcessId == _ownPid) { Report($"skip own window: {desc}"); return null; }
                var fg = ForegroundPid();
                if (fg != null && fg != info.ProcessId) { Report($"skip background window (foreground pid={fg}): {desc}"); return null; }
                if (info.IsOffscreen || info.IsPassword) { Report($"skip offscreen/password: {desc}"); return null; }
                if (!IsEditable(el, info.ControlType)) { Report($"skip not editable: {desc}"); return null; }

                var r = info.BoundingRectangle;
                if (r.IsEmpty || r.Width < MinWidth || r.Height < MinHeight)
                {
                    Report($"skip too small/empty ({r}): {desc}");
                    return null;
                }
                Report($"show button: {desc} bounds={r}");
                return new TextTarget(el, r);
            }
            catch (Exception ex)
            {
                // Element vanished or the target process is unresponsive.
                Report($"probe error: {ex.GetType().Name}: {ex.Message}");
                return null;
            }
        }

        static bool IsEditable(AutomationElement el, ControlType type)
        {
            bool hasValue = el.TryGetCurrentPattern(ValuePattern.Pattern, out var vp);
            bool readOnly = hasValue && ((ValuePattern)vp).Current.IsReadOnly;
            if (readOnly) return false;

            if (type == ControlType.Edit) return true;
            if (NeverText.Contains(type)) return false;

            // Any other focused control with a writable value is an input (editable combo boxes, custom fields).
            if (hasValue) return true;

            // Rich editors (Slack, web contenteditable, Windows 11 Notepad) may surface as
            // Document/Group/Custom/Pane with a TextPattern but no ValuePattern.
            return el.TryGetCurrentPattern(TextPattern.Pattern, out _) && el.Current.IsKeyboardFocusable;
        }

        static readonly HashSet<ControlType> NeverText = new()
        {
            ControlType.Button, ControlType.CheckBox, ControlType.RadioButton, ControlType.Slider,
            ControlType.ScrollBar, ControlType.ProgressBar, ControlType.MenuItem, ControlType.TabItem,
            ControlType.ListItem, ControlType.TreeItem, ControlType.Hyperlink, ControlType.Spinner,
        };
    }
}
