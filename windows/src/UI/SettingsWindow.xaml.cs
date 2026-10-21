using System.Diagnostics;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Navigation;
using ParaphraseTool.Platform;
using ParaphraseTool.Core;

namespace ParaphraseTool.UI
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
            _settings.Save();
            DialogResult = true;
        }
    }
}
