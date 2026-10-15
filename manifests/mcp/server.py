"""The sandbox's only door to its tools: an MCP server that knows who is calling.

It speaks the Model Context Protocol, revision 2026-07-28, over Streamable
HTTP: one POST endpoint, one JSON response per request, no sessions. Every
request is checked in this order, and the first failure answers it:

  1. no browser origin (a present Origin header is refused, as the spec asks);
  2. the caller's identity: a Kubernetes ServiceAccount token bound to this
     server's audience, verified by the API server's TokenReview. A token
     for the Kubernetes API is not accepted here, and this server's token is
     not accepted there;
  3. the protocol: version 2026-07-28 in the header and in _meta, the
     Mcp-Method and Mcp-Name headers matching the body;
  4. the grant: policy.json names the tools and resources each identity may
     see. Anything else is answered as if it did not exist;
  5. the call: a rate limit per identity, arguments validated against the
     tool's input schema, the result capped and stripped of control
     characters.

The credential the records tool needs is mounted here and nowhere else: an
agent asks for a record, this server fetches it with a key the agent never
holds. Every decision is one JSON line on stdout, with the caller's
ServiceAccount and pod: the audit trail of what each agent tried.

Standard library only: the image is a pinned python:3.13-alpine and nothing
is installed into it.
"""
import base64
import collections
import hashlib
import json
import os
import re
import ssl
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PROTOCOL = "2026-07-28"
SERVER_INFO = {"name": "sandbox-mcp", "version": "1.1.0"}
POLICY_PATH = os.environ.get("MCP_POLICY", "/etc/mcp/policy.json")
RECORDS_KEY = os.environ.get("RECORDS_KEY_FILE", "/var/run/secrets/records/key")
REPORT_URL = os.environ.get("REPORT_URL", "http://tool-gateway.tools.svc.cluster.local:9898/")
RECORDS_URL = os.environ.get("RECORDS_URL", "http://records-api.corp.svc.cluster.local:8080")
API = "https://kubernetes.default.svc"
SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
MAX_BODY = 64 * 1024
MAX_OUTPUT = 4096
UPSTREAM_TIMEOUT = 5


def load_policy(path=POLICY_PATH):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


# --- the tools and resources this server has --------------------------------
# Having a tool is not granting it: policy.json decides who sees which.

def _get(url, method="GET", key=False):
    headers = {"Accept": "application/json"}
    if key:
        with open(RECORDS_KEY, encoding="utf-8") as f:
            headers["Authorization"] = "Bearer " + f.read().strip()
    req = urllib.request.Request(url, method=method, headers=headers)
    with urllib.request.urlopen(req, timeout=UPSTREAM_TIMEOUT) as r:
        return r.read(MAX_OUTPUT * 2).decode("utf-8", "replace")


def quarterly_report(_args):
    # The upstream is a fixed address, not one the caller names: a tool that
    # fetches whatever URL it is given is an exit, not a tool.
    body = _get(REPORT_URL)
    try:
        return json.loads(body).get("message", body)
    except ValueError:
        return body


def records_lookup(args):
    return _get(RECORDS_URL + "/records/" + args["customer_id"], key=True)


def delete_record(args):
    return _get(RECORDS_URL + "/records/" + args["customer_id"], method="DELETE", key=True)


CUSTOMER_ID = {"type": "string", "pattern": "^C[0-9]{4}$", "maxLength": 5,
               "description": "A customer ID, C followed by four digits"}
TOOLS = {
    "quarterly_report": {
        "definition": {
            "name": "quarterly_report",
            "title": "Quarterly report",
            "description": "The finance team's quarterly numbers, as published on the internal report service.",
            "inputSchema": {"type": "object", "additionalProperties": False},
            "annotations": {"readOnlyHint": True, "destructiveHint": False, "openWorldHint": False},
        },
        "run": quarterly_report,
    },
    "records_lookup": {
        "definition": {
            "name": "records_lookup",
            "title": "Customer record",
            "description": "One customer's record from the records service, by customer ID.",
            "inputSchema": {"type": "object", "properties": {"customer_id": CUSTOMER_ID},
                            "required": ["customer_id"], "additionalProperties": False},
            "annotations": {"readOnlyHint": True, "destructiveHint": False, "openWorldHint": False},
        },
        "run": records_lookup,
    },
    "delete_record": {
        "definition": {
            "name": "delete_record",
            "title": "Delete a customer record",
            "description": "Deletes one customer's record from the records service.",
            "inputSchema": {"type": "object", "properties": {"customer_id": CUSTOMER_ID},
                            "required": ["customer_id"], "additionalProperties": False},
            "annotations": {"readOnlyHint": False, "destructiveHint": True, "openWorldHint": False},
        },
        "run": delete_record,
    },
}
RESOURCES = {
    "report://quarterly": {
        "definition": {"uri": "report://quarterly", "name": "quarterly-report",
                       "title": "Quarterly report", "mimeType": "text/plain"},
        "read": lambda: quarterly_report({}),
    },
    "records://index": {
        "definition": {"uri": "records://index", "name": "records-index",
                       "title": "Customer IDs in the records service", "mimeType": "application/json"},
        "read": lambda: _get(RECORDS_URL + "/records", key=True),
    },
}


