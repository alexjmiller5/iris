"""Loopback-only sync gate for the native table-navigation regression.

Start with --port 0, pass the printed URL as TEST_RUNNER_LIFE_UI_TEST_TABLE_NAV_HUB.
Only synthetic replicas on explicitly selected disposable simulators may use it.
"""

import argparse
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

released = threading.Event()
released.set()
waiting = threading.Event()


class Handler(BaseHTTPRequestHandler):
    def reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        if self.path == "/fixture/hold":
            released.clear()
            waiting.clear()
        elif self.path == "/fixture/release":
            released.set()
        elif self.path != "/fixture/status":
            self.reply(503, {"error": "Synthetic service unavailable"})
            return
        self.reply(200, {"waiting": waiting.is_set()})

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if self.path == "/v1/schema/pull":
            waiting.set()
            released.wait(60)
        self.reply(503, {"error": "Synthetic offline sync"})


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"http://127.0.0.1:{server.server_port}", flush=True)
    server.serve_forever()
