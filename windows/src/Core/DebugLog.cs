using System;
using System.IO;

namespace Quili.Core
{
    /// <summary>Tiny append-only log at %APPDATA%\Quili\debug.log for diagnosing field detection.</summary>
    public static class DebugLog
    {
        static readonly string FilePath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Quili", "debug.log");
        static readonly object Gate = new();

        /// <summary>The "Write debug log" setting; on unless switched off.</summary>
        public static volatile bool Enabled = true;

        public static void Write(string message)
        {
            if (!Enabled) return;
            try
            {
                lock (Gate)
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
                    if (File.Exists(FilePath) && new FileInfo(FilePath).Length > 1_000_000) File.Delete(FilePath);
                    File.AppendAllText(FilePath, $"{DateTime.Now:HH:mm:ss.fff} {message}{Environment.NewLine}");
                }
            }
            catch (Exception) { }
        }
    }
}
