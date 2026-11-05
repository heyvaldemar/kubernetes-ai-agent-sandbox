#!/usr/bin/env bash
# probes/sbx-probe.sh - run the eight attempts of boundary_probe.py inside a
# Docker Sandboxes sandbox, then settle on the host what only the host can see.
#
#   probes/sbx-probe.sh SANDBOX HOST_WORKSPACE OUT_DIR [ALLOWED_URL [ALLOWED_TEXT]]
#
# SANDBOX is a sandbox that exists (sbx create AGENT HOST_WORKSPACE, with or
# without --clone). ALLOWED_URL is a host its policy allows, the network
# control; ALLOWED_TEXT is text that page contains.
#
# TEST FIXTURE. The run plants a file holding a random token next to the
# workspace (outside it), sets one variable to the token only in this shell,
# hands another to the sandbox on purpose with sbx exec -e, copies the probe
# in, runs it, and then checks on the host which of the files written inside
# arrived and who owns them there. It removes the probe's own files from the
# host afterwards. Nothing is pushed or published.
#
# Writes OUT_DIR/results-*.jsonl (one line per check), table-*.md, the
# sandbox's policy log and run-*.txt (versions, date, token).
set -euo pipefail

sandbox="${1:?usage: sbx-probe.sh SANDBOX HOST_WORKSPACE OUT_DIR [ALLOWED_URL [ALLOWED_TEXT]]}"
ws="$(cd "${2:?host workspace}" && pwd)"
out="${3:?output directory}"
allowed="${4:-}"
allowed_text="${5:-<}"
here="$(cd "$(dirname "$0")" && pwd)"

token="$(python3 -I -c 'import secrets; print(secrets.token_hex(8))')"
outside="$(dirname "$ws")/boundary-probe-outside"
mkdir -p "$out" "$outside"
fixture="$outside/host-only-$token.txt"
printf 'TEST FIXTURE: a host file outside the sandbox workspace\n%s\n' "$token" > "$fixture"
tag="$sandbox-$token"

{
  echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "sbx: $(sbx version 2>&1 | head -n 1)"
  echo "docker: $(docker version --format '{{.Server.Version}}' 2>&1)"
  echo "sandbox: $sandbox"
  echo "host workspace: $ws"
  echo "token: $token"
} > "$out/run-$tag.txt"

sbx cp "$here/boundary_probe.py" "$sandbox:/tmp/boundary_probe.py"

set -- --token "$token" --host-file "$fixture" --host-home "$HOME" --outside-dir "$outside" \
  --host-docker-id "$(docker info --format '{{.ID}}')" \
  --docker-tcp host.docker.internal --docker-tcp gateway.docker.internal \
  --env-marker BOUNDARY_PROBE_HOST_ENV --env-control BOUNDARY_PROBE_CONTROL
if [ -n "$allowed" ]; then
  set -- "$@" --allowed-url "$allowed" --allowed-expect "$allowed_text"
fi

rc=0
BOUNDARY_PROBE_HOST_ENV="$token" sbx exec -e BOUNDARY_PROBE_CONTROL="$token" "$sandbox" \
  python3 -I /tmp/boundary_probe.py attempt "$@" \
  > "$out/results-$tag.jsonl" 2> "$out/stderr-$tag.txt" || rc=$?
echo "probe exit: $rc" >> "$out/run-$tag.txt"

python3 -I "$here/boundary_probe.py" verify --results "$out/results-$tag.jsonl" --token "$token" \
  --host-workspace "$ws" --cleanup | tee "$out/table-$tag.md"
sbx policy log "$sandbox" --json > "$out/policy-log-$tag.json" 2>&1 || true
rm -f "$fixture" "$outside/boundary-probe-$token.txt" "$HOME/boundary-probe-$token.txt"
rmdir "$outside" 2>/dev/null || true
exit "$rc"
