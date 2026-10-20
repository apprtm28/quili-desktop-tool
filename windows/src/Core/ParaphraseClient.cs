using System;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace ParaphraseTool.Core
{
    public static class ParaphraseClient
    {
        static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(120) };

        /// <summary>Accepts either the base URL or the full endpoint URL and returns the base URL.</summary>
        public static string NormalizeServerUrl(string? url)
        {
            var u = (url ?? "").Trim().TrimEnd('/');
            const string endpoint = "/api/paraphrase";
            if (u.EndsWith(endpoint, StringComparison.OrdinalIgnoreCase)) u = u[..^endpoint.Length].TrimEnd('/');
            return u;
        }

        public static async Task<string> ParaphraseAsync(string text, Settings settings, CancellationToken ct = default)
        {
            var apiKey = settings.ApiKey;
            var serverUrl = NormalizeServerUrl(settings.ServerUrl);
            if (string.IsNullOrWhiteSpace(apiKey) || string.IsNullOrWhiteSpace(serverUrl))
                throw new InvalidOperationException("Server URL or API key not set. Open Settings from the tray icon.");

            DebugLog.Write($"paraphrase request: POST {serverUrl}/api/paraphrase ({text.Length} chars)");
            var body = JsonSerializer.Serialize(new { text, style = settings.Style });

            using var req = new HttpRequestMessage(HttpMethod.Post, serverUrl + "/api/paraphrase")
            {
                Content = new StringContent(body, Encoding.UTF8, "application/json"),
            };
            req.Headers.Add("X-API-Key", apiKey);

            using var resp = await Http.SendAsync(req, ct).ConfigureAwait(false);
            var json = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);

            DebugLog.Write($"paraphrase response: HTTP {(int)resp.StatusCode}");
            if (!resp.IsSuccessStatusCode)
            {
                string msg = json;
                try
                {
                    var detail = JsonDocument.Parse(json).RootElement.GetProperty("detail");
                    msg = detail.ValueKind == JsonValueKind.String ? detail.GetString() ?? json : detail.ToString();
                }
                catch (Exception) { }
                throw new InvalidOperationException($"Paraphrase server error {(int)resp.StatusCode}: {msg}");
            }

            using var doc = JsonDocument.Parse(json);
            var content = doc.RootElement.GetProperty("text").GetString();
            if (string.IsNullOrWhiteSpace(content))
                throw new InvalidOperationException("Paraphrase server returned an empty response.");
            return content.Trim();
        }
    }
}