def validate(schema, args):
    """The subset of JSON Schema the tools above use; an error message, or None."""
    if not isinstance(args, dict):
        return "arguments must be an object"
    props = schema.get("properties", {})
    for name in schema.get("required", []):
        if name not in args:
            return "missing argument: %s" % name
    for name, value in args.items():
        if name not in props:
            if schema.get("additionalProperties", True) is False:
                return "unexpected argument: %s" % name
            continue
        p = props[name]
        if p.get("type") == "string":
            if not isinstance(value, str):
                return "%s must be a string" % name
            if "maxLength" in p and len(value) > p["maxLength"]:
                return "%s is longer than %d characters" % (name, p["maxLength"])
            if "pattern" in p and not re.search(p["pattern"], value):
                return "%s does not match %s" % (name, p["pattern"])
    return None


CONTROL = re.compile(r"[\x00-\x08\x0b-\x1f\x7f]")


def sanitize(text):
    """Cap the size and drop control characters. An instruction written in
    plain words passes: no filter can tell it from data, and the sandbox
    around the agent is what decides what acting on it can reach."""
    text = CONTROL.sub("", text)
    return text if len(text) <= MAX_OUTPUT else text[:MAX_OUTPUT] + " [truncated]"


# --- who is calling ----------------------------------------------------------

_reviews = {}
_reviews_lock = threading.Lock()


def identify(token, audience):
    """(ServiceAccount, pod) for a token the API server accepts for this
    server's audience, else None. Answers are cached for 30 seconds by the
    token's hash, never by the token."""
    digest = hashlib.sha256(token.encode()).hexdigest()
    now = time.monotonic()
    with _reviews_lock:
        hit = _reviews.get(digest)
        if hit and hit[0] > now:
            return hit[1]
    with open(os.path.join(SA_DIR, "token"), encoding="utf-8") as f:
        own = f.read().strip()
    body = json.dumps({"apiVersion": "authentication.k8s.io/v1", "kind": "TokenReview",
                       "spec": {"token": token, "audiences": [audience]}}).encode()
    req = urllib.request.Request(API + "/apis/authentication.k8s.io/v1/tokenreviews", data=body, method="POST",
                                 headers={"Content-Type": "application/json", "Authorization": "Bearer " + own})
    ctx = ssl.create_default_context(cafile=os.path.join(SA_DIR, "ca.crt"))
    with urllib.request.urlopen(req, timeout=UPSTREAM_TIMEOUT, context=ctx) as r:
        status = json.load(r).get("status", {})
    who = None
    if status.get("authenticated") and audience in status.get("audiences", []):
        user = status.get("user", {})
        pod = (user.get("extra") or {}).get("authentication.kubernetes.io/pod-name", [""])[0]
        who = (user.get("username", ""), pod)
    with _reviews_lock:
        _reviews[digest] = (now + 30, who)
    return who


class RateLimit:
    """At most `calls` tool calls per identity in any `seconds` window."""

    def __init__(self, calls, seconds):
        self.calls, self.seconds = calls, seconds
        self.seen = collections.defaultdict(collections.deque)
        self.lock = threading.Lock()

    def allow(self, who):
        now = time.monotonic()
        with self.lock:
            q = self.seen[who]
            while q and q[0] <= now - self.seconds:
                q.popleft()
            if len(q) >= self.calls:
                return False
            q.append(now)
            return True


# --- the protocol ------------------------------------------------------------

class Refused(Exception):
    """A request answered with an HTTP status and, where there is one, a JSON-RPC error."""

    def __init__(self, status, code=None, message="", data=None, decision="invalid"):
        super().__init__(message)
        self.status, self.code, self.message, self.data, self.decision = status, code, message, data, decision


