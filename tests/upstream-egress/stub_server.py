#!/usr/bin/env python3
"""stub_server.py - a plain-HTTP stand-in that answers on several ports.

TEST FIXTURE. Stands in for a destination the sandbox-router might be asked to
reach, so the measurement touches no real service. It listens plain HTTP on
each port given on the command line and answers every request with a known
marker, so the probe can tell "the egress reached me" from "the egress was
refused". It is not the API server and speaks no TLS: port 443 and 6443 here
are just port numbers, used because the router's default NetworkPolicy keys on
them. Standard library only.

    stub_server.py 443 6443 8888
"""
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MARKER = b"AGENT-SANDBOX-EGRESS-STUB"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802 - http.server's name
        body = MARKER + b" port=" + str(self.server.server_address[1]).encode() + b"\n"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def main(ports):
    servers = [ThreadingHTTPServer(("0.0.0.0", int(p)), Handler) for p in ports]
    for s in servers:
        threading.Thread(target=s.serve_forever, daemon=True).start()
    print("stub ready on " + ",".join(ports), flush=True)
    threading.Event().wait()


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: stub_server.py PORT [PORT...]", file=sys.stderr)
        sys.exit(2)
    main(sys.argv[1:])
