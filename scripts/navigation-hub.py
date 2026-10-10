"""Loopback-only sync gate for native table-navigation and sync-status UI tests.

Start with --port 0, pass the printed URL as TEST_RUNNER_IRIS_TEST_TABLE_NAV_HUB.
Only synthetic replicas on explicitly selected disposable simulators may use it.
GET /fixture/mode/<offline|accept|reject> switches sync replies: offline (the
default) answers 503, accept completes empty rounds, reject refuses notes pushes.
Outside offline mode GET /v1/changes opens the wake socket: it answers "ping"
with "pong" and never signals a change, so the app reports Live.
"""

import argparse
import base64
import hashlib
import json
import struct
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

released = threading.Event()
released.set()
waiting = threading.Event()
mode = "offline"
TABLES = [
    "notes", "topics", "views", "view_defaults", "related_view_defaults", "sidebar_pins",
    "history", "provenance", "catalog_tables", "catalog_properties", "catalog_rules",
    "catalog_log",
]  # fmt: skip


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
        global mode
        if self.path.startswith("/fixture/mode/"):
            mode = self.path.removeprefix("/fixture/mode/")
        elif self.path == "/fixture/hold":
            released.clear()
            waiting.clear()
        elif self.path == "/fixture/release":
            released.set()
        elif self.path == "/v1/changes" and mode != "offline":
            self.wake_socket()
            return
        elif self.path != "/fixture/status":
            self.reply(503, {"error": "Synthetic service unavailable"})
            return
        self.reply(200, {"waiting": waiting.is_set()})

    def wake_socket(self):
        key = self.headers["Sec-WebSocket-Key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", base64.b64encode(hashlib.sha1(key.encode()).digest()).decode())
        self.end_headers()
        self.close_connection = True
        try:
            while len(head := self.rfile.read(2)) == 2:
                size = head[1] & 0x7F
                if size >= 126:
                    size = struct.unpack(">H" if size == 126 else ">Q", self.rfile.read(2 if size == 126 else 8))[0]
                mask = self.rfile.read(4) if head[1] & 0x80 else bytes(4)
                data = bytes(b ^ mask[i % 4] for i, b in enumerate(self.rfile.read(size)))
                if head[0] & 0x0F == 8:
                    break
                if head[0] & 0x0F == 1 and data == b"ping":
                    self.wfile.write(b"\x81\x04pong")
                    self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if self.path == "/v1/schema/pull":
            waiting.set()
            released.wait(60)
        if mode == "offline":
            self.reply(503, {"error": "Synthetic offline sync"})
            return
        body = json.loads(raw or b"{}")
        rows = body.get("rows", [])
        refused = rows if mode == "reject" and body.get("table") == "notes" else []
        replies = {
            "/v1/schema/pull": {"entries": []},
            "/v1/schema/push": {},
            "/v1/stats": {"tables": {table: 1 for table in TABLES}},
            "/v1/cursor": {"max_hub_at": "", "tables": {t: "" for t in body.get("tables", [])}},
            "/v1/rows/pull": {"rows": [], "next_cursor": None},
            "/v1/rows/push": {
                "upserted": len(rows) - len(refused),
                "rejected": [{"id": r["id"], "errors": "Synthetic rejection"} for r in refused],
            },
        }
        if self.path in replies:
            self.reply(200, replies[self.path])
        else:
            self.reply(404, {"error": "Synthetic route unavailable"})


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"http://127.0.0.1:{server.server_port}", flush=True)
    server.serve_forever()