def header_value(raw):
    """A mirrored header's value, decoded if it uses the Base64 sentinel."""
    if raw.startswith("=?base64?") and raw.endswith("?="):
        return base64.b64decode(raw[len("=?base64?"):-2]).decode("utf-8")
    return raw


def complete(result, ttl_ms=None, scope=None):
    """A complete result. Discovery, the lists and resource reads carry the
    caching hints 2026-07-28 requires: the lists differ per caller, so they
    are private, and a cache must not hand one identity's grant to another."""
    out = {"resultType": "complete"}
    out.update(result)
    if ttl_ms is not None:
        out["ttlMs"], out["cacheScope"] = ttl_ms, scope
    out["_meta"] = {"io.modelcontextprotocol/serverInfo": SERVER_INFO}
    return out


class Server:
    def __init__(self, policy):
        self.policy = policy
        self.audience = policy["audience"]
        self.grants = policy["identities"]
        self.limit = RateLimit(policy["rate_limit"]["calls"], policy["rate_limit"]["seconds"])

    def grant(self, who):
        return self.grants.get(who, {"tools": [], "resources": []})

    def check_protocol(self, headers, msg):
        method = msg.get("method")
        params = msg.get("params") or {}
        meta = params.get("_meta") or {}
        if method == "initialize":
            # A client from before 2026-07-28 opens with a handshake. Name the
            # version this server speaks, the one thing it can act on.
            raise Refused(400, -32022, "Unsupported protocol version",
                          {"supported": [PROTOCOL], "requested": params.get("protocolVersion")})
        version = headers.get("MCP-Protocol-Version")
        if not version:
            raise Refused(400, -32020, "Header mismatch: MCP-Protocol-Version is required")
        if "io.modelcontextprotocol/protocolVersion" not in meta or \
                "io.modelcontextprotocol/clientCapabilities" not in meta:
            raise Refused(400, -32602, "Invalid params: _meta needs protocolVersion and clientCapabilities")
        if meta["io.modelcontextprotocol/protocolVersion"] != version:
            raise Refused(400, -32020, "Header mismatch: MCP-Protocol-Version does not match _meta")
        if version != PROTOCOL:
            raise Refused(400, -32022, "Unsupported protocol version", {"supported": [PROTOCOL], "requested": version})
        if headers.get("Mcp-Method") != method:
            raise Refused(400, -32020, "Header mismatch: Mcp-Method does not match the body")
        if method in ("tools/call", "resources/read", "prompts/get"):
            want = params.get("name") if method != "resources/read" else params.get("uri")
            got = headers.get("Mcp-Name")
            try:
                got = header_value(got) if got is not None else None
            except (ValueError, UnicodeDecodeError):
                got = None
            if got != want:
                raise Refused(400, -32020, "Header mismatch: Mcp-Name does not match the body")

    def handle(self, who, msg):
        """The result for a request from `who`, or Refused. Also returns what
        the audit line should say: (result, decision, name)."""
        method, params = msg.get("method"), msg.get("params") or {}
        g = self.grant(who)
        if method == "server/discover":
            return complete({"supportedVersions": [PROTOCOL], "capabilities": {"tools": {}, "resources": {}},
                             "instructions": "Tools and resources are listed per caller; a call to anything "
                                             "not listed is answered as if it did not exist."},
                            3600000, "public"), "allowed", ""
        if method == "tools/list":
            tools = [TOOLS[n]["definition"] for n in sorted(TOOLS) if n in g["tools"]]
            return complete({"tools": tools}, 60000, "private"), "allowed", ""
        if method == "resources/list":
            res = [RESOURCES[u]["definition"] for u in sorted(RESOURCES) if u in g["resources"]]
            return complete({"resources": res}, 60000, "private"), "allowed", ""
        if method == "tools/call":
            name = params.get("name", "")
            if name not in TOOLS or name not in g["tools"]:
                # The same answer for a tool that does not exist and one this
                # caller is not granted: the grant is not something to probe.
                raise Refused(200, -32602, "Unknown tool: %s" % name, decision="denied")
            if not self.limit.allow(who):
                return complete({"content": [{"type": "text", "text": "Rate limited: at most %d calls in %d seconds."
                                              % (self.limit.calls, self.limit.seconds)}],
                                 "isError": True}), "rate_limited", name
            tool = TOOLS[name]
            args = params.get("arguments") or {}
            problem = validate(tool["definition"]["inputSchema"], args)
            if problem:
                return complete({"content": [{"type": "text", "text": "Invalid arguments: " + problem}],
                                 "isError": True}), "invalid_arguments", name
            try:
                text = tool["run"](args)
                is_error = False
            except urllib.error.HTTPError as e:
                text, is_error = "The service answered HTTP %d." % e.code, True
            except (urllib.error.URLError, OSError) as e:
                text, is_error = "The service could not be reached: %s" % type(e).__name__, True
            return complete({"content": [{"type": "text", "text": sanitize(text)}], "isError": is_error}), \
                "allowed", name
        if method == "resources/read":
            uri = params.get("uri", "")
            if uri not in RESOURCES or uri not in g["resources"]:
                raise Refused(200, -32602, "Resource not found: %s" % uri, decision="denied")
            r = RESOURCES[uri]
            return complete({"contents": [{"uri": uri, "mimeType": r["definition"]["mimeType"],
                                           "text": sanitize(r["read"]())}]}, 0, "private"), "allowed", uri
        raise Refused(404, -32601, "Method not found: %s" % method)


