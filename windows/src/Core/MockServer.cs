using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Quili.Core
{
    /// <summary>
    /// A built-in stand-in for the Senwich server, for when the real one is down: answers every Quili endpoint
    /// (<c>/api/paraphrase</c>, <c>/api/translate</c>, <c>/api/summarize-thread</c>) with fixed, pre-written text
    /// whatever it is sent, on a loopback port picked by the system. It speaks the real server's wire format: with
    /// <c>"stream": true</c> it sends <c>delta</c> events (the text so far, each replacing the previous) and one
    /// <c>done</c>, otherwise plain JSON. Any other path answers 404. Started and stopped by the "Mock server
    /// (offline)" setting.
    /// </summary>
    public sealed class MockServer
    {
        public static readonly MockServer Shared = new();

        public const string Summary =
            "The team discussed the failed deploy of the order service and agreed on a rollback plan.\n" +
            "\n" +
            "Timeline:\n" +
            "- [Today at 14:10] Rina: deployed the order service release; checkout errors (5xx) started.\n" +
            "- [Today at 14:25] Rina: rolled the release back; error rates returned to normal.\n" +
            "- [Today at 14:40] Dani: found the root cause: a config change cut the database connection pool from 50 to 5.\n" +
            "- [Today at 14:52] Dani: confirmed the fix is a one-line revert and will ship it behind a canary first.\n" +
            "\n" +
            "Key information:\n" +
            "- db.pool.size: 50 -> 5 (config change)\n" +
            "- order-service release 2.14.0 (rolled back)\n" +
            "- checkout 5xx errors, 14:10-14:25\n" +
            "- canary: 10%\n" +
            "- @dani, @rina\n" +
            "\n" +
            "Open items:\n" +
            "- Dani: ship the config revert to 10% canary and report back before full rollout.\n" +
            "- Rina: add an alert for connection pool saturation.\n" +
            "- Everyone: add the pool size to the pre-deploy checklist.";

        /// <summary>The canned answer for each endpoint.</summary>
        static readonly Dictionary<string, string> Replies = new()
        {
            ["/api/paraphrase"] = "This is a pre-generated paraphrase returned by Quili's offline mock server.",
            ["/api/translate"] = "This is a pre-generated English translation returned by Quili's offline mock server.",
            ["/api/summarize-thread"] = Summary,
        };

        const int Chunk = 12;
        static readonly TimeSpan ChunkDelay = TimeSpan.FromMilliseconds(50);

        sealed record Request(string Path, bool Stream, int TextLength);

        readonly object _gate = new();
        TcpListener? _listener;
        CancellationTokenSource? _cts;
        int _port;

        /// <summary><c>http://127.0.0.1:&lt;port&gt;</c> while the server is running.</summary>
        public string? BaseUrl
        {
            get { lock (_gate) return _listener == null ? null : $"http://127.0.0.1:{_port}"; }
        }

        /// <summary>Starts listening (a no-op when already running) and returns the base URL.</summary>
        public string Start()
        {
            lock (_gate)
            {
                if (_listener != null) return $"http://127.0.0.1:{_port}";
                var listener = new TcpListener(IPAddress.Loopback, 0);
                listener.Start();
                _port = ((IPEndPoint)listener.LocalEndpoint).Port;
                _listener = listener;
                _cts = new CancellationTokenSource();
                _ = AcceptLoopAsync(listener, _cts.Token);
                DebugLog.Write($"mock server listening on 127.0.0.1:{_port}");
                return $"http://127.0.0.1:{_port}";
            }
        }

        public void Stop()
        {
            lock (_gate)
            {
                if (_listener == null) return;
                _cts?.Cancel();
                _listener.Stop();
                _listener = null;
                _cts = null;
            }
            DebugLog.Write("mock server stopped");
        }

        // ---- Connections ----

        static async Task AcceptLoopAsync(TcpListener listener, CancellationToken ct)
        {
            while (!ct.IsCancellationRequested)
            {
                TcpClient client;
                try { client = await listener.AcceptTcpClientAsync(ct).ConfigureAwait(false); }
                catch (Exception) { return; } // stopped
                _ = Task.Run(() => HandleAsync(client, ct));
            }
        }

        static async Task HandleAsync(TcpClient client, CancellationToken ct)
        {
            using (client)
            {
                try
                {
                    var stream = client.GetStream();
                    var request = await ReadRequestAsync(stream, ct).ConfigureAwait(false);
                    if (request != null) await RespondAsync(stream, request, ct).ConfigureAwait(false);
                }
                catch (Exception) { /* the client went away mid-response */ }
            }
        }

        static async Task<Request?> ReadRequestAsync(NetworkStream stream, CancellationToken ct)
        {
            var buffer = new List<byte>();
            var chunk = new byte[8192];
            while (buffer.Count < 2_000_000)
            {
                int n = await stream.ReadAsync(chunk, ct).ConfigureAwait(false);
                if (n == 0) return null;
                buffer.AddRange(new ArraySegment<byte>(chunk, 0, n));
                var request = Parse(buffer.ToArray());
                if (request != null) return request;
            }
            return null;
        }

        /// <summary>The request once its headers and whole body have arrived, else null.</summary>
        static Request? Parse(byte[] data)
        {
            int split = IndexOf(data, new byte[] { 13, 10, 13, 10 });
            if (split < 0) return null;
            var lines = Encoding.UTF8.GetString(data, 0, split).Split("\r\n");
            var parts = lines[0].Split(' ');
            if (parts.Length < 2) return null;

            int length = 0;
            foreach (var line in lines)
                if (line.StartsWith("content-length:", StringComparison.OrdinalIgnoreCase))
                    int.TryParse(line["content-length:".Length..].Trim(), out length);
            int bodyStart = split + 4;
            if (data.Length - bodyStart < length) return null;

            bool stream = false;
            int textLength = 0;
            try
            {
                using var json = JsonDocument.Parse(new ReadOnlyMemory<byte>(data, bodyStart, length));
                if (json.RootElement.TryGetProperty("stream", out var s) && s.ValueKind == JsonValueKind.True) stream = true;
                if (json.RootElement.TryGetProperty("text", out var t) && t.ValueKind == JsonValueKind.String)
                    textLength = t.GetString()!.Length;
            }
            catch (JsonException) { }
            return new Request(parts[1], stream, textLength);
        }

        static int IndexOf(byte[] data, byte[] pattern)
        {
            for (int i = 0; i <= data.Length - pattern.Length; i++)
            {
                int j = 0;
                while (j < pattern.Length && data[i + j] == pattern[j]) j++;
                if (j == pattern.Length) return i;
            }
            return -1;
        }

        static async Task RespondAsync(NetworkStream stream, Request request, CancellationToken ct)
        {
            if (!Replies.TryGetValue(request.Path, out var reply))
            {
                await SendAsync(stream, Http(404, new { detail = $"mock server only implements {string.Join(", ", Replies.Keys)}" }), ct).ConfigureAwait(false);
                return;
            }
            DebugLog.Write($"mock server: {request.Path} with {request.TextLength} chars; replying with the canned text");
            var final = new { text = reply, language = "English", model = "mock" };
            if (!request.Stream)
            {
                await SendAsync(stream, Http(200, final), ct).ConfigureAwait(false);
                return;
            }

            await SendAsync(stream, Encoding.ASCII.GetBytes(
                "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"), ct).ConfigureAwait(false);
            for (int end = Chunk; end < reply.Length; end += Chunk)
            {
                await SendAsync(stream, Event("delta", new { text = reply[..end] }), ct).ConfigureAwait(false);
                await Task.Delay(ChunkDelay, ct).ConfigureAwait(false);
            }
            await SendAsync(stream, Event("done", final), ct).ConfigureAwait(false);
        }

        static async Task SendAsync(NetworkStream stream, byte[] data, CancellationToken ct)
        {
            await stream.WriteAsync(data, ct).ConfigureAwait(false);
            await stream.FlushAsync(ct).ConfigureAwait(false);
        }

        // The default JSON encoder escapes every non-ASCII character, like the real server, so emoji can't be mis-decoded.
        static byte[] Event(string name, object data) =>
            Encoding.ASCII.GetBytes($"event: {name}\ndata: {JsonSerializer.Serialize(data)}\n\n");

        static byte[] Http(int status, object data)
        {
            var body = Encoding.ASCII.GetBytes(JsonSerializer.Serialize(data));
            var head = Encoding.ASCII.GetBytes(
                $"HTTP/1.1 {status} {(status == 200 ? "OK" : "Not Found")}\r\nContent-Type: application/json\r\nContent-Length: {body.Length}\r\nConnection: close\r\n\r\n");
            var all = new byte[head.Length + body.Length];
            head.CopyTo(all, 0);
            body.CopyTo(all, head.Length);
            return all;
        }
    }
}
