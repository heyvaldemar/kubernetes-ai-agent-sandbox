#!/usr/bin/env python3
"""router_egress_probe.py - measure the egress a sandbox-router permits.

TEST FIXTURE. This measures a documented default of an upstream project,
kubernetes-sigs/agent-sandbox, on a local kind cluster with in-cluster stubs.
It touches no real internet and no real cloud. Each request is a planted
measurement aimed at the router under test, in the ADR 6 boundary-probe
family (docs/decisions/0007-...). It is not an attack tool and names no
target but the stubs and router its caller passes it.

The sandbox-router (release v1.0.10) forwards a request to the address named
by the caller's `X-Sandbox-Pod-IP` and `X-Sandbox-Port` headers, once the
address passes its IP-class check (loopback, link-local, multicast and
unspecified are rejected, so the cloud-metadata address is not reachable
through it) and its authorizer admits the call (the default `--authz-mode=
allow-all` admits every call carrying a valid `X-Sandbox-ID`). What the
router can then reach is decided by the NetworkPolicy on its Pod. This probe
sends the router one request per target and records whether the target
answered (reached) or the dial was refused by policy (blocked).

Reached is unambiguous: every stub is a plain-HTTP server that returns a known
marker, so a 200 carrying the marker means the egress reached it. Anything
else (the router's 502/504 on a dialled-but-dropped address) is blocked.

    router_egress_probe.py --router http://HOST:8080 --config a|b \
        --targets targets.json [--marker STR]

targets.json is a list of objects:
    {"name", "pod_ip", "port", "sandbox_id",
     "kind": "attempt"|"control", "expect": {"a": "reached"|"blocked",
     "b": "reached"|"blocked"}, "note"}

One JSON line per target, in the demo agents' format: "config" is a or b,
"got" is reached or blocked, "ok" compares it with expect[config]. Standard
library only.
"""
import argparse
import json
import re
import sys
import urllib.error
import urllib.request

FIXTURE = "TEST FIXTURE: measured on agent-sandbox v1.0.10 router egress defaults"
TIMEOUT = 20


def clean(text, limit=240):
    text = re.sub(r"[\x00-\x1f\x7f]+", " ", str(text)).strip()
    return text[:limit]


def ask_router(router, sandbox_id, pod_ip, port, marker):
    """Send the router one request; return (got, detail)."""
    req = urllib.request.Request(
        router.rstrip("/") + "/",
        headers={
            "X-Sandbox-ID": sandbox_id,
            "X-Sandbox-Pod-IP": pod_ip,
            "X-Sandbox-Port": str(port),
            "User-Agent": "router-egress-probe",
        },
    )
    # No proxy handlers: talk to the router directly.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(req, timeout=TIMEOUT) as resp:
            body = resp.read(4096).decode("utf-8", "replace")
            status = resp.status
    except urllib.error.HTTPError as exc:
        body = exc.read(4096).decode("utf-8", "replace")
        # The router answers 4xx for a request it rejects before dialling
        # (a malformed header, an IP class it refuses); that is not an egress
        # measurement, so surface it rather than calling it blocked.
        if exc.code in (400, 401, 403):
            return "refused-by-router", clean(f"HTTP {exc.code}: {body}")
        return "blocked", clean(f"HTTP {exc.code}: {body}")
    except Exception as exc:  # noqa: BLE001 - every failure is a measurement
        return "blocked", clean(f"{type(exc).__name__}: {exc}")
    if status == 200 and marker in body:
        return "reached", clean(f"HTTP 200, answer carries {marker!r}")
    if marker in body:
        return "reached", clean(f"HTTP {status}, answer carries {marker!r}")
    return "blocked", clean(f"HTTP {status}: {body}")


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--router", required=True, help="the router's base URL, e.g. http://host:8080")
    p.add_argument("--config", required=True, choices=["a", "b"], help="which NetworkPolicy config is live")
    p.add_argument("--targets", required=True, help="path to the targets JSON")
    p.add_argument("--marker", default="AGENT-SANDBOX-EGRESS-STUB", help="text every stub returns")
    a = p.parse_args()
    targets = json.load(open(a.targets, encoding="utf-8"))
    failed = 0
    for t in targets:
        got, detail = ask_router(a.router, t["sandbox_id"], t["pod_ip"], t["port"], a.marker)
        expect = t["expect"][a.config]
        ok = got == expect
        if t["kind"] == "attempt" or t["kind"] == "control":
            if not ok:
                failed += 1
        line = {
            "fixture": FIXTURE,
            "config": a.config,
            "kind": t["kind"],
            "name": t["name"],
            "target": f"{t['pod_ip']}:{t['port']}",
            "via": "sandbox-router X-Sandbox-Pod-IP",
            "expected": expect,
            "got": got,
            "ok": ok,
            "note": t.get("note", ""),
            "detail": detail,
        }
        print(json.dumps(line), flush=True)
    print(json.dumps({"summary": {"config": a.config, "targets": len(targets), "failed": failed}}), flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
