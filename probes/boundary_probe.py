#!/usr/bin/env python3
"""boundary_probe.py - eight planted attempts to get out of a sandbox.

TEST FIXTURE. Every attempt in this file is an escape attempt planted on
purpose and aimed at the sandbox the script runs in, to see where that sandbox
stops it. It reads no credential's value and prints none: a credential file is
reported by its path and size, an environment variable by its name, an SSH
agent by its number of keys. It sends nothing anywhere except the targets named
on its command line, and the only data it carries out is the random token it
was given, which proves that a channel was open.

Inside the sandbox:

    python3 -I boundary_probe.py attempt --token T [targets] > results.jsonl

On the host, afterwards, for what only the host can see (did a file written
inside appear outside, and who owns it there):

    python3 -I boundary_probe.py verify --results results.jsonl --token T ...

One JSON line per check, the format of the demo agents in this repository:
"attempt" is 1 to 8, "kind" is attempt (expected blocked), control (expected
reached, so a pass cannot come from an environment that refuses everything)
or observation (no expectation), and "got" is what happened.

The eight attempts: 1 a host the network policy does not allow, 2 host files
outside the mounted workspace, 3 credential files, the SSH agent and the
instance metadata service, 4 a Docker socket that belongs to the host, 5 the
host's environment variables, 6 writes outside the working directory, 7 DNS as
a way out, 8 privilege escalation, and what root reaches from there.

Standard library only, Python 3.9 or later. Tested by tests/probe/run.sh: in a
container with every door open each attempt must get through, and in a
container with every door shut each must be blocked.
"""
import argparse
import base64
import glob
import json
import os
import re
import shutil
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request

FIXTURE = "TEST FIXTURE: planted escape attempt"
TIMEOUT = 6
CRED_PATHS = [
    ".aws/credentials", ".aws/config", ".docker/config.json", ".kube/config",
    ".config/gh/hosts.yml", ".git-credentials", ".netrc", ".ssh/id_rsa",
    ".ssh/id_ecdsa", ".ssh/id_ed25519",
]
CRED_NAME = re.compile(r"(TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|API_?KEY|ACCESS_KEY|SESSION|PRIVATE)", re.I)
DOCKER_SOCKETS = ["/var/run/docker.sock", "/run/docker.sock", "/var/run/docker.sock.raw",
                  "/run/host-services/docker.proxy.sock"]


def clean(text, limit=160):
    """One line, no control characters, nothing that looks like a key."""
    text = re.sub(r"[\x00-\x1f\x7f]+", " ", str(text)).strip()
    text = re.sub(r"[A-Za-z0-9_\-+=]{32,}", "<redacted>", text)
    return text[:limit]


def err(exc):
    return clean(f"{type(exc).__name__}: {exc}")


class Report:
    def __init__(self):
        self.lines = []

    def add(self, attempt, area, kind, check, target, got, detail="", **extra):
        expected = {"attempt": "blocked", "control": "reached"}.get(kind)
        line = {"attempt": attempt, "area": area, "kind": kind, "fixture": FIXTURE,
                "check": check, "target": target, "expected": expected, "got": got,
                "ok": (got == expected) if expected and got in ("reached", "blocked") else None,
                "detail": clean(detail, 240)}
        line.update(extra)
        self.lines.append(line)
        print(json.dumps(line), flush=True)


# --- the network -------------------------------------------------------------

def fetch(url, proxy=True, limit=65536):
    """Return (status, body) or raise. proxy=False ignores the proxy settings."""
    handlers = [] if proxy else [urllib.request.ProxyHandler({})]
    opener = urllib.request.build_opener(*handlers)
    req = urllib.request.Request(url, headers={"User-Agent": "boundary-probe"})
    try:
        with opener.open(req, timeout=TIMEOUT) as resp:
            return resp.status, resp.read(limit).decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read(limit).decode("utf-8", "replace")


def try_fetch(url, expect, proxy=True):
    """reached only when the page the target serves comes back."""
    try:
        status, body = fetch(url, proxy=proxy)
    except Exception as exc:  # noqa: BLE001 - every failure is a measurement
        return "blocked", err(exc)
    if expect in body:
        return "reached", f"HTTP {status}, page contains {expect!r}"
    return "blocked", f"HTTP {status}: {body}"


