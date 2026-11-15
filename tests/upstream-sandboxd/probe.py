#!/usr/bin/env python3
"""Send one file operation per probe to a sandboxd REST endpoint and record
what came back, as JSON on stdout. Runs inside a client container on the same
Docker network as the daemon, reached as http://sbxd:8080.

This exercises an UPSTREAM project (kubernetes-sigs/agent-sandbox sandboxd),
not this repository. Every path is a fixture created in the daemon's own
--root-dir; nothing reaches the internet or a cloud. See
docs/decisions/0008-measured-sandboxd-fileops.md.

The daemon's own answer is the measurement: a 2xx, a 4xx with an error code,
or no answer at all within the deadline (a hang). The caller never decides
what "should" happen here; verdict.py compares two versions' answers.
"""
import json
import sys
import time
import urllib.error
import urllib.request

BASE = "http://sbxd:8080"
TIMEOUT = float(sys.argv[1]) if len(sys.argv) > 1 else 6.0
# Read-body cap: a device like /dev/zero streams without end; stop at the cap
# and report eof=false rather than read forever.
CAP = 5_000_000


def req(method, path, read_body=False):
    r = urllib.request.Request(BASE + path, method=method)
    t = time.time()
    try:
        with urllib.request.urlopen(r, timeout=TIMEOUT) as resp:
            if not read_body:
                resp.read(128)
                return {"status": resp.status, "elapsed": round(time.time() - t, 2)}
            total, eof = 0, True
            while True:
                if time.time() - t > TIMEOUT:
                    eof = False
                    break
                chunk = resp.read(65536)
                if not chunk:
                    break
                total += len(chunk)
                if total >= CAP:
                    eof = False
                    break
            return {
                "status": resp.status,
                "elapsed": round(time.time() - t, 2),
                "bytes": total,
                "eof": eof,
                "timed_out": (time.time() - t >= TIMEOUT),
            }
    except urllib.error.HTTPError as e:
        try:
            body = e.read(200).decode("latin1")
        except Exception:
            body = ""
        code, msg = "", ""
        if body.startswith("{"):
            try:
                doc = json.loads(body)
                code, msg = doc.get("code", ""), doc.get("message", "")
            except Exception:
                pass
        return {
            "status": e.code,
            "code": code,
            "msg": msg[:120] or body[:120],
            "elapsed": round(time.time() - t, 2),
        }
    except Exception as e:
        el = round(time.time() - t, 2)
        # No HTTP answer within the deadline: the handler is hung open.
        return {"status": None, "elapsed": el, "timed_out": el >= TIMEOUT - 0.5,
                "error": type(e).__name__}


# Order matters: read then delete the regular-file control; the symlink
# deletes come after so an earlier probe never disturbs a later fixture.
PROBES = [
    # Controls prove the endpoint works at all, so a special-file or symlink
    # result below is a property of that input, not a broken handler.
    ("control_get_regular", "GET", "/v1/files/regular.txt", True),
    ("control_delete_regular", "DELETE", "/v1/files/regular.txt", False),
    # #2222 — named pipe and device file in a GET file transfer.
    ("get_fifo", "GET", "/v1/files/pipe", True),
    ("get_device", "GET", "/v1/files/zero", True),
    # #2218 — DELETE of a symlink whose target is INSIDE the sandbox root
    # (an escaping link is already refused by the path-traversal guard; see
    # control_delete_escape_link).
    ("delete_inroot_link_file", "DELETE", "/v1/files/link-to-file", False),
    ("delete_inroot_link_dir", "DELETE", "/v1/files/link-to-dir?recursive=true", False),
    ("control_delete_escape_link", "DELETE", "/v1/files/escape-link", False),
]

if __name__ == "__main__":
    print(json.dumps({n: req(m, p, rb) for (n, m, p, rb) in PROBES}))
