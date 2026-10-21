using System;
using System.Threading.Tasks;
using System.Windows.Threading;
using ParaphraseTool.Core;
using ParaphraseTool.Platform;
using ParaphraseTool.UI;

namespace ParaphraseTool
{
    public enum NoticeLevel { Info, Error }

    /// <summary>
    /// Ties the pieces together: tracks the focused field, shows the overlay button on it, and runs
    /// read → paraphrase → replace when the button is clicked. Create it on the UI thread.
    /// </summary>
    public sealed class ParaphraseController : IDisposable
    {
        readonly Settings _settings;
        readonly Dispatcher _dispatcher;
        readonly Action<string, string, NoticeLevel> _notify;
        readonly OverlayWindow _overlay = new();
        readonly FocusTracker _tracker = new();
        TextTarget? _current;

        public ParaphraseController(Settings settings, Dispatcher dispatcher, Action<string, string, NoticeLevel> notify)
        {
            _settings = settings;
            _dispatcher = dispatcher;
            _notify = notify;
            _overlay.ActionRequested += action => _ = RunAsync(action);
            _tracker.TargetChanged += t => _dispatcher.BeginInvoke(() => OnTargetChanged(t));
        }

        public void Start() => _tracker.Start();

        public bool Paused
        {
            set
            {
                _tracker.Paused = value;
                if (value) _overlay.HideOverlay();
            }
        }

        public void Dispose() => _tracker.Dispose();

        void OnTargetChanged(TextTarget? target)
        {
            // Keep the button where it is while a request is running; the result is validated afterwards.
            if (_overlay.IsBusy) return;

            _current = target;
            if (target == null) _overlay.HideOverlay();
            else _overlay.ShowAt(target.Bounds);
        }

        async Task RunAsync(TextAction action)
        {
            var target = _current;
            DebugLog.Write($"{action} clicked (target={(target == null ? "none" : "set")}, busy={_overlay.IsBusy})");
            if (target == null || _overlay.IsBusy) return;

            _overlay.SetBusy(true);
            var targetWindow = Native.GetForegroundWindow();
            try
            {
                var field = await TextAccess.ReadAsync(target.Element);
                DebugLog.Write($"read {field.Text.Length} chars from field");
                if (string.IsNullOrWhiteSpace(field.Text))
                {
                    _notify($"Nothing to {action.Verb().ToLowerInvariant()}", "The text field is empty.", NoticeLevel.Info);
                    return;
                }

                var result = await ParaphraseClient.RunAsync(field.Text, _settings, action);

                bool focused = FocusTracker.StillFocused(target.Element), front = FocusTracker.IsForeground(target.Element);
                if (!focused || !front)
                {
                    DebugLog.Write($"target lost focus (focused={focused}, foreground={front}); bringing it back");
                    if (await FocusTracker.RestoreFocusAsync(target.Element, targetWindow))
                        DebugLog.Write("focus restored");
                    else
                    {
                        DebugLog.Write("could not restore focus; result left on the clipboard");
                        TextAccess.TrySetClipboard(result);
                        _notify("Focus changed", $"The {action.Verb().ToLowerInvariant()}d text was copied to the clipboard instead.", NoticeLevel.Info);
                        return;
                    }
                }

                await TextAccess.ReplaceAsync(field, result, target.Element);
                DebugLog.Write("field replaced");
            }
            catch (Exception ex)
            {
                DebugLog.Write($"{action} failed: {ex.GetType().Name}: {ex.Message}");
                _notify($"{action.Verb()} failed", ex.Message, NoticeLevel.Error);
            }
            finally
            {
                _overlay.SetBusy(false);
            }
        }
    }
}
