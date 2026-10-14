#!/usr/bin/env bash
# tests/e2e/run.sh - prove the sandbox does what the README says, against the
# kind cluster in the current kubeconfig (kind/cluster.yaml, gVisor installed,
# manifests applied).
#
# Every refusal is paired with a control that must succeed, so a check cannot
# pass because the environment refuses everything:
#
#   0. the node has no swap (a gVisor pod's memory limit depends on it)
#   1. a sandbox pod runs on gVisor's kernel, not the node's
#   2. admission refuses each planted manifest in tests/e2e/plants for the
#      reason it names, and admits the compliant control
#   3. the demo agent, hijacked by a prompt injection in its tool's answer,
#      reaches its tool and nothing else
#   4. from outside the sandbox, the same addresses answer
#   5. with the sandbox's egress opened by mistake, corp still refuses it
#   6. a sandbox pod is killed at its memory limit, and the namespace quota
#      refuses a pod that would exceed it
#
# Needs kubectl and python3. Writes a summary to $GITHUB_STEP_SUMMARY when set.
# shellcheck disable=SC2015
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CLUSTER="${CLUSTER:-agent-sandbox}"
BUSYBOX=docker.io/library/busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e
CURL=docker.io/curlimages/curl:8.22.0@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777
PYTHON=docker.io/library/python:3.13-alpine@sha256:2d9aefe2fef018a7eb2c13064c89c71929800fd2e5dccdbf52ea5da5bb8d929a
results=()
failed=0

pass() { results+=("PASS  $1"); printf '  ok    %s\n' "$1"; }
fail() { results+=("FAIL  $1"); printf '  FAIL  %s\n' "$1"; failed=1; }
step() { printf '\n== %s\n' "$*"; }

# shellcheck disable=SC2329  # called by the EXIT trap
cleanup() {
  kubectl -n agents delete networkpolicy e2e-open-egress --ignore-not-found >/dev/null 2>&1
  kubectl -n agents delete pod e2e-probe e2e-wall e2e-hog --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl delete namespace e2e-control --ignore-not-found --wait=false >/dev/null 2>&1
}
trap cleanup EXIT

# A pod in the sandbox that meets every admission rule. $1 name, $2 image,
# $3 memory limit, then the command.
sandbox_pod() {
  local name="$1" image="$2" memory="$3"; shift 3
  python3 - "$name" "$image" "$memory" "$@" <<'PY' | kubectl apply -f - >/dev/null
import json, sys
name, image, memory, *cmd = sys.argv[1:]
print(json.dumps({
  "apiVersion": "v1", "kind": "Pod",
  "metadata": {"name": name, "namespace": "agents"},
  "spec": {
    "runtimeClassName": "gvisor", "automountServiceAccountToken": False, "restartPolicy": "Never",
    "securityContext": {"runAsNonRoot": True, "runAsUser": 10001, "runAsGroup": 10001,
                        "seccompProfile": {"type": "RuntimeDefault"}},
    "containers": [{
      "name": "c", "image": image, "command": cmd,
      "resources": {"requests": {"cpu": "10m", "memory": "16Mi"}, "limits": {"cpu": "200m", "memory": memory}},
      "securityContext": {"allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True,
                          "capabilities": {"drop": ["ALL"]}}}]}}))
PY
}
# Wait for a pod to finish; prints its phase.
finished() {
  local phase=""
  for _ in $(seq 1 60); do
    phase="$(kubectl -n "$1" get pod "$2" -o jsonpath='{.status.phase}' 2>/dev/null)"
    case "$phase" in Succeeded|Failed) break ;; esac
    sleep 3
  done
  echo "$phase"
}
# "url code" lines, from inside a pod that runs curl against each URL. The
# single quotes are on purpose: the pod's shell expands it, not this one.
# shellcheck disable=SC2016
probe_script='for u in "$@"; do printf "%s %s\n" "$u" "$(curl -s -o /dev/null -w "%{http_code}" --max-time 6 "$u")"; done'
CORP=http://internal-records.corp.svc.cluster.local:9898/
OUTSIDE=https://example.com/

