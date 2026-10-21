using System;
using Microsoft.Win32;

namespace Quili.Platform
{
    /// <summary>Registers or removes the app in the per-user Windows "Run at login" list.</summary>
    public static class StartupRegistration
    {
        const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        const string ValueName = "Quili";
        const string LegacyValueName = "ParaphraseTool"; // the app's name before it became Quili

        /// <summary>Moves a startup entry registered by the old app to the current name, pointing at this exe.</summary>
        public static void MigrateLegacy()
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: true);
            if (key == null || key.GetValue(LegacyValueName) == null) return;
            key.DeleteValue(LegacyValueName, throwOnMissingValue: false);
            key.SetValue(ValueName, $"\"{Environment.ProcessPath}\"");
        }

        public static void Apply(bool enabled)
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: true);
            if (key == null) return;
            if (enabled)
                key.SetValue(ValueName, $"\"{Environment.ProcessPath}\"");
            else
                key.DeleteValue(ValueName, throwOnMissingValue: false);
        }
    }
}
