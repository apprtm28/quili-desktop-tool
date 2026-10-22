#!/usr/bin/env python3
"""Stand-in for the Senwich server while it is down: answers POST /api/paraphrase, /api/translate and
/api/summarize-thread with fixed, pre-written text, whatever it is sent. Standard library only.

    python3 tools/mock_server.py [--port 8765] [--delay 0.05]

Then in Quili's Settings set the Server URL to http://127.0.0.1:8765 (any API key works) and use
"Summarize Slack thread". It speaks the real server's wire format: with "stream": true it sends
`delta` events (the text so far, each replacing the previous) and one `done`; otherwise plain JSON.
Every other path answers 404.
"""

import argparse
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SUMMARY = """The team discussed the failed deploy of the order service and agreed on a rollback plan.

- The release at 14:10 caused elevated 5xx errors on checkout; Rina rolled it back at 14:25.
- Root cause: a config change dropped the database connection pool size from 50 to 5.
- Dani confirmed the fix is a one-line revert and will ship it behind a canary first.
- Monitoring showed error rates back to normal after the rollback.

Open items:
- Dani: ship the config revert to 10% canary and report back before full rollout.
- Rina: add an alert for connection pool saturation.
- Everyone: add the pool size to the pre-deploy checklist."""

REPLIES = {
    "/api/paraphrase": "This is a pre-generated paraphrase returned by Quili's offline mock server.",
    "/api/translate": "This is a pre-generated English translation returned by Quili's offline mock server.",
    "/api/summarize-thread": SUMMARY,
}
LANGUAGE = "English"
MODEL = "mock"


def ascii_json(data: object) -> bytes:
    """ASCII-escaped like the real server, so emoji can't be mis-decoded by a client."""
    return json.dumps(data, ensure_ascii=True).encode("ascii")


def sse(event: str, data: object) -> bytes:
    return b"event: " + event.encode() + b"\ndata: " + ascii_json(data) + b"\n\n"


class Handler(BaseHTTPRequestHandler):
    # Close-delimited responses: no Content-Length needed for the event stream.
    protocol_version = "HTTP/1.0"
    delay = 0.05

    def log_message(self, fmt: str, *args: object) -> None:
        print(f"{self.log_date_time_string()} {fmt % args}", flush=True)

    def reply(self, status: int, body: bytes, content_type: str = "application/json") -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self) -> None:  # noqa: N802
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        reply = REPLIES.get(self.path)
        if reply is None:
            self.reply(404, ascii_json({"detail": f"mock server only implements {', '.join(REPLIES)}"}))
            return
        try:
            body = json.loads(raw or b"{}")
        except ValueError:
            body = {}
        text = body.get("text", "") if isinstance(body, dict) else ""
        stream = bool(body.get("stream")) if isinstance(body, dict) else False
        print(f"  {self.path}: {len(text)} chars received; replying with the canned text", flush=True)

        final = {"text": reply, "language": LANGUAGE, "model": MODEL}
        if not stream:
            self.reply(200, ascii_json(final))
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        try:
            for end in range(12, len(reply), 12):
                self.wfile.write(sse("delta", {"text": reply[:end]}))
                self.wfile.flush()
                time.sleep(self.delay)
            self.wfile.write(sse("done", final))
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            print("  client disconnected mid-stream", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--delay", type=float, default=0.05, help="seconds between streamed chunks")
    args = parser.parse_args()
    Handler.delay = args.delay
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"Mock server on http://{args.host}:{args.port} for {', '.join(REPLIES)} (Ctrl+C to stop)", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
