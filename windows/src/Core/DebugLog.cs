using System;
using System.IO;

namespace ParaphraseTool.Core
{
    /// <summary>Tiny append-only log at %APPDATA%\ParaphraseTool\debug.log for diagnosing field detection.</summary>
    public static class DebugLog
    {
        static readonly string FilePath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ParaphraseTool", "debug.log");
        static readonly object Gate = new();

        public static void Write(string message)
        {
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
