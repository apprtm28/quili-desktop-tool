using System;
using System.Drawing;
using System.Threading;
using System.Windows;
using System.Windows.Forms;

namespace ParaphraseTool
{
    public partial class App : System.Windows.Application
    {
        Mutex? _singleInstance;
        NotifyIcon? _tray;
        FocusTracker? _tracker;
        OverlayWindow? _overlay;
        Settings _settings = new();
        TextTarget? _current;

        protected override void OnStartup(StartupEventArgs e)
        {
            base.OnStartup(e);

            _singleInstance = new Mutex(true, "ParaphraseTool.SingleInstance", out bool isNew);
            if (!isNew) { Shutdown(); return; }

            _settings = Settings.Load();

            _overlay = new OverlayWindow();
            _overlay.Clicked += () => _ = ParaphraseAsync();

            _tracker = new FocusTracker();
            _tracker.TargetChanged += t => Dispatcher.BeginInvoke(() => OnTargetChanged(t));
            _tracker.Start();

            BuildTray();

            if (string.IsNullOrEmpty(_settings.ApiKey) || string.IsNullOrEmpty(_settings.ServerUrl)) ShowSettings();
        }

        protected override void OnExit(ExitEventArgs e)
        {
            _tracker?.Dispose();
            if (_tray != null) { _tray.Visible = false; _tray.Dispose(); }
            _singleInstance?.Dispose();
            base.OnExit(e);
        }

        void BuildTray()
        {
            var menu = new ContextMenuStrip();
            menu.Items.Add("Settings…", null, (_, _) => ShowSettings());
            var pause = new ToolStripMenuItem("Pause") { CheckOnClick = true };
            pause.CheckedChanged += (_, _) =>
            {
                _tracker!.Paused = pause.Checked;
                if (pause.Checked) _overlay!.HideOverlay();
            };
            menu.Items.Add(pause);
            menu.Items.Add("Exit", null, (_, _) => Shutdown());

            _tray = new NotifyIcon
            {
                Icon = SystemIcons.Application,
                Text = "Paraphrase Tool",
                ContextMenuStrip = menu,
                Visible = true,
            };
            _tray.DoubleClick += (_, _) => ShowSettings();
        }

        void ShowSettings() => new SettingsWindow(_settings).ShowDialog();

        void OnTargetChanged(TextTarget? target)
        {
            // Keep the button where it is while a request is running; the result is validated afterwards.
            if (_overlay!.IsBusy) return;

            _current = target;
            if (target == null) _overlay.HideOverlay();
            else _overlay.ShowAt(target.Bounds);
        }

        async System.Threading.Tasks.Task ParaphraseAsync()
        {
            var target = _current;
            DebugLog.Write($"button clicked (target={(target == null ? "none" : "set")}, busy={_overlay!.IsBusy})");
            if (target == null || _overlay!.IsBusy) return;

            _overlay.SetBusy(true);
            try
            {
                var field = await TextAccess.ReadAsync(target.Element);
                var original = field.Text;
                DebugLog.Write($"read {original?.Length ?? 0} chars from field");
                if (string.IsNullOrWhiteSpace(original))
                {
                    Notify("Nothing to paraphrase", "The text field is empty.", ToolTipIcon.Info);
                    return;
                }

                var result = await ParaphraseClient.ParaphraseAsync(original, _settings);

                if (!FocusTracker.StillFocused(target.Element))
                {
                    TextAccess.TrySetClipboard(result);
                    Notify("Focus changed", "Paraphrased text was copied to the clipboard instead.", ToolTipIcon.Info);
                    return;
                }

                await TextAccess.ReplaceAsync(field, result);
                DebugLog.Write("field replaced");
            }
            catch (Exception ex)
            {
                DebugLog.Write($"paraphrase failed: {ex.GetType().Name}: {ex.Message}");
                Notify("Paraphrase failed", ex.Message, ToolTipIcon.Error);
            }
            finally
            {
                _overlay.SetBusy(false);
            }
        }

        void Notify(string title, string message, ToolTipIcon icon) =>
            _tray?.ShowBalloonTip(4000, title, message, icon);
    }
}