# --- 0 -----------------------------------------------------------------------
step "0. the node has no swap"
swap=""
for node in $(kind get nodes --name "$CLUSTER" 2>/dev/null); do
  swap+="$(docker exec "$node" awk 'NR > 1' /proc/swaps)"
done
if [ -z "$swap" ]; then pass "no swap on the node; a sandbox pod's memory limit holds (see docs/threat-model.md)"; else
  fail "the node has swap; under gVisor a pod's memory limit is then RAM plus unlimited swap. Run swapoff -a first."; fi

# --- 1 -----------------------------------------------------------------------
step "1. gVisor's kernel, not the node's"
sandbox_pod e2e-probe "$BUSYBOX" 32Mi sleep 300
kubectl -n agents wait --for=condition=Ready pod/e2e-probe --timeout=120s >/dev/null 2>&1
pod_kernel="$(kubectl -n agents exec e2e-probe -- uname -r 2>/dev/null)"
node_kernel="$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kernelVersion}')"
if [[ "$pod_kernel" == *gvisor* ]] && [[ "$node_kernel" != *gvisor* ]]; then
  pass "a sandbox pod sees kernel $pod_kernel; the node runs $node_kernel"
else
  fail "a sandbox pod sees kernel '${pod_kernel:-none}', the node '$node_kernel'"
fi
kubectl -n agents delete pod e2e-probe --wait=false >/dev/null 2>&1