SERVER = None


def audit(**line):
    line["at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    print(json.dumps(line, sort_keys=True), flush=True)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "sandbox-mcp"
    sys_version = ""

    def log_message(self, *_):
        pass  # the audit line is the log

    def send(self, status, body=None, extra=None):
        data = b"" if body is None else json.dumps(body).encode()
        self.send_response(status)
        if body is not None:
            self.send_header("Content-Type", "application/json")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/healthz":
            return self.send(200, {"ok": True})
        # No standalone stream in 2026-07-28: GET to the endpoint is not allowed.
        self.send(405, None, {"Allow": "POST"})

    def do_DELETE(self):
        self.send(405, None, {"Allow": "POST"})

    def do_POST(self):
        who, pod, msg = "", "", {}
        try:
            # The body is read before anything is decided: a refusal that left
            # it unread would leave it on a kept-alive connection, to be parsed
            # as the next request.
            try:
                length = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                length = -1
            if length < 0 or length > MAX_BODY:
                self.close_connection = True
                raise Refused(413, -32600, "Request too large")
            raw = self.rfile.read(length) if length else b""
            if self.path != "/mcp":
                return self.send(404)
            if self.headers.get("Origin") is not None:
                raise Refused(403, -32600, "Cross-origin requests are refused", decision="denied")
            auth = self.headers.get("Authorization", "")
            if not auth.startswith("Bearer "):
                raise Refused(401, decision="unauthenticated", message="no bearer token")
            try:
                identity = identify(auth[len("Bearer "):].strip(), SERVER.audience)
            except (urllib.error.URLError, OSError, ValueError) as e:
                raise Refused(503, -32603, "Identity check unavailable: %s" % type(e).__name__)
            if identity is None:
                raise Refused(401, decision="unauthenticated", message="token not accepted for this audience")
            who, pod = identity
            try:
                msg = json.loads(raw or b"null")
            except ValueError:
                raise Refused(400, -32700, "Parse error")
            if not isinstance(msg, dict) or msg.get("jsonrpc") != "2.0" or not isinstance(msg.get("method"), str):
                raise Refused(400, -32600, "Invalid Request")
            if "id" not in msg:
                audit(identity=who, pod=pod, method=msg["method"], decision="accepted")
                return self.send(202)
            SERVER.check_protocol(self.headers, msg)
            result, decision, name = SERVER.handle(who, msg)
            audit(identity=who, pod=pod, method=msg["method"], name=name, decision=decision)
            self.send(200, {"jsonrpc": "2.0", "id": msg["id"], "result": result})
        except Refused as r:
            params = msg.get("params") if isinstance(msg, dict) else None
            name = (params or {}).get("name") or (params or {}).get("uri") or ""
            audit(identity=who, pod=pod, method=msg.get("method", "") if isinstance(msg, dict) else "",
                  name=name, decision=r.decision, reason=r.message, status=r.status)
            extra = {"WWW-Authenticate": 'Bearer realm="sandbox-mcp"'} if r.status == 401 else None
            body = None
            if r.code is not None:
                err = {"code": r.code, "message": r.message}
                if r.data is not None:
                    err["data"] = r.data
                body = {"jsonrpc": "2.0", "error": err}
                if isinstance(msg, dict) and "id" in msg:
                    body["id"] = msg["id"]
            self.send(r.status, body, extra)


def main():
    global SERVER
    SERVER = Server(load_policy())
    port = int(os.environ.get("PORT", "8080"))
    httpd = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    audit(event="listening", port=port, protocol=PROTOCOL, identities=sorted(SERVER.grants))
    httpd.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
