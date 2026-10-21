using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Quili.Platform;

namespace Quili.Core
{
    public class Settings
    {
        public const string DefaultStyle =
            "Polish the provided text to improve grammar, verb tenses, clarity, and natural flow while preserving the original meaning, tone, and intent.\n\nKeep the wording and sentence structure as close to the original as possible, making only necessary adjustments. Use natural, conversational English without making it overly formal or complicated.\n\nReturn only the revised text, without explanations or additional commentary.";
        // Earlier defaults: anyone still on one of these never customised it and moves to the current default.
        static readonly string[] LegacyDefaultStyles =
        {
            "Keep the meaning, improve clarity and flow, and keep a natural tone.",
            "Paraphrase it with clearly different wording while keeping the meaning and a natural tone.",
        };
        public const int MaxStyleLength = 1000;

        public string ApiKeyProtected { get; set; } = "";
        public string ServerUrl { get; set; } = "";
        public string Style { get; set; } = DefaultStyle;
        public bool RunAtStartup { get; set; }

        static readonly string Dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Quili");
        static readonly string FilePath = Path.Combine(Dir, "settings.json");
        // Quili was called "Paraphrase Tool" before; its settings live here.
        static readonly string LegacyFilePath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ParaphraseTool", "settings.json");

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

        /// <summary>First launch after the rename: carry the old app's settings (server URL, instruction, API key, startup entry) over.</summary>
        static void MigrateFromParaphraseTool()
        {
            try
            {
                if (File.Exists(FilePath) || !File.Exists(LegacyFilePath)) return;
                Directory.CreateDirectory(Dir);
                File.Copy(LegacyFilePath, FilePath); // the API key is DPAPI-protected per user, so it still decrypts
                StartupRegistration.MigrateLegacy();
                DebugLog.Write("migrated settings from the old Paraphrase Tool app");
            }
            catch (Exception) { }
        }

        public static Settings Load()
        {
            MigrateFromParaphraseTool();
            try
            {
                if (File.Exists(FilePath))
                {
                    var loaded = JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath)) ?? new Settings();
                    // Move users who never changed the default to the current one.
                    if (string.IsNullOrWhiteSpace(loaded.Style) || Array.IndexOf(LegacyDefaultStyles, loaded.Style.Trim()) >= 0)
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