# --- 2 -----------------------------------------------------------------------
step "2. admission"
for plant in "$HERE"/plants/*.yaml; do
  name="$(basename "$plant" .yaml)"
  expect="$(sed -n 's/^# expect: //p' "$plant")"
  out="$(kubectl apply --dry-run=server -f "$plant" 2>&1)"
  rc=$?
  if [ "$expect" = admitted ]; then
    [ $rc -eq 0 ] && pass "$name: admitted" || fail "$name was refused: $out"
  elif [ $rc -ne 0 ] && grep -q "$expect" <<<"$out"; then
    pass "$name: refused ($expect)"
  else
    fail "$name: expected a refusal saying '$expect', got (rc=$rc): $out"
  fi
done

# --- 3 -----------------------------------------------------------------------
step "3. the demo agent, hijacked by its tool's answer"
kubectl -n agents delete job agent-demo --ignore-not-found --wait=true >/dev/null 2>&1
kubectl apply -f "$ROOT/manifests/agent/job.yaml" >/dev/null
kubectl -n agents wait --for=jsonpath='{.status.conditions[?(@.status=="True")].type}' job/agent-demo --timeout=180s >/dev/null 2>&1
report="$(kubectl -n agents logs job/agent-demo 2>/dev/null)"
lines="$(python3 - <<'PY' "$report"
import json, sys
for raw in sys.argv[1].splitlines():
    try:
        r = json.loads(raw)
    except ValueError:
        continue
    if "check" in r:
        print("%s\t%s\t%s\t%s" % ("ok" if r["ok"] else "bad", r["check"], r["expected"], r["got"]))
PY
)"
if [ -z "$lines" ]; then fail "the agent wrote no report: ${report:0:300}"; fi
while IFS=$'\t' read -r ok check expected got; do
  [ -z "$ok" ] && continue
  [ "$ok" = ok ] && pass "agent: $check: $got" || fail "agent: $check: expected $expected, got $got"
done <<<"$lines"

# --- 4 -----------------------------------------------------------------------
step "4. the same addresses, from outside the sandbox"
kubectl create namespace e2e-control --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n e2e-control run e2e-control --image="$CURL" --restart=Never --command -- sh -c "$probe_script" sh "$CORP" "$OUTSIDE" >/dev/null
[ "$(finished e2e-control e2e-control)" = Succeeded ] || true
control="$(kubectl -n e2e-control logs e2e-control 2>/dev/null)"
if grep -q "^$CORP 200" <<<"$control" && grep -q "^$OUTSIDE 200" <<<"$control"; then
  pass "outside the sandbox, corp and the internet answer: the agent's refusals are the sandbox's doing"
else
  fail "the control outside the sandbox did not reach corp and the internet: ${control:-no output}"
fi

# --- 5 -----------------------------------------------------------------------
step "5. the first wall opened by mistake; the second holds"
kubectl apply -f - >/dev/null <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: e2e-open-egress
  namespace: agents
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - {}
EOF
sandbox_pod e2e-wall "$CURL" 64Mi sh -c "$probe_script" sh "$CORP" "$OUTSIDE"
finished agents e2e-wall >/dev/null
wall="$(kubectl -n agents logs e2e-wall 2>/dev/null)"
kubectl -n agents delete networkpolicy e2e-open-egress >/dev/null 2>&1
if grep -q "^$OUTSIDE 200" <<<"$wall" && grep -q "^$CORP 000" <<<"$wall"; then
  pass "with all egress allowed the internet answers the sandbox, and corp still refuses it"
else
  fail "with egress opened: ${wall:-no output}"
fi

# --- 6 -----------------------------------------------------------------------
step "6. limits"
sandbox_pod e2e-hog "$PYTHON" 128Mi python3 -c "
import time
chunks = []
for i in range(64):
    chunks.append(b'\x01' * (16 * 1024 * 1024))
    print(len(chunks) * 16, flush=True)
    time.sleep(0.05)"
finished agents e2e-hog >/dev/null
reason="$(kubectl -n agents get pod e2e-hog -o jsonpath='{.status.containerStatuses[0].state.terminated.reason}' 2>/dev/null)"
held="$(kubectl -n agents logs e2e-hog 2>/dev/null | tail -1)"
# The limit is 128Mi plus gVisor's 32Mi overhead, at the pod's cgroup.
if [ "$reason" = OOMKilled ] && [ "${held:-0}" -le 160 ]; then
  pass "a sandbox pod with a 128Mi limit was killed holding ${held}MiB"
else
  fail "the memory hog ended '${reason:-running}' holding ${held:-?}MiB against a 128Mi limit"
fi
quota="$(python3 - <<'PY' | kubectl apply --dry-run=server -f - 2>&1
import json
print(json.dumps({"apiVersion": "v1", "kind": "Pod", "metadata": {"name": "e2e-greedy", "namespace": "agents"},
  "spec": {"runtimeClassName": "gvisor", "automountServiceAccountToken": False,
    "securityContext": {"runAsNonRoot": True, "runAsUser": 10001, "seccompProfile": {"type": "RuntimeDefault"}},
    "containers": [{"name": "c", "image": "docker.io/library/busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e",
      "command": ["sleep", "60"],
      "resources": {"requests": {"cpu": "10m", "memory": "16Mi"}, "limits": {"cpu": "100m", "memory": "3Gi"}},
      "securityContext": {"allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True, "capabilities": {"drop": ["ALL"]}}}]}}))
PY
)"
grep -q "exceeded quota" <<<"$quota" && pass "a pod asking for 3Gi is refused by the namespace quota" \
  || fail "a pod asking for 3Gi was not refused by the quota: $quota"

# A copy the status workflow reads (scripts/status.py), when one is asked for.
if [ -n "${E2E_RESULTS:-}" ]; then
  { printf 'R\t%s\n' "${results[@]}"; } | python3 -c '
import json, sys
checks, measured = [], []
for line in sys.stdin:
    kind, _, text = line.rstrip("\n").partition("\t")
    if kind == "R" and text:
        state, _, name = text.partition("  ")
        checks.append({"state": state.strip(), "name": name.strip()})
    elif kind == "M" and text:
        measured.append(text)
json.dump({"checks": checks, "measured": measured}, sys.stdout)
' >"$E2E_RESULTS"
fi

# --- summary -----------------------------------------------------------------
printf '\n'
printf '%s\n' "${results[@]}"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  { echo "### agent sandbox e2e"; echo; echo '```'; printf '%s\n' "${results[@]}"; echo '```'; } >>"$GITHUB_STEP_SUMMARY"
fi
exit "$failed"