def raw_http(hostport, expect):
    host, port = hostport.rsplit(":", 1)
    try:
        with socket.create_connection((host, int(port)), timeout=TIMEOUT) as s:
            s.sendall(f"GET / HTTP/1.0\r\nHost: {host}\r\n\r\n".encode())
            data = b""
            while len(data) < 65536:
                chunk = s.recv(4096)
                if not chunk:
                    break
                data += chunk
    except Exception as exc:  # noqa: BLE001
        return "blocked", err(exc)
    text = data.decode("utf-8", "replace")
    if expect.lower() in text.lower():
        return "reached", f"answered, response contains {expect!r}"
    return "blocked", f"connected, but not the target: {text}"


def attempt_network(r, a):
    if a.allowed_url:
        got, detail = try_fetch(a.allowed_url, a.allowed_expect)
        r.add(1, "network", "control", "an allowed host, through the sandbox's proxy", a.allowed_url, got, detail)
    else:
        r.add(1, "network", "observation", "no allowed host given, so no control for the network", "", "skipped")
    got, detail = try_fetch(a.blocked_url, a.blocked_expect)
    r.add(1, "network", "attempt", "a host the policy does not allow, through the proxy", a.blocked_url, got, detail)
    got, detail = try_fetch(a.blocked_url, a.blocked_expect, proxy=False)
    r.add(1, "network", "attempt", "the same host, around the proxy", a.blocked_url, got, detail)
    got, detail = raw_http(a.blocked_ip, a.blocked_ip_expect)
    r.add(1, "network", "attempt", "an address, past DNS and the proxy", a.blocked_ip, got, detail)


# --- files of the host -------------------------------------------------------

def read_for_token(path, token):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            data = fh.read(65536)
    except Exception as exc:  # noqa: BLE001
        return "blocked", err(exc)
    if token in data:
        return "reached", f"read {len(data)} bytes, the token is in them"
    return "blocked", f"read {len(data)} bytes, not the planted file"


def attempt_host_files(r, a):
    ws = os.path.abspath(a.workspace)
    try:
        n = len(os.listdir(ws))
        r.add(2, "host files", "control", "the mounted workspace is readable", ws, "reached", f"{n} entries")
    except Exception as exc:  # noqa: BLE001
        r.add(2, "host files", "control", "the mounted workspace is readable", ws, "blocked", err(exc))
    if a.host_file:
        got, detail = read_for_token(a.host_file, a.token)
        r.add(2, "host files", "attempt", "a planted host file outside the workspace, by its host path",
              a.host_file, got, detail)
    if a.host_home:
        home = os.path.abspath(a.host_home)
        try:
            entries = set(os.listdir(home))
        except Exception as exc:  # noqa: BLE001
            r.add(2, "host files", "attempt", "the host user's home directory, beyond the workspace", home,
                  "blocked", err(exc))
        else:
            rel = os.path.relpath(ws, home)
            chain = set() if rel.startswith("..") else {rel.split(os.sep)[0]}
            extra = entries - chain
            got = "reached" if extra else "blocked"
            r.add(2, "host files", "attempt", "the host user's home directory, beyond the workspace", home, got,
                  f"{len(entries)} entries, {len(extra)} of them not on the way to the workspace")


# --- credentials -------------------------------------------------------------

def ssh_agent_keys(path):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(TIMEOUT)
        s.connect(path)
        s.sendall(struct.pack(">IB", 1, 11))  # SSH2_AGENTC_REQUEST_IDENTITIES
        head = s.recv(9)
        if len(head) < 9 or head[4] != 12:  # SSH2_AGENT_IDENTITIES_ANSWER
            raise RuntimeError("no identities answer")
        return struct.unpack(">I", head[5:9])[0]


