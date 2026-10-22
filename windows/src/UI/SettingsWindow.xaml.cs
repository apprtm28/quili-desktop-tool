using System;
using System.Diagnostics;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Navigation;
using Quili.Platform;
using Quili.Core;

namespace Quili.UI
{
    public partial class SettingsWindow : Window
    {
        readonly Settings _settings;

        public SettingsWindow(Settings settings)
        {
            InitializeComponent();
            _settings = settings;
            VersionText.Text = $"Version {AppInfo.Version}";
            KeyBox.Password = settings.ApiKey;
            ServerBox.Text = ParaphraseClient.NormalizeServerUrl(settings.ServerUrl);
            StyleBox.Text = settings.Style;
            StartupBox.IsChecked = settings.RunAtStartup;
            MockBox.IsChecked = settings.MockMode;
            LogBox.IsChecked = settings.LoggingEnabled;
            ContentRendered += (_, _) => BringToFront();
        }

        /// <summary>
        /// Opened from the overlay (a window that never takes focus), Settings could otherwise appear behind the
        /// app the user was in. Raise it above everything and give it focus.
        /// </summary>
        void BringToFront()
        {
            Topmost = true;   // raises it above other windows even if Windows refuses to hand over focus
            Native.ForceForeground(new WindowInteropHelper(this).Handle);
            Activate();
            Topmost = false;
        }

        void RepoLink_RequestNavigate(object sender, RequestNavigateEventArgs e)
        {
            Process.Start(new ProcessStartInfo(AppInfo.RepoUrl) { UseShellExecute = true });
            e.Handled = true;
        }

        // The card has no title bar: the header is the drag handle, and the X closes without saving.
        void Header_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
        {
            if (e.ButtonState == MouseButtonState.Pressed) DragMove();
        }

        void Close_Click(object sender, RoutedEventArgs e) => Close();

        /// <summary>Switches the API key between dots and plain text, carrying what was typed across.</summary>
        void ToggleKey_Click(object sender, RoutedEventArgs e)
        {
            bool reveal = KeyPlain.Visibility != Visibility.Visible;
            if (reveal)
            {
                KeyPlain.Text = KeyBox.Password;
                KeyPlain.Visibility = Visibility.Visible;
                KeyBox.Visibility = Visibility.Collapsed;
                KeyPlain.Focus();
                KeyPlain.CaretIndex = KeyPlain.Text.Length;
            }
            else
            {
                KeyBox.Password = KeyPlain.Text;
                KeyBox.Visibility = Visibility.Visible;
                KeyPlain.Visibility = Visibility.Collapsed;
                KeyBox.Focus();
            }
            EyeIcon.Data = (Geometry)FindResource(reveal ? "EyeGeometry" : "EyeOffGeometry");
        }

        void Save_Click(object sender, RoutedEventArgs e)
        {
            var key = KeyPlain.Visibility == Visibility.Visible ? KeyPlain.Text : KeyBox.Password;
            _settings.ApiKey = key.Trim();
            _settings.ServerUrl = ParaphraseClient.NormalizeServerUrl(ServerBox.Text);
            _settings.Style = string.IsNullOrWhiteSpace(StyleBox.Text) ? Settings.DefaultStyle : StyleBox.Text.Trim();
            _settings.RunAtStartup = StartupBox.IsChecked == true;
            ApplyMock(MockBox.IsChecked == true);
            ApplyLogging(LogBox.IsChecked == true);
            _settings.Save();
            DialogResult = true;
        }

        /// <summary>Turns the debug log on or off, leaving a note in the log either way (the last line before it goes quiet).</summary>
        void ApplyLogging(bool on)
        {
            if (on == _settings.LoggingEnabled) return;
            if (!on) DebugLog.Write("debug log turned off in Settings");
            _settings.LoggingEnabled = on;
            DebugLog.Enabled = on;
            if (on) DebugLog.Write("debug log turned on in Settings");
        }

        /// <summary>Turns the built-in mock server on (and starts it) or off (and stops it).</summary>
        void ApplyMock(bool on)
        {
            _settings.MockMode = on;
            if (!on) { MockServer.Shared.Stop(); return; }
            try { MockServer.Shared.Start(); }
            catch (Exception ex)
            {
                _settings.MockMode = false;
                DebugLog.Write($"mock server failed to start: {ex.GetType().Name}: {ex.Message}");
                System.Windows.MessageBox.Show(ex.Message, "Mock server failed", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }
    }
}
