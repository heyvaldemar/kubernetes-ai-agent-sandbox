#!/usr/bin/env python3
"""The MCP server's protocol and grants, without a cluster.

    python3 tests/mcp/test_server.py

Raw HTTP against manifests/mcp/server.py on localhost (tests/mcp/harness.py):
what MCP 2026-07-28 requires of a Streamable HTTP server, and what this one
adds, each as a request and the answer it must get. The cluster-side
controls (gVisor, the token's audience at the API server, network policy,
the key never reaching an agent) are in tests/e2e/run.sh.
"""
import base64
import json
import os
import sys
import unittest
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import harness  # noqa: E402

V = "2026-07-28"


def meta(version=V):
    return {"io.modelcontextprotocol/protocolVersion": version,
            "io.modelcontextprotocol/clientInfo": {"name": "test", "version": "0"},
            "io.modelcontextprotocol/clientCapabilities": {}}


def post(url, body, token="researcher-token", headers=None, method="POST"):
    """(status, parsed body or None, response headers)."""
    h = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
    if token:
        h["Authorization"] = "Bearer " + token
    if isinstance(body, dict) and "method" in body:
        h["MCP-Protocol-Version"] = (body.get("params") or {}).get("_meta", {}).get(
            "io.modelcontextprotocol/protocolVersion", V)
        h["Mcp-Method"] = body["method"]
        p = body.get("params") or {}
        if body["method"] in ("tools/call", "resources/read"):
            h["Mcp-Name"] = p.get("name") if body["method"] == "tools/call" else p.get("uri")
    h.update(headers or {})
    h = {k: v for k, v in h.items() if v is not None}
    data = json.dumps(body).encode() if body is not None and method == "POST" else None
    req = urllib.request.Request(url, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            raw, status, rh = r.read(), r.status, r.headers
    except urllib.error.HTTPError as e:
        with e:
            raw, status, rh = e.read(), e.code, e.headers
    return status, (json.loads(raw) if raw else None), rh


def rpc(method, params=None, id_=1, version=V):
    p = dict(params or {})
    p["_meta"] = meta(version)
    return {"jsonrpc": "2.0", "id": id_, "method": method, "params": p}


class Protocol(unittest.TestCase):
    """What the 2026-07-28 revision asks of a Streamable HTTP server."""

    def setUp(self):
        self.ctx = harness.running()
        self.url, self.srv, self.audit = self.ctx.__enter__()

    def tearDown(self):
        self.ctx.__exit__(None, None, None)

    def test_discover(self):
        s, b, _ = post(self.url, rpc("server/discover"))
        self.assertEqual(s, 200)
        self.assertEqual(b["result"]["resultType"], "complete")
        self.assertEqual(b["result"]["supportedVersions"], [V])
        self.assertIn("tools", b["result"]["capabilities"])
        self.assertEqual(b["result"]["_meta"]["io.modelcontextprotocol/serverInfo"]["name"], "sandbox-mcp")
        self.assertEqual(b["result"]["cacheScope"], "public")

    def test_lists_that_differ_per_caller_are_private_to_a_cache(self):
        for m in ("tools/list", "resources/list"):
            s, b, _ = post(self.url, rpc(m))
            self.assertEqual((b["result"]["cacheScope"], b["result"]["ttlMs"] >= 0), ("private", True), m)

    def test_get_and_delete_are_not_allowed(self):
        for m in ("GET", "DELETE"):
            s, _, h = post(self.url, None, method=m)
            self.assertEqual(s, 405, m)
            self.assertEqual(h.get("Allow"), "POST")

    def test_origin_is_refused(self):
        s, b, _ = post(self.url, rpc("tools/list"), headers={"Origin": "https://evil.example"})
        self.assertEqual(s, 403)
        self.assertNotIn("id", b)

    def test_version_header_is_required(self):
        s, b, _ = post(self.url, rpc("tools/list"), headers={"MCP-Protocol-Version": None})
        self.assertEqual((s, b["error"]["code"]), (400, -32020))

    def test_header_and_meta_must_agree(self):
        s, b, _ = post(self.url, rpc("tools/list"), headers={"MCP-Protocol-Version": "2025-11-25"})
        self.assertEqual((s, b["error"]["code"]), (400, -32020))

    def test_unsupported_version_names_the_supported_one(self):
        s, b, _ = post(self.url, rpc("tools/list", version="2025-11-25"))
        self.assertEqual((s, b["error"]["code"]), (400, -32022))
        self.assertEqual(b["error"]["data"], {"supported": [V], "requested": "2025-11-25"})

    def test_a_legacy_handshake_is_told_the_version(self):
        body = {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "x", "version": "0"}}}
        s, b, _ = post(self.url, body, headers={"MCP-Protocol-Version": None, "Mcp-Method": None})
        self.assertEqual((s, b["error"]["code"]), (400, -32022))
        self.assertEqual(b["error"]["data"]["supported"], [V])

    def test_meta_is_required(self):
        body = rpc("tools/list")
        del body["params"]["_meta"]["io.modelcontextprotocol/clientCapabilities"]
        s, b, _ = post(self.url, body)
        self.assertEqual((s, b["error"]["code"]), (400, -32602))

    def test_method_header_must_match(self):
        s, b, _ = post(self.url, rpc("tools/list"), headers={"Mcp-Method": "resources/list"})
        self.assertEqual((s, b["error"]["code"]), (400, -32020))

    def test_name_header_must_match_and_may_be_base64(self):
        call = rpc("tools/call", {"name": "quarterly_report", "arguments": {}})
        s, b, _ = post(self.url, call, headers={"Mcp-Name": "records_lookup"})
        self.assertEqual((s, b["error"]["code"]), (400, -32020))
        enc = "=?base64?" + base64.b64encode(b"quarterly_report").decode() + "?="
        s, b, _ = post(self.url, call, headers={"Mcp-Name": enc})
        self.assertEqual(s, 200)
        self.assertFalse(b["result"]["isError"])

    def test_unknown_method(self):
        s, b, _ = post(self.url, rpc("prompts/list"))
        self.assertEqual((s, b["error"]["code"]), (404, -32601))

    def test_notification_is_accepted_without_a_body(self):
        s, b, _ = post(self.url, {"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {}})
        self.assertEqual((s, b), (202, None))


class Identity(unittest.TestCase):
    """Who is calling, before anything else is read."""

    def setUp(self):
        self.ctx = harness.running()
        self.url, self.srv, self.audit = self.ctx.__enter__()

    def tearDown(self):
        self.ctx.__exit__(None, None, None)

    def test_no_token(self):
        s, b, h = post(self.url, rpc("tools/list"), token=None)
        self.assertEqual((s, b), (401, None))
        self.assertTrue(h.get("WWW-Authenticate", "").startswith("Bearer"))

    def test_a_token_the_identity_check_does_not_accept(self):
        s, _, _ = post(self.url, rpc("tools/list"), token="api-server-token")
        self.assertEqual(s, 401)

    def test_every_decision_is_an_audit_line_with_the_pod(self):
        post(self.url, rpc("tools/call", {"name": "records_lookup", "arguments": {"customer_id": "C0001"}}))
        lines = [json.loads(x) for x in self.audit.getvalue().splitlines()]
        denied = [x for x in lines if x.get("decision") == "denied"]
        self.assertEqual(len(denied), 1)
        self.assertEqual(denied[0]["identity"], "system:serviceaccount:agents:researcher")
        self.assertEqual(denied[0]["pod"], "agent-demo-abc12")
        self.assertEqual(denied[0]["name"], "records_lookup")


class Grants(unittest.TestCase):
    """Each identity sees and calls what policy.json grants it, and nothing else."""

    def setUp(self):
        self.ctx = harness.running()
        self.url, self.srv, self.audit = self.ctx.__enter__()
        harness.Upstream.seen.clear()

    def tearDown(self):
        self.ctx.__exit__(None, None, None)

    def tools(self, token):
        s, b, _ = post(self.url, rpc("tools/list"), token=token)
        self.assertEqual(s, 200)
        return [t["name"] for t in b["result"]["tools"]]

    def test_each_identity_lists_its_grant(self):
        self.assertEqual(self.tools("researcher-token"), ["quarterly_report"])
        self.assertEqual(self.tools("clerk-token"), ["records_lookup"])
        self.assertEqual(self.tools("stranger-token"), [])

    def test_the_destructive_tool_is_granted_to_nobody(self):
        for token in harness.TOKENS:
            s, b, _ = post(self.url, rpc("tools/call", {"name": "delete_record", "arguments": {"customer_id": "C0001"}}),
                           token=token)
            self.assertEqual((s, b["error"]["code"]), (200, -32602), token)
        self.assertEqual([x for x in harness.Upstream.seen if x[0] == "DELETE"], [])

    def test_not_granted_looks_the_same_as_not_there(self):
        _, a, _ = post(self.url, rpc("tools/call", {"name": "records_lookup", "arguments": {"customer_id": "C0001"}}))
        _, b, _ = post(self.url, rpc("tools/call", {"name": "no_such_tool", "arguments": {}}))
        self.assertEqual(a["error"]["code"], b["error"]["code"])
        self.assertEqual(a["error"]["message"].split(":")[0], b["error"]["message"].split(":")[0])

    def test_the_tool_answers_and_carries_what_the_upstream_said(self):
        s, b, _ = post(self.url, rpc("tools/call", {"name": "quarterly_report", "arguments": {}}))
        self.assertEqual(s, 200)
        self.assertFalse(b["result"]["isError"])
        self.assertIn("SYSTEM NOTE", b["result"]["content"][0]["text"])

    def test_the_key_is_used_by_the_server_for_the_caller(self):
        s, b, _ = post(self.url, rpc("tools/call", {"name": "records_lookup", "arguments": {"customer_id": "C0001"}}),
                       token="clerk-token")
        self.assertEqual(s, 200)
        self.assertIn("Northwind", b["result"]["content"][0]["text"])
        self.assertIn(("GET", "/records/C0001", "Bearer " + harness.KEY), harness.Upstream.seen)
        self.assertNotIn(harness.KEY, json.dumps(b))

    def test_arguments_are_validated_before_the_upstream_is_called(self):
        for args in ({"customer_id": "C0001' OR 1=1"}, {"customer_id": "../admin"}, {},
                     {"customer_id": "C0001", "extra": 1}, {"customer_id": 1}):
            s, b, _ = post(self.url, rpc("tools/call", {"name": "records_lookup", "arguments": args}),
                           token="clerk-token")
            self.assertEqual(s, 200)
            self.assertTrue(b["result"]["isError"], args)
            self.assertIn("Invalid arguments", b["result"]["content"][0]["text"])
        self.assertEqual(harness.Upstream.seen, [])

    def test_resources_follow_the_grant(self):
        s, b, _ = post(self.url, rpc("resources/list"))
        self.assertEqual([r["uri"] for r in b["result"]["resources"]], ["report://quarterly"])
        s, b, _ = post(self.url, rpc("resources/read", {"uri": "records://index"}))
        self.assertEqual((s, b["error"]["code"]), (200, -32602))
        s, b, _ = post(self.url, rpc("resources/read", {"uri": "records://index"}), token="clerk-token")
        self.assertIn("C0001", b["result"]["contents"][0]["text"])


class Limits(unittest.TestCase):
    def test_rate_limit_per_identity(self):
        with harness.running(rate_calls=3) as (url, _, _):
            got = []
            for i in range(5):
                _, b, _ = post(url, rpc("tools/call", {"name": "quarterly_report", "arguments": {}}, id_=i))
                got.append(b["result"]["isError"])
            self.assertEqual(got, [False, False, False, True, True])
            # Another identity has its own budget.
            _, b, _ = post(url, rpc("tools/call", {"name": "records_lookup", "arguments": {"customer_id": "C0001"}}),
                           token="clerk-token")
            self.assertFalse(b["result"]["isError"])

    def test_output_is_capped_and_stripped(self):
        srv = harness.load_server()
        self.assertEqual(srv.sanitize("a\x1b[31mb\x00c\nd"), "a[31mbc\nd")
        self.assertTrue(srv.sanitize("x" * 10000).endswith("[truncated]"))

    def test_an_oversized_request_is_refused(self):
        with harness.running() as (url, _, _):
            body = rpc("tools/list")
            body["params"]["padding"] = "x" * (70 * 1024)
            s, _, _ = post(url, body)
            self.assertEqual(s, 413)


if __name__ == "__main__":
    unittest.main(verbosity=1)
