using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using ParaphraseTool.Platform;

namespace ParaphraseTool.Core
{
    public class Settings
    {
        public const string DefaultStyle = "Paraphrase it with clearly different wording while keeping the meaning and a natural tone.";
        const string LegacyDefaultStyle = "Keep the meaning, improve clarity and flow, and keep a natural tone.";
        public const int MaxStyleLength = 1000;

        public string ApiKeyProtected { get; set; } = "";
        public string ServerUrl { get; set; } = "";
        public string Style { get; set; } = DefaultStyle;
        public bool RunAtStartup { get; set; }

        static readonly string Dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ParaphraseTool");
        static readonly string FilePath = Path.Combine(Dir, "settings.json");

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

        /// <summary>The instruction sent to the server as the paraphrase command (never empty, length-capped).</summary>
        [JsonIgnore]
        public string EffectiveStyle
        {
            get
            {
                var s = (Style ?? "").Trim();
                if (s.Length == 0) return DefaultStyle;
                return s.Length > MaxStyleLength ? s[..MaxStyleLength] : s;
            }
        }

        public static Settings Load()
        {
            try
            {
                if (File.Exists(FilePath))
                {
                    var loaded = JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath)) ?? new Settings();
                    // The old default only asked for a light edit; move users who never changed it to the new one.
                    if (string.IsNullOrWhiteSpace(loaded.Style) || loaded.Style.Trim() == LegacyDefaultStyle)
                        loaded.Style = DefaultStyle;
                    return loaded;
                }
            }
            catch (Exception) { }
            return new Settings();
        }

        public void Save()
        {
            Directory.CreateDirectory(Dir);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
            StartupRegistration.Apply(RunAtStartup);
        }
    }
}
