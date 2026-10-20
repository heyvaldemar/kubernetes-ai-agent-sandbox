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
#      reason it names, and admits the compliant controls
#   3. the demo agents: one hijacked by a prompt injection in its tool's
#      answer reaches the MCP server, its granted tool and nothing else; one
#      granted the records tool gets a record without holding the key
#   4. the MCP server: the API server and the MCP server each refuse the
#      other's token; every decision is in the MCP server's log with the
#      caller's pod; the records key exists only where it is used
#   5. from outside the sandbox, the same addresses answer
#   6. a sandbox pod resolves the cluster's names and no outside name, and
#      cannot ask the cluster's CoreDNS, which forwards; outside the sandbox
#      the same outside name resolves
#   7. with the sandbox's egress opened by mistake, corp and the tools'
#      upstreams still refuse it; with the mistake undone, the first wall
#      holds again
#   8. a sandbox pod is killed at its memory limit, and the namespace quota
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
  kubectl -n agents delete pod e2e-probe e2e-wall e2e-hog e2e-tokens --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl delete namespace e2e-control --ignore-not-found --wait=false >/dev/null 2>&1
}
trap cleanup EXIT

# A pod in the sandbox that meets every admission rule. $1 name, $2 image,
# $3 memory limit, then the command.
# A sandbox pod asks the agents' resolver, like the agents' Jobs; with
# SANDBOX_DNS=cluster it keeps the cluster's CoreDNS, which the network
# policy refuses it unless egress has been opened.
sandbox_pod() {
  local name="$1" image="$2" memory="$3"; shift 3
  python3 - "$name" "$image" "$memory" "${SANDBOX_DNS:-agents}" "$@" <<'PY' | kubectl apply -f - >/dev/null
import json, sys
name, image, memory, dns, *cmd = sys.argv[1:]
agents_dns = {"dnsPolicy": "None", "dnsConfig": {
    "nameservers": ["10.96.0.53"], "searches": ["agents.svc.cluster.local", "svc.cluster.local", "cluster.local"],
    "options": [{"name": "ndots", "value": "5"}]}} if dns == "agents" else {}
print(json.dumps({
  "apiVersion": "v1", "kind": "Pod",
  "metadata": {"name": name, "namespace": "agents"},
  "spec": dict(agents_dns, **{
    "runtimeClassName": "gvisor", "automountServiceAccountToken": False, "restartPolicy": "Never",
    "securityContext": {"runAsNonRoot": True, "runAsUser": 10001, "runAsGroup": 10001,
                        "seccompProfile": {"type": "RuntimeDefault"}},
    "containers": [{
      "name": "c", "image": image, "command": cmd,
      "resources": {"requests": {"cpu": "10m", "memory": "16Mi"}, "limits": {"cpu": "200m", "memory": memory}},
      "securityContext": {"allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True,
                          "capabilities": {"drop": ["ALL"]}}}]})}))
PY
}
# Wait for a Job to succeed or fail. (A finished Job has two True
# conditions in Kubernetes 1.37, so `kubectl wait --for=jsonpath` on them
# matches twice and errors.)
job_done() {
  for _ in $(seq 1 90); do
    [ -n "$(kubectl -n agents get job "$1" -o jsonpath='{.status.succeeded}{.status.failed}' 2>/dev/null)" ] && return 0
    sleep 2
  done
  return 1
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
RECORDS=http://records-api.corp.svc.cluster.local:8080/healthz
REPORT=http://tool-gateway.tools.svc.cluster.local:9898/
MCP=http://mcp-server.mcp.svc.cluster.local:8080/mcp
MCP_AUDIENCE=mcp.sandbox.heyvaldemar.com

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
step "3. the demo agents, through the MCP server"
kubectl -n agents delete job agent-demo records-clerk --ignore-not-found --wait=true >/dev/null 2>&1
kubectl apply -f "$ROOT/manifests/agent/job.yaml" >/dev/null
for job in agent-demo records-clerk; do
  job_done "$job" || true
  report="$(kubectl -n agents logs "job/$job" 2>/dev/null)"
  lines="$(python3 - "$report" <<'PY'
import json, sys
for raw in sys.argv[1].splitlines():
    try:
        r = json.loads(raw)
    except ValueError:
        continue
    if "check" in r:
        print("%s\t%s\t%s\t%s\t%s" % ("ok" if r["ok"] else "bad", r.get("agent", "agent"), r["check"], r["expected"], r["got"]))
PY
)"
  if [ -z "$lines" ]; then fail "$job wrote no report: ${report:0:300}"; fi
  while IFS=$'\t' read -r ok agent check expected got; do
    [ -z "$ok" ] && continue
    [ "$ok" = ok ] && pass "$agent: $check: $got" || fail "$agent: $check: expected $expected, got $got"
  done <<<"$lines"
