using System;
using System.Threading;
using System.Windows;
using Quili.Core;
using Quili.UI;

namespace Quili
{
    public partial class App : System.Windows.Application
    {
        Mutex? _singleInstance;
        TrayIcon? _tray;
        ParaphraseController? _controller;
        Settings _settings = new();

        protected override void OnStartup(StartupEventArgs e)
        {
            base.OnStartup(e);

            _singleInstance = new Mutex(true, "Quili.SingleInstance", out bool isNew);
            if (!isNew) { Shutdown(); return; }

            _settings = Settings.Load();
            DebugLog.Enabled = _settings.LoggingEnabled;
            if (_settings.MockMode)
            {
                try { MockServer.Shared.Start(); }
                catch (Exception ex) { DebugLog.Write($"mock server failed to start: {ex.GetType().Name}: {ex.Message}"); }
            }

            _tray = new TrayIcon(ShowSettings, paused => _controller!.Paused = paused, Shutdown);
            _controller = new ParaphraseController(_settings, Dispatcher, _tray.Notify);
            _controller.SettingsRequested += ShowSettings;
            _controller.Start();

            if (string.IsNullOrEmpty(_settings.ApiKey) || string.IsNullOrEmpty(_settings.ServerUrl)) ShowSettings();
        }

        protected override void OnExit(ExitEventArgs e)
        {
            _controller?.Dispose();
            _tray?.Dispose();
            _singleInstance?.Dispose();
            base.OnExit(e);
        }

        void ShowSettings() => new SettingsWindow(_settings).ShowDialog();
    }
}
