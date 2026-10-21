using System.Reflection;

namespace ParaphraseTool.Core
{
    public static class AppInfo
    {
        /// <summary>The version from the repo's VERSION file, e.g. "1.0.0".</summary>
        public static string Version { get; } = ReadVersion();

        static string ReadVersion()
        {
            var v = typeof(AppInfo).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
            if (string.IsNullOrEmpty(v)) return "dev";
            var plus = v.IndexOf('+'); // the SDK appends "+<git hash>"
            return plus >= 0 ? v[..plus] : v;
        }
    }
}
