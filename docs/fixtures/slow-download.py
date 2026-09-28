#!/usr/bin/env python3
"""Small deterministic download fixture for Copper's probe worlds.

  python3 slow-download.py 8766
  /big?mb=20&kbps=2000       sized, throttled
  /unknown?mb=5&kbps=1500    chunked, no Content-Length
  /fail?mb=10&at=0.4         closes the connection part way through
  /tiny.bin                   an immediate attachment
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse
import os
import time

CHUNK = 64 * 1024


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def do_GET(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        if parsed.path == "/tiny.bin":
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", "4")
            self.send_header("Content-Disposition", 'attachment; filename="tiny.bin"')
            self.end_headers()
            self.wfile.write(b"tiny")
            return

        kind = parsed.path.lstrip("/")
        if kind not in ("big", "unknown", "fail"):
            self.send_error(404)
            return
        mb = max(1, int(query.get("mb", [20])[0]))
        kbps = max(1, int(query.get("kbps", [2000])[0]))
        total = mb * 1024 * 1024
        fail_at = min(1.0, max(0.0, float(query.get("at", [0.4])[0])))
        filename = {"big": "big.bin", "unknown": "unknown.bin", "fail": "fail.bin"}[kind]

        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Disposition", f'attachment; filename="{filename}"')
        if kind == "unknown":
            self.send_header("Transfer-Encoding", "chunked")
        else:
            self.send_header("Content-Length", str(total))
        self.end_headers()

        sent = 0
        delay = CHUNK / (kbps * 1024.0)
        try:
            while sent < total:
                if kind == "fail" and sent >= int(total * fail_at):
                    self.connection.shutdown(1)
                    self.connection.close()
                    return
                size = min(CHUNK, total - sent)
                data = bytes((sent // CHUNK) % 251 for _ in range(size))
                if kind == "unknown":
                    self.wfile.write(f"{size:x}\r\n".encode("ascii"))
                    self.wfile.write(data)
                    self.wfile.write(b"\r\n")
                else:
                    self.wfile.write(data)
                self.wfile.flush()
                sent += size
                if sent < total:
                    time.sleep(delay)
            if kind == "unknown":
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8766")) if len(os.sys.argv) < 2 else int(os.sys.argv[1])
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"slow-download listening on http://127.0.0.1:{port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
