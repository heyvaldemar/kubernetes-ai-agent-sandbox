#!/usr/bin/env python3
"""tests/probe/target.py - what the boundary probe reaches for, in CI.

TEST FIXTURE. Stands in for the outside world on the runner, so the probe's
test touches no outside service: an HTTP server that serves one known page,
an instance metadata path and a DNS-over-HTTPS answer, and a DNS server over
UDP and TCP that answers 192.0.2.1 for every name under probe.test and logs
each name it is asked, so the test can see whether the probe's token got out.
"""
import json
import socket
import socketserver
import struct
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ZONE = "probe.test"
ANSWER = "192.0.2.1"
PAGE = b"boundary-probe target\n"


def log(msg):
    print(msg, flush=True)


class Http(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802 - http.server's name
        if self.path.startswith("/resolve"):
            body = json.dumps({"Status": 0, "Answer": [{"type": 1, "data": ANSWER}]}).encode()
            name = self.path.partition("name=")[2].partition("&")[0]
            log(f"doh {name}")
        elif self.path.startswith("/latest/meta-data"):
            body = b"ami-id\ninstance-id\n"
        else:
            body = PAGE
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def qname(msg):
    i, labels = 12, []
    while msg[i]:
        labels.append(msg[i + 1:i + 1 + msg[i]].decode())
        i += msg[i] + 1
    return ".".join(labels), i + 5


def answer(msg, how):
    name, end = qname(msg)
    log(f"dns-{how} {name}")
    ours = name == ZONE or name.endswith("." + ZONE)
    flags = 0x8180 if ours else 0x8183
    head = msg[:2] + struct.pack(">HHHHH", flags, 1, 1 if ours else 0, 0, 0)
    out = head + msg[12:end]
    if ours:
        out += struct.pack(">HHHIH", 0xC00C, 1, 1, 60, 4) + socket.inet_aton(ANSWER)
    return out


class Udp(socketserver.BaseRequestHandler):
    def handle(self):
        data, sock = self.request
        sock.sendto(answer(data, "udp"), self.client_address)


class Tcp(socketserver.BaseRequestHandler):
    def handle(self):
        size = struct.unpack(">H", self.request.recv(2))[0]
        data = self.request.recv(size)
        out = answer(data, "tcp")
        self.request.sendall(struct.pack(">H", len(out)) + out)


def main():
    servers = [ThreadingHTTPServer(("0.0.0.0", 8080), Http),
               socketserver.ThreadingUDPServer(("0.0.0.0", 53), Udp),
               socketserver.ThreadingTCPServer(("0.0.0.0", 53), Tcp)]
    for s in servers:
        threading.Thread(target=s.serve_forever, daemon=True).start()
    log("target ready")
    threading.Event().wait()


if __name__ == "__main__":
    sys.exit(main())