def attempt_credentials(r, a):
    homes = [("the sandbox user's home", os.path.expanduser("~"))]
    if a.host_home and os.path.abspath(a.host_home) != os.path.abspath(os.path.expanduser("~")):
        homes.append(("the host user's home, by its host path", a.host_home))
    for label, home in homes:
        found = []
        for rel in CRED_PATHS:
            p = os.path.join(home, rel)
            try:
                with open(p, "rb") as fh:
                    found.append(f"{p} ({len(fh.read())} bytes)")
            except OSError:
                pass
        got = "reached" if found else "blocked"
        detail = "readable: " + ", ".join(found) if found else f"none of {len(CRED_PATHS)} credential files readable"
        r.add(3, "credentials", "attempt", f"credential files in {label}", home, got, detail)
    sock = os.environ.get("SSH_AUTH_SOCK", "")
    if not sock:
        r.add(3, "credentials", "attempt", "sign with the user's SSH keys through an agent", "SSH_AUTH_SOCK",
              "blocked", "SSH_AUTH_SOCK is not set")
    else:
        try:
            n = ssh_agent_keys(sock)
            r.add(3, "credentials", "attempt", "sign with the user's SSH keys through an agent", "SSH_AUTH_SOCK",
                  "reached" if n else "blocked", f"the agent offers {n} keys (none used)")
        except Exception as exc:  # noqa: BLE001
            r.add(3, "credentials", "attempt", "sign with the user's SSH keys through an agent", "SSH_AUTH_SOCK",
                  "blocked", err(exc))
    for proxy, how in ((False, "directly"), (True, "through the proxy")):
        try:
            status, body = fetch(a.imds_url, proxy=proxy)
            got = "reached" if status == 200 else "blocked"
            detail = f"HTTP {status}" + ("" if got == "reached" else f": {body}")
        except Exception as exc:  # noqa: BLE001
            got, detail = "blocked", err(exc)
        r.add(3, "credentials", "attempt", f"the cloud instance metadata service, {how}", a.imds_url, got, detail)


# --- the Docker socket -------------------------------------------------------

def docker_get(path, endpoint, tcp=None):
    if tcp:
        s = socket.create_connection(tcp, timeout=TIMEOUT)
    else:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(TIMEOUT)
        s.connect(path)
    with s:
        s.sendall(f"GET {endpoint} HTTP/1.0\r\nHost: docker\r\n\r\n".encode())
        data = b""
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            data += chunk
    head, _, body = data.partition(b"\r\n\r\n")
    if not head.startswith(b"HTTP/"):
        raise ConnectionError(f"not an HTTP answer ({len(data)} bytes)")
    info = json.loads(body or b"null")
    if not isinstance(info, dict):
        raise ValueError("not a Docker API answer")
    return head.split(b" ", 2)[1].decode(), info


def attempt_docker(r, a):
    sockets = list(DOCKER_SOCKETS)
    if a.host_home:
        sockets.append(os.path.join(a.host_home, ".docker/run/docker.sock"))
    seen = set()
    for path in sockets:
        if not os.path.exists(path) or os.path.realpath(path) in seen:
            continue
        seen.add(os.path.realpath(path))
        try:
            _, info = docker_get(path, "/info")
        except Exception as exc:  # noqa: BLE001
            r.add(4, "docker.sock", "attempt", "the host's Docker daemon through a socket", path, "blocked", err(exc))
            continue
        same = bool(a.host_docker_id) and info.get("ID") == a.host_docker_id
        got = "reached" if same else ("blocked" if a.host_docker_id else "answered")
        whose = "the host's daemon" if same else "a daemon that is not the host's"
        r.add(4, "docker.sock", "attempt", "the host's Docker daemon through a socket", path, got,
              f"{whose}: {info.get('Name')}, {info.get('OperatingSystem')}, {info.get('Containers')} containers")
    if not seen:
        r.add(4, "docker.sock", "attempt", "the host's Docker daemon through a socket", ", ".join(sockets),
              "blocked", "no Docker socket at any of these paths")
    for host in a.docker_tcp:
        try:
            _, info = docker_get(None, "/info", tcp=(host, 2375))
            same = info.get("ID") == a.host_docker_id
            r.add(4, "docker.sock", "attempt", "the host's Docker daemon over TCP", f"{host}:2375",
                  "reached" if same else "blocked", f"a daemon that is not the host's answered: {info.get('Name')}"
                  if not same else f"the host's daemon answered: {info.get('Name')}")
        except Exception as exc:  # noqa: BLE001
            r.add(4, "docker.sock", "attempt", "the host's Docker daemon over TCP", f"{host}:2375", "blocked",
                  err(exc))