done

# --- 4 -----------------------------------------------------------------------
step "4. the MCP server"
# Each token is good for one audience. The MCP token goes to the API server
# from here; the API token goes to the MCP server from a sandbox pod, on
# stdin, so neither is ever on a command line or in a pod spec.
mcp_token="$(kubectl -n agents create token researcher --audience "$MCP_AUDIENCE" --duration 10m)"
api_token="$(kubectl -n agents create token researcher --duration 10m)"
api_server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
code="$(printf 'header = "Authorization: Bearer %s"\n' "$mcp_token" | curl -sk -o /dev/null -w '%{http_code}' --config - "$api_server/api")"
[ "$code" = 401 ] && pass "the API server refuses the MCP token: HTTP 401" \
  || fail "the API server answered the MCP token with HTTP $code"
sandbox_pod e2e-tokens "$CURL" 32Mi sleep 300
kubectl -n agents wait --for=condition=Ready pod/e2e-tokens --timeout=120s >/dev/null 2>&1
# shellcheck disable=SC2016  # expanded by the pod's shell
ask_mcp='read -r t; printf "header = \"Authorization: Bearer %s\"\n" "$t" | curl -s -o /dev/null -w "%{http_code}" --max-time 6 --config - -X POST -H "Content-Type: application/json" -H "MCP-Protocol-Version: 2026-07-28" -H "Mcp-Method: tools/list" -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}}}}" "$1"'
with_api="$(printf '%s\n' "$api_token" | kubectl -n agents exec -i e2e-tokens -- sh -c "$ask_mcp" sh "$MCP" 2>/dev/null)"
with_mcp="$(printf '%s\n' "$mcp_token" | kubectl -n agents exec -i e2e-tokens -- sh -c "$ask_mcp" sh "$MCP" 2>/dev/null)"
unset mcp_token api_token
if [ "$with_api" = 401 ] && [ "$with_mcp" = 200 ]; then
  pass "the MCP server refuses a Kubernetes API token (401) and takes its own audience's (200)"
else
  fail "the MCP server answered an API token with ${with_api:-nothing} and its own token with ${with_mcp:-nothing}"
fi
kubectl -n agents delete pod e2e-tokens --wait=false >/dev/null 2>&1

audit="$(kubectl -n mcp logs deployment/mcp-server 2>/dev/null)"
records_log="$(kubectl -n corp logs deployment/records-api 2>/dev/null)"
while IFS=$'\t' read -r ok what; do
  [ -z "$ok" ] && continue
  [ "$ok" = ok ] && pass "audit: $what" || fail "audit: $what"
