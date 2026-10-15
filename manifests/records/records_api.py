"""Another team's service that wants a key: the records an agent may ask for
through the MCP server, and must never be able to reach on its own.

    GET    /records          the customer IDs
    GET    /records/<id>     one customer's record
    DELETE /records/<id>     deletes it
    GET    /healthz          no key needed

Every request but the health check needs `Authorization: Bearer <key>`, the
key in /var/run/secrets/records/key, generated at install and held by this
service and the MCP server only. Each request is one JSON line on stdout.

Standard library only. The records are fictional.
"""
import hmac
import json
import os
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

KEY_FILE = os.environ.get("RECORDS_KEY_FILE", "/var/run/secrets/records/key")
RECORDS = {
    "C0001": {"id": "C0001", "name": "Northwind Traders", "plan": "enterprise", "renewal": "2027-03-31"},
    "C0002": {"id": "C0002", "name": "Tailspin Toys", "plan": "team", "renewal": "2026-12-15"},
    "C0003": {"id": "C0003", "name": "Fabrikam Logistics", "plan": "enterprise", "renewal": "2027-06-30"},
}
LOCK = threading.Lock()
PATH = re.compile(r"^/records(?:/(C[0-9]{4}))?$")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "records-api"
    sys_version = ""

    def log_message(self, *_):
        pass

    def answer(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        print(json.dumps({"at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "method": self.command,
                          "path": self.path, "status": status}), flush=True)

    def authorized(self):
        with open(KEY_FILE, encoding="utf-8") as f:
            key = f.read().strip()
        got = self.headers.get("Authorization", "")
        return bool(key) and hmac.compare_digest(got.encode(), ("Bearer " + key).encode())

    def route(self):
        if self.path == "/healthz":
            return None
        m = PATH.match(self.path)
        if not m:
            self.answer(404, {"error": "not found"})
            return False
        if not self.authorized():
            self.answer(401, {"error": "a key is required"})
            return False
        return m.group(1) or ""

    def do_GET(self):
        rid = self.route()
        if rid is None:
            return self.answer(200, {"ok": True})
        if rid is False:
            return
        with LOCK:
            if rid == "":
                return self.answer(200, {"records": sorted(RECORDS)})
            if rid not in RECORDS:
                return self.answer(404, {"error": "no such record"})
            return self.answer(200, RECORDS[rid])

    def do_DELETE(self):
        rid = self.route()
        if rid in (None, False, ""):
            return self.answer(405, {"error": "not allowed"}) if rid is not False else None
        with LOCK:
            if RECORDS.pop(rid, None) is None:
                return self.answer(404, {"error": "no such record"})
        self.answer(200, {"deleted": rid})


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", int(os.environ.get("PORT", "8080"))), Handler).serve_forever()
