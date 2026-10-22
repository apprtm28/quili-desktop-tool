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
        DispatcherTimer? _summaryHide; // auto-hides the summary bubble

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

        /// <summary>
        /// Tray action: reads the Slack thread open in the last app window the user was in and shows its summary
        /// above the tray. Never writes to Slack; the summary is also copied to the clipboard.
        /// </summary>
        public void SummarizeThread()
        {
            if (_cts != null || _overlay.IsBusy) return;
            _ = SummarizeAsync();
        }

        async Task SummarizeAsync()
        {
            var action = TextAction.SummarizeThread;
            var window = _tracker.LastOtherWindow;
            if (window == IntPtr.Zero || !ThreadReader.IsSlack(window))
            {
                _notify("Open a Slack thread first", "Switch to Slack, open the thread, then choose Summarize Slack thread.", NoticeLevel.Info);
                return;
            }
            DebugLog.Write("summarize clicked");

            using var cts = _cts = new CancellationTokenSource();
            _summaryHide?.Stop();
            var work = System.Windows.Forms.Screen.PrimaryScreen!.WorkingArea;
            var anchor = new System.Drawing.Rectangle(work.Right - 1, work.Bottom - 1, 1, 1); // just above the tray
            bool previewing = true; // late streamed updates must not re-show the bubble after the request ended
            bool keepBubble = false;
            _bubble.ShowText("Reading the thread…", anchor, tall: true);
            try
            {
                var thread = await Task.Run(() => ThreadReader.Read(window), cts.Token);
                if (thread == null || thread.Text.Trim().Length <= 20)
                {
                    _notify("No thread found", "Open the thread in Slack's side pane (click its replies link) and try again.", NoticeLevel.Info);
                    return;
                }
                DebugLog.Write($"read {thread.Text.Length} chars from the thread{(thread.Truncated ? " (oldest messages dropped)" : "")}");

                var result = await ParaphraseClient.RunAsync(thread.Text, _settings, action, cts.Token,
                    partial => _dispatcher.BeginInvoke(() =>
                    {
                        if (previewing && !cts.IsCancellationRequested) _bubble.ShowText(partial, anchor, tall: true);
                    }));
                previewing = false;
                TextAccess.TrySetClipboard(result);
                _bubble.ShowText(result, anchor, tall: true);
                keepBubble = true;
                _notify("Thread summarized", "The summary was copied to the clipboard.", NoticeLevel.Info);

                // The bubble is click-through, so it goes away on its own.
                _summaryHide ??= new DispatcherTimer { Interval = TimeSpan.FromSeconds(25) };
                _summaryHide.Tick -= HideSummary;
                _summaryHide.Tick += HideSummary;
                _summaryHide.Start();
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
                if (!keepBubble) _bubble.HideBubble();
                _cts = null;
            }
        }

        void HideSummary(object? sender, EventArgs e)
        {
            _summaryHide?.Stop();
            _bubble.HideBubble();
        }

        async Task RunAsync(TextAction action)
        {
            var target = _current;
            DebugLog.Write($"{action} clicked (target={(target == null ? "none" : "set")}, busy={_overlay.IsBusy})");
            if (target == null || _overlay.IsBusy || _cts != null) return;

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
