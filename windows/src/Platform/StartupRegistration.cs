using System;
using Microsoft.Win32;

namespace ParaphraseTool.Platform
{
    /// <summary>Registers or removes the app in the per-user Windows "Run at login" list.</summary>
    public static class StartupRegistration
    {
        const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        const string ValueName = "ParaphraseTool";

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
