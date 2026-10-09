"""Loopback-only sync gate for native table-navigation and sync-status UI tests.

Start with --port 0, pass the printed URL as TEST_RUNNER_IRIS_TEST_TABLE_NAV_HUB.
Only synthetic replicas on explicitly selected disposable simulators may use it.
GET /fixture/mode/<offline|accept|reject> switches sync replies: offline (the
default) answers 503, accept completes empty rounds, reject refuses notes pushes.
"""

import argparse
import json
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
        elif self.path != "/fixture/status":
            self.reply(503, {"error": "Synthetic service unavailable"})
            return
        self.reply(200, {"waiting": waiting.is_set()})

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
