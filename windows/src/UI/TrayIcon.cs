using System;
using System.Drawing;
using System.Windows.Forms;
using ParaphraseTool.Core;

namespace ParaphraseTool.UI
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
            menu.Items.Add("Exit", null, (_, _) => exit());

            _icon = new NotifyIcon
            {
                Icon = SystemIcons.Application,
                Text = $"Paraphrase Tool {AppInfo.Version}",
                ContextMenuStrip = menu,
                Visible = true,
            };
            _icon.DoubleClick += (_, _) => showSettings();
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
