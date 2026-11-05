#!/usr/bin/env python3
"""tests/probe/fake_agent.py - an SSH agent that offers one key it does not have.

TEST FIXTURE. Answers the identities request on a Unix socket with one
made-up ed25519 public key, so the probe's SSH agent attempt has an agent to
find in the open container. It signs nothing.
"""
import os
import socket
import struct
import sys


def string(b):
    return struct.pack(">I", len(b)) + b


def main(path):
    blob = string(b"ssh-ed25519") + string(bytes(32))
    reply = bytes([12]) + struct.pack(">I", 1) + string(blob) + string(b"TEST FIXTURE: not a key")
    if os.path.exists(path):
        os.unlink(path)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(path)
    srv.listen(4)
    while True:
        conn, _ = srv.accept()
        with conn:
            head = conn.recv(5)
            if len(head) == 5 and head[4] == 11:
                conn.sendall(struct.pack(">I", len(reply)) + reply)
            else:
                conn.sendall(struct.pack(">IB", 1, 5))  # SSH_AGENT_FAILURE


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
