using System.Diagnostics;
using System.Windows;
using System.Windows.Navigation;
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
        }

        void RepoLink_RequestNavigate(object sender, RequestNavigateEventArgs e)
        {
            Process.Start(new ProcessStartInfo(AppInfo.RepoUrl) { UseShellExecute = true });
            e.Handled = true;
        }

        void Save_Click(object sender, RoutedEventArgs e)
        {
            _settings.ApiKey = KeyBox.Password.Trim();
            _settings.ServerUrl = ParaphraseClient.NormalizeServerUrl(ServerBox.Text);
            _settings.Style = string.IsNullOrWhiteSpace(StyleBox.Text) ? Settings.DefaultStyle : StyleBox.Text.Trim();
            _settings.RunAtStartup = StartupBox.IsChecked == true;
            _settings.Save();
            DialogResult = true;
        }
    }
}