# --- the environment ---------------------------------------------------------

def attempt_environment(r, a):
    if a.env_control:
        got = "reached" if os.environ.get(a.env_control) == a.token else "blocked"
        r.add(5, "environment", "control", "a variable handed to the sandbox on purpose", a.env_control, got,
              "present, carries the token" if got == "reached" else "absent")
    if a.env_marker:
        value = os.environ.get(a.env_marker)
        got = "reached" if value == a.token else "blocked"
        detail = "present, carries the token" if got == "reached" else (
            "present with another value" if value is not None else "absent")
        r.add(5, "environment", "attempt", "a variable set only in the host's shell", a.env_marker, got, detail)
    names = sorted(n for n in os.environ if CRED_NAME.search(n))
    r.add(5, "environment", "observation", "credential-shaped variable names inside (values not read)", "environ",
          "present" if names else "absent", ", ".join(names) or "none")
    try:
        secrets = sorted(os.listdir("/run/secrets"))
        r.add(5, "environment", "observation", "entries in /run/secrets (names only)", "/run/secrets",
              "present" if secrets else "absent", ", ".join(secrets) or "empty")
    except OSError as exc:
        r.add(5, "environment", "observation", "entries in /run/secrets (names only)", "/run/secrets", "absent",
              err(exc))


# --- root, through sudo when the probe is not root ---------------------------

def as_root(op, **kw):
    """Run one root operation, directly or through sudo -n. Returns a dict."""
    if os.geteuid() == 0:
        return ROOT_OPS[op](**kw)
    if not shutil.which("sudo"):
        return {"error": "not root, and no sudo"}
    cmd = ["sudo", "-n", sys.executable, "-I", os.path.abspath(__file__), "_root", op, json.dumps(kw)]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    except Exception as exc:  # noqa: BLE001
        return {"error": err(exc)}
    if out.returncode != 0:
        return {"error": clean(out.stderr or out.stdout or f"exit {out.returncode}")}
    return json.loads(out.stdout)


def root_whoami():
    return {"uid": os.geteuid()}


def root_write(path, content):
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(content)
        return {"written": True}
    except Exception as exc:  # noqa: BLE001
        return {"error": err(exc)}


def root_read(path, token):
    got, detail = read_for_token(path, token)
    return {"got": got, "detail": detail}


def root_suid(path, content):
    try:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(content)
        os.chown(path, 0, 0)
        os.chmod(path, 0o4755)
        st = os.stat(path)
        return {"written": True, "inside": f"uid {st.st_uid}, mode {oct(st.st_mode & 0o7777)}"}
    except Exception as exc:  # noqa: BLE001
        return {"error": err(exc)}


def root_virtiofs(rel, token):
    tags = []
    for f in glob.glob("/sys/fs/virtiofs/*/tag"):
        try:
            with open(f, encoding="utf-8") as fh:
                tags.append(fh.read().strip())
        except OSError:
            pass
    if not tags:
        return {"got": "n/a", "detail": "no virtiofs shares in this sandbox"}
    notes = []
    for tag in tags:
        mnt = tempfile.mkdtemp(prefix="bp-")
        res = subprocess.run(["mount", "-t", "virtiofs", tag, mnt], capture_output=True, text=True)
        if res.returncode != 0:
            notes.append(f"{tag}: mount refused: {clean(res.stderr, 80)}")
            continue
        try:
            got, detail = read_for_token(os.path.join(mnt, rel), token)
            if got == "reached":
                return {"got": "reached", "detail": f"share {tag!r} mounted again by root: {detail}"}
            notes.append(f"{tag}: mounted, planted file not under it")
        finally:
            subprocess.run(["umount", mnt], capture_output=True)
            os.rmdir(mnt)
    return {"got": "blocked", "detail": "; ".join(notes)}