done < <(python3 - "$audit" "$records_log" <<'PY'
import json, sys
lines = [json.loads(x) for x in sys.argv[1].splitlines() if x.startswith("{")]
records = [json.loads(x) for x in sys.argv[2].splitlines() if x.startswith("{")]
def has(**want):
    return [l for l in lines if all(l.get(k) == v for k, v in want.items())]
denied = has(identity="system:serviceaccount:agents:researcher", name="records_lookup", decision="denied")
print("%s\tthe researcher's attempt at the records tool is logged as denied, with its pod%s" % (
    "ok" if denied and denied[0].get("pod", "").startswith("agent-demo-") else "bad",
    " (%s)" % denied[0]["pod"] if denied else ""))
allowed = has(identity="system:serviceaccount:agents:records-clerk", name="records_lookup", decision="allowed")
print("%s\tthe records clerk's lookup is logged as allowed, with its pod" % (
    "ok" if allowed and allowed[0].get("pod", "").startswith("records-clerk-") else "bad"))
print("%s\tthe destructive tool was never allowed to anyone" % (
    "bad" if has(name="delete_record", decision="allowed") else "ok"))
limited = has(identity="system:serviceaccount:agents:researcher", decision="rate_limited")
print("%s\tthe researcher's loop is logged as rate limited, %d times" % ("ok" if limited else "bad", len(limited)))
print("%s\tthe records service saw the lookup, and no delete" % (
    "ok" if any(r["method"] == "GET" and r["path"] == "/records/C0001" and r["status"] == 200 for r in records)
    and not any(r["method"] == "DELETE" for r in records) else "bad"))
PY
)

holders="$(kubectl get secrets -A --field-selector metadata.name=records-api-key -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{end}')"
[ "$holders" = "corp mcp " ] && pass "the records key exists in corp and mcp only, never in a sandbox namespace" \
  || fail "the records key exists in: ${holders:-nowhere}"

# --- 5 -----------------------------------------------------------------------
step "5. the same addresses, from outside the sandbox"
kubectl create namespace e2e-control --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n e2e-control run e2e-control --image="$CURL" --restart=Never --command -- sh -c "$probe_script" sh "$CORP" "$OUTSIDE" >/dev/null
[ "$(finished e2e-control e2e-control)" = Succeeded ] || true
control="$(kubectl -n e2e-control logs e2e-control 2>/dev/null)"
if grep -q "^$CORP 200" <<<"$control" && grep -q "^$OUTSIDE 200" <<<"$control"; then
  pass "outside the sandbox, corp and the internet answer: the agent's refusals are the sandbox's doing"
else
  fail "the control outside the sandbox did not reach corp and the internet: ${control:-no output}"
fi

# --- 6 -----------------------------------------------------------------------
step "6. names: the cluster's, and nothing else"
# A lookup relayed to the internet carries data out in the name it asks for.
# The agents ask a resolver of their own, which answers for cluster.local
# only, and their network policy refuses the cluster's CoreDNS. Three
# lookups from one sandbox pod, then the same outside name from outside.
kube_dns="$(kubectl -n kube-system get service kube-dns -o jsonpath='{.spec.clusterIP}')"
# shellcheck disable=SC2016
sandbox_pod e2e-names "$BUSYBOX" 32Mi sh -c 'for q in "$@"; do echo "== $q"; nslookup -timeout=3 $q 2>&1; done' sh \
  mcp-server.mcp.svc.cluster.local example.com "example.com $kube_dns"
finished agents e2e-names >/dev/null
names="$(kubectl -n agents logs e2e-names 2>/dev/null)"
answered() {  # did the lookup headed "== $1" get an address back?
  awk -v q="== $1" '$0 == q {on = 1; next} /^== / {on = 0} on' <<<"$names" | sed -n '/^Name:/,$p' | grep -qE '^Address:? [0-9]'
}
if answered mcp-server.mcp.svc.cluster.local; then
  pass "control: a sandbox pod resolves the MCP server's name through the agents' resolver"
else
  fail "control: a sandbox pod cannot resolve mcp-server.mcp.svc.cluster.local, so its refusals below prove nothing: ${names:-no output}"
fi
if answered example.com; then fail "a sandbox pod resolved example.com: DNS is a way out"; else pass "a sandbox pod resolves no outside name"; fi
if answered "example.com $kube_dns"; then
  fail "a sandbox pod asked the cluster's CoreDNS ($kube_dns) for example.com and got an answer"
else
  pass "a sandbox pod cannot ask the cluster's CoreDNS ($kube_dns), which forwards"
