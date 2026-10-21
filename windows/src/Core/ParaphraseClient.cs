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
        // A dead or stale connection fails fast (connect timeout, short idle lifetime) and is retried once,
        // so a restart on the server costs seconds instead of a long hang.
        static readonly HttpClient Http = new(new SocketsHttpHandler
        {
            ConnectTimeout = TimeSpan.FromSeconds(8),
            PooledConnectionIdleTimeout = TimeSpan.FromSeconds(45),
            PooledConnectionLifetime = TimeSpan.FromMinutes(5),
        }) { Timeout = TimeSpan.FromSeconds(45) };

        /// <summary>Accepts either the base URL or the full endpoint URL and returns the base URL.</summary>
        public static string NormalizeServerUrl(string? url)
        {
            var u = (url ?? "").Trim().TrimEnd('/');
            foreach (var endpoint in new[] { "/api/paraphrase", "/api/translate" })
                if (u.EndsWith(endpoint, StringComparison.OrdinalIgnoreCase))
                    u = u[..^endpoint.Length].TrimEnd('/');
            return u;
        }

        public static Task<string> ParaphraseAsync(string text, Settings settings, CancellationToken ct = default) =>
            RunAsync(text, settings, TextAction.Paraphrase, ct);

        public static async Task<string> RunAsync(string text, Settings settings, TextAction action, CancellationToken ct = default)
        {
            var apiKey = settings.ApiKey;
            var serverUrl = NormalizeServerUrl(settings.ServerUrl);
            if (string.IsNullOrWhiteSpace(apiKey) || string.IsNullOrWhiteSpace(serverUrl))
                throw new InvalidOperationException("Server URL or API key not set. Open Settings from the tray icon.");

            text = TextHygiene.StripLoneSurrogates(text);
            DebugLog.Write($"{action} request: POST {serverUrl}{action.Path()} ({TextHygiene.Describe(text)})");
            // The default encoder escapes every non-ASCII character (\uD83D\uDE00), so emoji cannot be
            // mangled in transit; the body is also sent explicitly as UTF-8.
            // Paraphrase carries the user's instruction; translate always targets English.
            var body = action == TextAction.TranslateToEnglish
                ? JsonSerializer.Serialize(new { text, target_language = "English" })
                : JsonSerializer.Serialize(new { text, style = TextHygiene.StripLoneSurrogates(settings.EffectiveStyle) });

            HttpRequestMessage NewRequest()
            {
                var req = new HttpRequestMessage(HttpMethod.Post, serverUrl + action.Path())
                {
                    Content = new StringContent(body, new UTF8Encoding(false), "application/json"),
                };
                req.Headers.Add("X-API-Key", apiKey);
                return req;
            }

            HttpResponseMessage resp;
            try
            {
                using var first = NewRequest();
                resp = await Http.SendAsync(first, ct).ConfigureAwait(false);
            }
            catch (HttpRequestException ex)
            {
                // Connection-level failure (no HTTP response at all): safe to try once more.
                DebugLog.Write($"{action} connection failed ({ex.Message}); retrying once");
                using var second = NewRequest();
                resp = await Http.SendAsync(second, ct).ConfigureAwait(false);
            }
            catch (TaskCanceledException) when (!ct.IsCancellationRequested)
            {
                throw new TimeoutException("The server took too long to respond.");
            }

            using var _ = resp;
            // Decode as UTF-8 ourselves rather than trusting a missing/incorrect charset header.
            var json = Encoding.UTF8.GetString(await resp.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false));

            DebugLog.Write($"{action} response: HTTP {(int)resp.StatusCode}");
            if (!resp.IsSuccessStatusCode)
            {
                string msg = json;
                try
                {
                    var detail = JsonDocument.Parse(json).RootElement.GetProperty("detail");
                    msg = detail.ValueKind == JsonValueKind.String ? detail.GetString() ?? json : detail.ToString();
                }
                catch (Exception) { }
                throw new InvalidOperationException($"{action.Verb()} server error {(int)resp.StatusCode}: {msg}");
            }

            using var doc = JsonDocument.Parse(json);
            var content = doc.RootElement.GetProperty("text").GetString();
            if (string.IsNullOrWhiteSpace(content))
                throw new InvalidOperationException("Paraphrase server returned an empty response.");
            content = TextHygiene.StripLoneSurrogates(content).Trim();
            DebugLog.Write($"{action} result: {TextHygiene.Describe(content)}");
            return content;
        }
    }
}