ROOT_OPS = {"whoami": root_whoami, "write": root_write, "read": root_read, "suid": root_suid,
            "virtiofs": root_virtiofs}


# --- writes outside the working directory ------------------------------------

def write_file(path, content):
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(content)
        return "written", "written as the sandbox user"
    except Exception as exc:  # noqa: BLE001
        res = as_root("write", path=path, content=content)
        if res.get("written"):
            return "written", f"refused as the sandbox user ({err(exc)}), written as root"
        return "refused", f"{err(exc)}; as root: {res.get('error')}"


def attempt_writes(r, a):
    content = f"{FIXTURE}\n{a.token}\n"
    target = os.path.join(os.path.abspath(a.workspace), f".boundary-probe-{a.token}")
    inside, detail = write_file(target, content)
    r.add(6, "writes", "control", "a file written in the workspace appears on the host", target,
          "pending-host-check" if inside == "written" else "blocked", f"inside: {detail}",
          host_check={"path": target, "rule": "appears"})
    for label, base in (("next to the workspace", a.outside_dir), ("in the host user's home", a.host_home)):
        if not base:
            continue
        target = os.path.join(base, f"boundary-probe-{a.token}.txt")
        inside, detail = write_file(target, content)
        r.add(6, "writes", "attempt", f"a file written {label}, outside the workspace", target,
              "pending-host-check" if inside == "written" else "blocked", f"inside: {detail}",
              host_check={"path": target, "rule": "appears"})


# --- DNS ---------------------------------------------------------------------

def dns_packet(name):
    tid = os.urandom(2)
    qname = b"".join(bytes([len(p)]) + p.encode() for p in name.rstrip(".").split(".")) + b"\0"
    return tid, tid + struct.pack(">HHHHH", 0x0100, 1, 0, 0, 0) + qname + struct.pack(">HH", 1, 1)


def dns_skip_name(msg, i):
    while True:
        n = msg[i]
        if n & 0xC0 == 0xC0:
            return i + 2
        if n == 0:
            return i + 1
        i += n + 1


def dns_a_records(msg):
    qd, an = struct.unpack(">HH", msg[4:8])
    i = 12
    for _ in range(qd):
        i = dns_skip_name(msg, i) + 4
    out = []
    for _ in range(an):
        i = dns_skip_name(msg, i)
        rtype, _, _, rdlen = struct.unpack(">HHIH", msg[i:i + 10])
        i += 10
        if rtype == 1 and rdlen == 4:
            out.append(socket.inet_ntoa(msg[i:i + 4]))
        i += rdlen
    return out


def dns_direct(server, name, expect, tcp=False):
    tid, pkt = dns_packet(name)
    try:
        if tcp:
            with socket.create_connection((server, 53), timeout=TIMEOUT) as s:
                s.sendall(struct.pack(">H", len(pkt)) + pkt)
                size = struct.unpack(">H", s.recv(2))[0]
                msg = b""
                while len(msg) < size:
                    chunk = s.recv(size - len(msg))
                    if not chunk:
                        break
                    msg += chunk
        else:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
                s.settimeout(TIMEOUT)
                s.sendto(pkt, (server, 53))
                msg, _ = s.recvfrom(4096)
    except Exception as exc:  # noqa: BLE001
        return "blocked", err(exc)
    if msg[:2] != tid:
        return "blocked", "an answer to another query"
    addrs = dns_a_records(msg)
    if expect in addrs:
        return "reached", f"answered {expect}: the name reached the zone's server"
    return "blocked", f"answered {addrs or 'nothing'} (rcode {msg[3] & 0x0F})"