fi
kubectl -n e2e-control run e2e-control-names --image="$BUSYBOX" --restart=Never --command -- nslookup -timeout=3 example.com >/dev/null 2>&1
[ "$(finished e2e-control e2e-control-names)" = Succeeded ] || true
if kubectl -n e2e-control logs e2e-control-names 2>/dev/null | sed -n '/^Name:/,$p' | grep -qE '^Address:? [0-9]'; then
  pass "control: outside the sandbox, example.com resolves: the sandbox's silence is its own"
else
  fail "control: example.com did not resolve outside the sandbox either"
fi

# --- 7 -----------------------------------------------------------------------
step "7. the first wall opened by mistake; the second holds, and the first closes again"
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
SANDBOX_DNS=cluster sandbox_pod e2e-wall "$CURL" 64Mi sh -c "$probe_script" sh "$CORP" "$OUTSIDE" "$RECORDS" "$REPORT"
finished agents e2e-wall >/dev/null
wall="$(kubectl -n agents logs e2e-wall 2>/dev/null)"
kubectl -n agents delete networkpolicy e2e-open-egress >/dev/null 2>&1
if grep -q "^$OUTSIDE 200" <<<"$wall" && grep -q "^$CORP 000" <<<"$wall" &&
   grep -q "^$RECORDS 000" <<<"$wall" && grep -q "^$REPORT 000" <<<"$wall"; then
  pass "with all egress allowed the internet answers the sandbox; corp, the records service and the report service still refuse it"
else
  fail "with egress opened: ${wall:-no output}"
fi
# Undoing the mistake has to close the wall again: a new sandbox pod, after
# the policy that opened it is deleted, must not reach the internet. Polled,
# since the network plugin applies a deleted policy on its own schedule; how
# long it took is printed, and a minute without closing is a failure.
closed=""
for i in $(seq 1 12); do
  kubectl -n agents delete pod e2e-reclosed --ignore-not-found --wait=true >/dev/null 2>&1
  SANDBOX_DNS=cluster sandbox_pod e2e-reclosed "$CURL" 64Mi sh -c "$probe_script" sh "$OUTSIDE" "http://1.1.1.1/"
  finished agents e2e-reclosed >/dev/null
  again="$(kubectl -n agents logs e2e-reclosed 2>/dev/null)"
  if grep -q "^$OUTSIDE 000" <<<"$again" && grep -q "^http://1.1.1.1/ 000" <<<"$again"; then closed="$i"; break; fi
  sleep 5
done
if [ -n "$closed" ]; then
  pass "with the mistake undone, the first wall holds again for a new sandbox pod (attempt $closed)"
else
  fail "with the policy that opened egress deleted, a new sandbox pod still reached the internet a minute later: $again"
fi
# The same for DNS over UDP, which the network plugin judges on its own path:
# a new sandbox pod must not get an answer from the cluster's CoreDNS.
kube_dns="$(kubectl -n kube-system get service kube-dns -o jsonpath='{.spec.clusterIP}')"
dns_closed=""
for i in $(seq 1 12); do
  kubectl -n agents delete pod e2e-redns --ignore-not-found --wait=true >/dev/null 2>&1
  sandbox_pod e2e-redns "$BUSYBOX" 32Mi nslookup -timeout=3 example.com "$kube_dns"
  finished agents e2e-redns >/dev/null
  if ! kubectl -n agents logs e2e-redns 2>/dev/null | sed -n '/^Name:/,$p' | grep -qE '^Address:? [0-9]'; then dns_closed="$i"; break; fi
  sleep 5
done
if [ -n "$dns_closed" ]; then
  pass "with the mistake undone, the cluster's CoreDNS answers a new sandbox pod no more (attempt $dns_closed)"
else
  fail "with the policy that opened egress deleted, a new sandbox pod still got answers from the cluster's CoreDNS a minute later"
fi

# --- 8 -----------------------------------------------------------------------
step "8. limits"
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
