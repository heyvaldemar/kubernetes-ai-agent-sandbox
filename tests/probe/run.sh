#!/usr/bin/env bash
# tests/probe/run.sh - prove that probes/boundary_probe.py can tell an open
# door from a shut one, before anyone believes what it says about a sandbox.
#
# The probe runs twice on this machine's Docker:
#
#   locked  no network, a read-only root, no capabilities, no new privileges,
#           an unprivileged user and the workspace alone: every attempt must
#           be blocked, the token must not reach the target's DNS log, and the
#           controls that need no network must still pass
#   open    root, privileged, the host's PID namespace and Docker socket, the
#           planted host file, a credentials fixture, an SSH agent, a variable
#           from the host and the target on its network: each of the eight
#           attempts must get through, every control must pass, and the token
#           must reach the target's DNS log
#
# TEST FIXTURE throughout: the files planted are markers, the key is not a key,
# and the target (tests/probe/target.py) is a container on this machine. No
# outside service is touched. Needs docker and python3. On Docker Desktop the
# host's PID namespace and file ownership are the VM's, so two open checks
# (the host file through PID 1, the setuid file's owner) only pass on Linux.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PYTHON=docker.io/library/python:3.13-alpine@sha256:2d9aefe2fef018a7eb2c13064c89c71929800fd2e5dccdbf52ea5da5bb8d929a
failed=0
pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failed=1; }

token="$(python3 -I -c 'import secrets; print(secrets.token_hex(8))')"
work="$(mktemp -d)"
chmod 755 "$work"
ws="$work/workspace" outside="$work/outside" home="$work/home"
mkdir -p "$ws" "$outside" "$home/.aws" "$home/Documents"
printf 'TEST FIXTURE: a host file outside the workspace\n%s\n' "$token" > "$outside/host-only-$token.txt"
printf '[default]\n# TEST FIXTURE: not a credential\n' > "$home/.aws/credentials"
net="bp-$token" target="bp-target-$token"

# shellcheck disable=SC2329  # called by the EXIT trap
cleanup() {
  docker rm -f "$target" >/dev/null 2>&1
  docker network rm "$net" >/dev/null 2>&1
  docker run --rm -v "$work:$work" "$PYTHON" rm -rf "$work/workspace" "$work/outside" "$work/home" >/dev/null 2>&1
  rm -rf "$work"
}
trap cleanup EXIT

docker network create "$net" >/dev/null
docker run -d --name "$target" --network "$net" -v "$HERE:/t:ro" "$PYTHON" python3 -u /t/target.py >/dev/null
for _ in $(seq 1 30); do
  logs="$(docker logs "$target" 2>&1)"
  case "$logs" in *"target ready"*) break ;; esac
  sleep 1
done
target_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$target")"

args=(--token "$token" --workspace "$ws" --host-file "$outside/host-only-$token.txt" --host-home "$home"
  --outside-dir "$outside"
  --allowed-url "http://$target:8080/" --allowed-expect "boundary-probe target"
  --blocked-url "http://$target:8080/" --blocked-expect "boundary-probe target"
  --blocked-ip "$target_ip:8080" --blocked-ip-expect "boundary-probe target"
  --imds-url "http://$target_ip:8080/latest/meta-data/"
  --host-docker-id "$(docker info --format '{{.ID}}')"
  --env-marker BOUNDARY_PROBE_HOST_ENV --env-control BOUNDARY_PROBE_CONTROL
  --dns-zone probe.test --dns-expect 192.0.2.1 --dns-server "$target_ip"
  --doh-url "http://$target_ip:8080/resolve")