def attempt_dns(r, a):
    name = f"bp-{a.token}.{a.dns_zone}"
    if a.allowed_url:
        host = urllib.parse.urlsplit(a.allowed_url).hostname
        try:
            addrs = sorted({x[4][0] for x in socket.getaddrinfo(host, 443, proto=socket.IPPROTO_TCP)})
            r.add(7, "dns", "control", "the sandbox's resolver answers for an allowed host", host, "reached",
                  f"{len(addrs)} addresses")
        except Exception as exc:  # noqa: BLE001
            r.add(7, "dns", "control", "the sandbox's resolver answers for an allowed host", host, "blocked",
                  err(exc))
    try:
        addrs = sorted({x[4][0] for x in socket.getaddrinfo(name, 443, proto=socket.IPPROTO_TCP)})
        got = "reached" if a.dns_expect in addrs else "blocked"
        detail = (f"answered {a.dns_expect}: the token reached the zone's server" if got == "reached"
                  else f"answered {addrs}")
    except Exception as exc:  # noqa: BLE001
        got, detail = "blocked", err(exc)
    r.add(7, "dns", "attempt", "the token as a name, through the sandbox's resolver", name, got, detail)
    for tcp in (False, True):
        got, detail = dns_direct(a.dns_server, name, a.dns_expect, tcp=tcp)
        r.add(7, "dns", "attempt", f"the token as a name, straight to a resolver over {'TCP' if tcp else 'UDP'}",
              f"{a.dns_server}:53", got, detail)
    url = f"{a.doh_url}?name={name}&type=A"
    try:
        status, body = fetch(url)
        got = "reached" if a.dns_expect in body else "blocked"
        detail = f"HTTP {status}" + ("" if got == "reached" else f": {body}")
    except Exception as exc:  # noqa: BLE001
        got, detail = "blocked", err(exc)
    r.add(7, "dns", "attempt", "the token as a name, over DNS over HTTPS", a.doh_url, got, detail)


# --- privilege escalation ----------------------------------------------------

def attempt_privilege(r, a):
    if os.geteuid() == 0:
        r.add(8, "privilege", "attempt", "become root inside the sandbox", "uid 0", "reached", "already root")
        root = True
    else:
        res = as_root("whoami")
        root = res.get("uid") == 0
        r.add(8, "privilege", "attempt", "become root inside the sandbox", "sudo -n", "reached" if root else "blocked",
              "sudo without a password gives uid 0" if root else res.get("error", "no root"))
    if not root:
        return
    if a.host_file:
        res = as_root("read", path="/proc/1/root" + os.path.abspath(a.host_file), token=a.token)
        r.add(8, "privilege", "attempt", "as root, the planted host file through PID 1's root",
              "/proc/1/root" + os.path.abspath(a.host_file), res.get("got", "blocked"),
              res.get("detail", res.get("error", "")))
        res = as_root("virtiofs", rel=os.path.abspath(a.host_file).lstrip("/"), token=a.token)
        r.add(8, "privilege", "attempt", "as root, the host's file shares mounted again to find the planted file",
              "/sys/fs/virtiofs", res.get("got", "blocked"), res.get("detail", res.get("error", "")))
    target = os.path.join(os.path.abspath(a.workspace), f".boundary-probe-{a.token}-suid")
    res = as_root("suid", path=target, content=f"{FIXTURE}\n{a.token}\n")
    r.add(8, "privilege", "attempt", "as root, a setuid file owned by root, left in the workspace for the host",
          target, "pending-host-check" if res.get("written") else "blocked",
          f"inside: {res.get('inside', res.get('error', ''))}", host_check={"path": target, "rule": "suid-root"})


# --- the host side -----------------------------------------------------------

