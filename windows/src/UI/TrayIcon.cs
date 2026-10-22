using System;
using System.Drawing;
using System.Windows.Forms;
using Quili.Core;

namespace Quili.UI
{
    /// <summary>Notification-area icon with the Settings / Pause / Exit menu and balloon notices.</summary>
    public sealed class TrayIcon : IDisposable
    {
        readonly NotifyIcon _icon;

        public TrayIcon(Action showSettings, Action<bool> pausedChanged, Action exit)
        {
            var menu = new ContextMenuStrip();
            menu.Items.Add("Settings…", null, (_, _) => showSettings());
            var pause = new ToolStripMenuItem("Pause") { CheckOnClick = true };
            pause.CheckedChanged += (_, _) => pausedChanged(pause.Checked);
            menu.Items.Add(pause);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Exit", null, (_, _) => exit());

            _icon = new NotifyIcon
            {
                Icon = LoadIcon(),
                Text = $"Quili {AppInfo.Version}",
                ContextMenuStrip = menu,
                Visible = true,
            };
            _icon.DoubleClick += (_, _) => showSettings();
        }

        /// <summary>The robot icon, embedded in the exe; the stock application icon if it can't be read.</summary>
        static Icon LoadIcon()
        {
            try
            {
                var resource = System.Windows.Application.GetResourceStream(new Uri("pack://application:,,,/assets/app.ico"));
                if (resource != null) return new Icon(resource.Stream);
            }
            catch (Exception) { }
            return SystemIcons.Application;
        }

        public void Notify(string title, string message, NoticeLevel level) =>
            _icon.ShowBalloonTip(4000, title, message, level == NoticeLevel.Error ? ToolTipIcon.Error : ToolTipIcon.Info);

        public void Dispose()
        {
            _icon.Visible = false;
            _icon.Dispose();
        }
    }
}