# judge FILE PROFILE: every attempt got what the profile demands; see the
# header for what each profile demands of the controls.
judge() {
  python3 -I - "$1" "$2" <<'EOF'
import json, sys
path, profile = sys.argv[1], sys.argv[2]
lines = [json.loads(x) for x in open(path, encoding="utf-8") if x.strip().startswith("{")]
want = "reached" if profile == "open" else "blocked"
bad = []
seen = set()
for x in lines:
    if x["kind"] == "attempt":
        if x["got"] == "n/a":
            continue
        seen.add(x["attempt"])
        if x["got"] != want:
            bad.append(x)
    elif x["kind"] == "control":
        needs_net = x["area"] in ("network", "dns")
        expect = "reached" if (profile == "open" or not needs_net) else "blocked"
        if x["got"] != expect:
            bad.append(x)
print(f"{len(lines)} lines, attempts {sorted(seen)}")
for x in bad:
    print(f"    {x['attempt']} {x['kind']}: {x['check']}: got {x['got']} ({x['detail']})")
missing = set(range(1, 9)) - seen
if missing:
    print(f"    no attempt ran for {sorted(missing)}")
sys.exit(1 if bad or missing else 0)
EOF
}

dns_seen() { docker logs "$target" 2>&1 | grep -c "$token" || true; }

printf '\n== the probe, locked in\n'
# conformance: allow-argv-secret - the token is a canary minted for this run, not a credential: the probe also names it as --token
docker run --rm --network none --read-only --tmpfs /tmp --cap-drop ALL \
  --security-opt no-new-privileges --user "$(id -u):$(id -g)" \
  -v "$ws:$ws" -v "$ROOT/probes:/p:ro" -w "$ws" -e BOUNDARY_PROBE_CONTROL="$token" \
  "$PYTHON" python3 -I /p/boundary_probe.py attempt "${args[@]}" > "$work/locked.jsonl"
python3 -I "$ROOT/probes/boundary_probe.py" verify --results "$work/locked.jsonl" --token "$token" \
  --cleanup > "$work/locked.md"
if out="$(judge "$work/locked.jsonl" locked)"; then
  pass "locked: every attempt blocked, the workspace and the handed variable still reachable ($out)"
else
  fail "locked: $out"
fi
n="$(dns_seen)"
if [ "$n" -eq 0 ]; then
  pass "locked: the token never reached the target's DNS log"
else
  fail "locked: the token reached the target's DNS log $n times"
fi

printf '\n== the probe, every door open\n'
# conformance: allow-argv-secret - the same canary, handed to the open container on purpose
docker run --rm --network "$net" --dns "$target_ip" --privileged --pid=host \
  -v /var/run/docker.sock:/var/run/docker.sock -v "$work:$work" -v "$home/.aws:/root/.aws:ro" \
  -v "$ROOT/probes:/p:ro" -v "$HERE:/t:ro" -w "$ws" \
  -e BOUNDARY_PROBE_HOST_ENV="$token" -e BOUNDARY_PROBE_CONTROL="$token" \
  "$PYTHON" sh -c 'python3 -I /t/fake_agent.py /tmp/agent.sock & sleep 1
    SSH_AUTH_SOCK=/tmp/agent.sock exec python3 -I /p/boundary_probe.py attempt "$@"' sh "${args[@]}" \
  > "$work/open.jsonl"
python3 -I "$ROOT/probes/boundary_probe.py" verify --results "$work/open.jsonl" --token "$token" \
  --cleanup > "$work/open.md"
if out="$(judge "$work/open.jsonl" open)"; then
  pass "open: each of the eight attempts got through, every control passed ($out)"
else
  fail "open: $out"
fi
n="$(dns_seen)"
if [ "$n" -gt 0 ]; then
  pass "open: the token reached the target's DNS log ($n queries)"
else
  fail "open: the token never reached the target's DNS log"
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Boundary probe, locked in"; cat "$work/locked.md"
    echo; echo "### Boundary probe, every door open"; cat "$work/open.md"
  } >> "$GITHUB_STEP_SUMMARY"
fi
printf '\n'
if [ "$failed" -eq 0 ]; then echo "boundary probe: every check passed"; else echo "boundary probe: FAILED"; fi
exit "$failed"