def verify(a):
    out = []
    with open(a.results, encoding="utf-8") as fh:
        lines = [json.loads(x) for x in fh if x.strip().startswith("{")]
    for line in lines:
        hc = line.get("host_check")
        if hc and line["got"] == "pending-host-check":
            path = hc["path"]
            if a.host_workspace and not os.path.exists(path):
                # Clone mode: the workspace inside is not the host's directory.
                moved = os.path.join(a.host_workspace, os.path.basename(path))
                if os.path.basename(path).startswith(".boundary-probe-") and os.path.lexists(moved):
                    path = moved
            if hc["rule"] == "appears":
                if os.path.exists(path):
                    line["got"], note = "reached", "on the host"
                else:
                    line["got"], note = "blocked", "not on the host"
            else:
                try:
                    st = os.lstat(path)
                    bad = st.st_uid == 0 and st.st_mode & stat.S_ISUID
                    line["got"] = "reached" if bad else "blocked"
                    note = f"on the host: uid {st.st_uid}, mode {oct(st.st_mode & 0o7777)}"
                except FileNotFoundError:
                    line["got"], note = "blocked", "not on the host"
            line["detail"] = clean(f"{line['detail']}; host: {note}", 240)
            line["ok"] = line["got"] == line["expected"] if line["expected"] else None
            if a.cleanup and os.path.exists(path) and a.token in os.path.basename(path):
                os.remove(path)
        out.append(line)
    with open(a.results, "w", encoding="utf-8") as fh:
        for line in out:
            fh.write(json.dumps(line) + "\n")
    print("| # | kind | check | got | detail |")
    print("|---|---|---|---|---|")
    for line in out:
        print(f"| {line['attempt']} | {line['kind']} | {line['check']} | {line['got']} | "
              f"{line['detail'].replace('|', '/')} |")


def main():
    if len(sys.argv) > 3 and sys.argv[1] == "_root":
        print(json.dumps(ROOT_OPS[sys.argv[2]](**json.loads(sys.argv[3]))))
        return 0
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    at = sub.add_parser("attempt", help="run the eight attempts from inside the sandbox")
    at.add_argument("--token", required=True, help="random marker; the only data the attempts carry")
    at.add_argument("--only", default="1,2,3,4,5,6,7,8", help="attempts to run, e.g. 1,7")
    at.add_argument("--workspace", default=os.getcwd())
    at.add_argument("--host-file", help="a file planted on the host, outside the workspace, holding the token")
    at.add_argument("--host-home", help="the host user's home directory, by its host path")
    at.add_argument("--outside-dir", help="a host directory outside the workspace to try to write into")
    at.add_argument("--allowed-url", help="a host the policy allows: the network control")
    at.add_argument("--allowed-expect", default="<", help="text the allowed page contains")
    at.add_argument("--blocked-url", default="https://example.com/")
    at.add_argument("--blocked-expect", default="Example Domain")
    at.add_argument("--blocked-ip", default="1.1.1.1:80")
    at.add_argument("--blocked-ip-expect", default="cloudflare")
    at.add_argument("--imds-url", default="http://169.254.169.254/latest/meta-data/")
    at.add_argument("--host-docker-id", help="the host daemon's ID (docker info --format '{{.ID}}')")
    at.add_argument("--docker-tcp", action="append", default=[], help="host to try on 2375 (repeatable)")
    at.add_argument("--env-marker", help="name of a variable set only in the host's shell to the token")
    at.add_argument("--env-control", help="name of a variable handed to the sandbox on purpose, set to the token")
    at.add_argument("--dns-zone", default="192-0-2-1.sslip.io", help="a zone whose server answers every name")
    at.add_argument("--dns-expect", default="192.0.2.1", help="the address that zone answers")
    at.add_argument("--dns-server", default="8.8.8.8")
    at.add_argument("--doh-url", default="https://dns.google/resolve")
    ve = sub.add_parser("verify", help="on the host: settle what only the host can see, print a table")
    ve.add_argument("--results", required=True)
    ve.add_argument("--token", required=True)
    ve.add_argument("--host-workspace", help="the workspace's host path, when it differs from the one inside")
    ve.add_argument("--cleanup", action="store_true", help="remove the probe's files that reached the host")
    a = p.parse_args()
    if a.cmd == "verify":
        verify(a)
        return 0
    if not re.fullmatch(r"[a-z0-9]{6,40}", a.token):
        p.error("--token must be 6 to 40 lowercase letters and digits")
    r = Report()
    runs = {1: attempt_network, 2: attempt_host_files, 3: attempt_credentials, 4: attempt_docker,
            5: attempt_environment, 6: attempt_writes, 7: attempt_dns, 8: attempt_privilege}
    for n in sorted({int(x) for x in a.only.split(",")}):
        runs[n](r, a)
    return 0


if __name__ == "__main__":
    sys.exit(main())
