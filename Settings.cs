using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Win32;

namespace ParaphraseTool
{
    public class Settings
    {
        public const string DefaultStyle = "Keep the meaning, improve clarity and flow, and keep a natural tone.";

        public string ApiKeyProtected { get; set; } = "";
        public string ServerUrl { get; set; } = "";
        public string Style { get; set; } = DefaultStyle;
        public bool RunAtStartup { get; set; }

        static readonly string Dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ParaphraseTool");
        static readonly string FilePath = Path.Combine(Dir, "settings.json");
        const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

        [JsonIgnore]
        public string ApiKey
        {
            get
            {
                if (string.IsNullOrEmpty(ApiKeyProtected)) return "";
                try
                {
                    var bytes = ProtectedData.Unprotect(
                        Convert.FromBase64String(ApiKeyProtected), null, DataProtectionScope.CurrentUser);
                    return Encoding.UTF8.GetString(bytes);
                }
                catch (CryptographicException) { return ""; }
            }
            set
            {
                ApiKeyProtected = string.IsNullOrEmpty(value)
                    ? ""
                    : Convert.ToBase64String(ProtectedData.Protect(
                        Encoding.UTF8.GetBytes(value), null, DataProtectionScope.CurrentUser));
            }
        }

        public static Settings Load()
        {
            try
            {
                if (File.Exists(FilePath))
                    return JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath)) ?? new Settings();
            }
            catch (Exception) { }
            return new Settings();
        }

        public void Save()
        {
            Directory.CreateDirectory(Dir);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
            ApplyStartup();
        }

        void ApplyStartup()
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: true);
            if (key == null) return;
            if (RunAtStartup)
                key.SetValue("ParaphraseTool", $"\"{Environment.ProcessPath}\"");
            else
                key.DeleteValue("ParaphraseTool", throwOnMissingValue: false);
        }
    }
}
