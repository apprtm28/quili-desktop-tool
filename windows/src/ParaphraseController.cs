using System;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Threading;
using Quili.Core;
using Quili.Platform;
using Quili.UI;

namespace Quili
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
        readonly BubbleWindow _bubble = new();
        readonly FocusTracker _tracker = new();
        TextTarget? _current;
        CancellationTokenSource? _cts;
        bool _writing; // once the field is being written, cancelling would leave it half-replaced

        public ParaphraseController(Settings settings, Dispatcher dispatcher, Action<string, string, NoticeLevel> notify)
        {
            _settings = settings;
            _dispatcher = dispatcher;
            _notify = notify;
            _overlay.ActionRequested += action => _ = RunAsync(action);
            _overlay.SettingsRequested += () => SettingsRequested?.Invoke();
            _overlay.CancelRequested += () =>
            {
                if (_writing) return;
                DebugLog.Write("cancel requested; dropping the connection");
                _cts?.Cancel();
            };
            _tracker.TargetChanged += t => _dispatcher.BeginInvoke(() => OnTargetChanged(t));
        }

        /// <summary>The gear in the pill was clicked.</summary>
        public event Action? SettingsRequested;

        public void Start() => _tracker.Start();

        public bool Paused
        {
            set
            {
                _tracker.Paused = value;
                if (value) { _overlay.HideOverlay(); _bubble.HideBubble(); }
            }
        }

        public void Dispose() => _tracker.Dispose();

        void OnTargetChanged(TextTarget? target)
        {
            // Keep the button where it is while a request is running; the result is validated afterwards.
            if (_overlay.IsBusy) return;

            // Same field as before (just moved or resized): a button the user dragged stays where they put it.
            bool sameField = target != null && _current != null && FocusTracker.SameElement(_current.Element, target.Element);
            _current = target;
            if (target == null) _overlay.HideOverlay();
            else _overlay.ShowAt(target.Bounds, sameField);
        }

        async Task RunAsync(TextAction action)
        {
            var target = _current;
            DebugLog.Write($"{action} clicked (target={(target == null ? "none" : "set")}, busy={_overlay.IsBusy})");
            if (target == null || _overlay.IsBusy) return;

            _overlay.SetBusy(true);
            using var cts = _cts = new CancellationTokenSource();
            _writing = false;
            var targetWindow = Native.GetForegroundWindow();
            bool previewing = true; // late streamed updates must not re-show the bubble after the request ended
            try
            {
                var field = await TextAccess.ReadAsync(target.Element);
                DebugLog.Write($"read {field.Text.Length} chars from field");
                if (string.IsNullOrWhiteSpace(field.Text))
                {
                    _notify($"Nothing to {action.Verb().ToLowerInvariant()}", "The text field is empty.", NoticeLevel.Info);
                    return;
                }

                // The text streams into a bubble beside the button while the model writes it; the field itself is
                // only touched once the final text is in.
                var result = await ParaphraseClient.RunAsync(field.Text, _settings, action, cts.Token,
                    partial => _dispatcher.BeginInvoke(() =>
                    {
                        if (previewing && !cts.IsCancellationRequested) _bubble.ShowText(partial, _overlay.Area);
                    }));
                previewing = false;
                _bubble.HideBubble();

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

                _writing = true;
                await TextAccess.ReplaceAsync(field, result, target.Element);
                DebugLog.Write("field replaced");
            }
            catch (OperationCanceledException) when (cts.IsCancellationRequested)
            {
                DebugLog.Write($"{action} cancelled by the user");
            }
            catch (Exception ex)
            {
                DebugLog.Write($"{action} failed: {ex.GetType().Name}: {ex.Message}");
                _notify($"{action.Verb()} failed", ex.Message, NoticeLevel.Error);
            }
            finally
            {
                previewing = false;
                _bubble.HideBubble();
                _cts = null;
                _writing = false;
                _overlay.SetBusy(false);
            }
        }
    }
}
