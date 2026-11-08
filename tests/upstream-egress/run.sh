#!/usr/bin/env bash
# tests/upstream-egress/run.sh - measure the egress a kubernetes-sigs/
# agent-sandbox sandbox-router permits, on its v1.0.10 defaults and with the
# documented apiServerCIDRs restriction, against the kind cluster in the
# current kubeconfig.
#
# This is a measurement of an upstream project, not a check of this
# repository. It deploys the vendored upstream router manifests (v1.0.10,
# verbatim NetworkPolicy) through an operational overlay, and sends the router
# one request per target carrying X-Sandbox-Pod-IP, through a caller Pod. Every
# target is an in-cluster plain-HTTP stub; nothing reaches the real internet or
# a cloud. See docs/decisions/0007-measured-upstream-egress.md.
#
# The matrix, config (a) = upstream default, config (b) = apiServerCIDRs:
#
#   ext-stub:443    a reached  b blocked   443 to a non-API destination
#   ext-stub:6443   a reached  b blocked   6443 to a non-API destination
#   apisrv-stub:6443 a reached b reached   the API-server stand-in, kept in scope
#   ext-stub:8888   a blocked  b blocked   a non-443/6443 port to a non-sandbox pod
#   hash-stub:8888  a reached  b reached   any port to a sandbox-labelled pod
#
# Config (a) reaching ext-stub on 443/6443 is the demonstration the egress is
# open by default; config (b) blocking it is the demonstration the documented
# restriction closes it. Each is the other's control, so neither passes because
# the environment refuses or allows everything. If config (b) does NOT block
# ext-stub, the run stops INCONCLUSIVE rather than claim anything.
#
# Needs kubectl and python3. Writes the result JSON to $E2E_RESULTS.
# shellcheck disable=SC2015
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
NS=agent-sandbox-system
ROUTER_IMAGE_DIGEST="sha256:78ced4e7a3495e4bf1c23f43d8912c68f390903adc12ec5bd24d8a715e094f6a"
UPSTREAM_TAG="v1.0.10"
UPSTREAM_COMMIT="0d94fc0bd96c8024d5e7845532d2d7e2a96604ef"
RESULTS="${E2E_RESULTS:-$(mktemp)}"
work="$(mktemp -d)"

say() { printf '\n== %s\n' "$*"; }
note() { printf '  ..    %s\n' "$*"; }

# shellcheck disable=SC2329  # called by the EXIT trap
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

say "Deploy the upstream router (config a: v1.0.10 default NetworkPolicy)"
# The overlay creates agent-sandbox-system and the router; stubs.yaml the
# ext-targets and caller namespaces and the stub and caller Pods.
kubectl apply -k "$HERE/overlay" >/dev/null
kubectl apply -f "$HERE/stubs.yaml" >/dev/null
# ConfigMaps the pods mount (created after their namespaces exist).
kubectl create configmap stub-src -n ext-targets \
  --from-file=stub_server.py="$HERE/stub_server.py" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl create configmap probe-src -n caller \
  --from-file=router_egress_probe.py="$ROOT/probes/router_egress_probe.py" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

say "Wait for the router and the stubs"
kubectl -n "$NS" rollout status deploy/sandbox-router --timeout=180s
for p in ext-stub apisrv-stub hash-stub; do
  kubectl -n ext-targets wait --for=condition=Ready "pod/$p" --timeout=120s
done

ext_ip="$(kubectl -n ext-targets get pod ext-stub -o jsonpath='{.status.podIP}')"
apisrv_ip="$(kubectl -n ext-targets get pod apisrv-stub -o jsonpath='{.status.podIP}')"
hash_ip="$(kubectl -n ext-targets get pod hash-stub -o jsonpath='{.status.podIP}')"
note "ext-stub $ext_ip  apisrv-stub $apisrv_ip  hash-stub $hash_ip"

cat > "$work/targets.json" <<JSON
[
 {"name":"ext-stub:443","pod_ip":"$ext_ip","port":443,"sandbox_id":"probe","kind":"attempt",
  "expect":{"a":"reached","b":"blocked"},
  "note":"443 to a non-API, non-sandbox destination; the port-only rule reaches it by default, apiServerCIDRs scopes it out"},
 {"name":"ext-stub:6443","pod_ip":"$ext_ip","port":6443,"sandbox_id":"probe","kind":"attempt",
  "expect":{"a":"reached","b":"blocked"},
  "note":"6443 to a non-API, non-sandbox destination; same as 443"},
 {"name":"apisrv-stub:6443","pod_ip":"$apisrv_ip","port":6443,"sandbox_id":"probe","kind":"control",
  "expect":{"a":"reached","b":"reached"},
  "note":"stands in for the API server endpoint; reached by default and still reached once apiServerCIDRs scopes 6443 to it"},
 {"name":"ext-stub:8888","pod_ip":"$ext_ip","port":8888,"sandbox_id":"probe","kind":"control",
  "expect":{"a":"blocked","b":"blocked"},
  "note":"a non-443/6443 port to a non-sandbox pod; never reached, so the measurement is not open to everything"},
 {"name":"hash-stub:8888","pod_ip":"$hash_ip","port":8888,"sandbox_id":"probe","kind":"control",
  "expect":{"a":"reached","b":"reached"},
  "note":"the sandbox-egress path; any TCP port to a Pod carrying agents.x-k8s.io/sandbox-name-hash"}
]
JSON
kubectl create configmap egress-targets -n caller \
  --from-file=targets.json="$work/targets.json" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n caller wait --for=condition=Ready pod/caller --timeout=120s

run_probe() {
  # $1 = config a|b ; writes JSON lines to $work/$1.jsonl
  kubectl -n caller exec caller -- python3 /probe/router_egress_probe.py \
    --router "http://sandbox-router-svc.${NS}:8080" --config "$1" \
    --targets /targets/targets.json > "$work/$1.jsonl"
}

say "Measure config a (upstream default)"
run_probe a || true
cat "$work/a.jsonl"

say "Apply config b (apiServerCIDRs: scope 443 and 6443 to the API-server stand-in)"
egress_len="$(kubectl -n "$NS" get networkpolicy sandbox-router -o jsonpath='{.spec.egress}' | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
if [ "$egress_len" != "4" ]; then
  echo "FAIL: upstream NetworkPolicy egress has $egress_len rules, expected 4; its shape changed, not patching blindly" >&2
  exit 1
fi
kubectl -n "$NS" patch networkpolicy sandbox-router --type=json -p "$(cat <<PATCH
[{"op":"replace","path":"/spec/egress/3","value":{
  "to":[{"ipBlock":{"cidr":"${apisrv_ip}/32"}}],
  "ports":[{"protocol":"TCP","port":443},{"protocol":"TCP","port":6443}]}}]
PATCH
)" >/dev/null
note "replaced the port-only 443/6443 egress rule with an ipBlock to ${apisrv_ip}/32"
sleep 6  # let kindnet apply the policy change

say "Measure config b (apiServerCIDRs restriction)"
run_probe b || true
cat "$work/b.jsonl"

say "Verdict"
python3 - "$work/a.jsonl" "$work/b.jsonl" "$RESULTS" \
  "$UPSTREAM_TAG" "$UPSTREAM_COMMIT" "$ROUTER_IMAGE_DIGEST" <<'PY'
import json, sys
a_path, b_path, out, tag, commit, digest = sys.argv[1:7]
def load(p):
    rows = [json.loads(l) for l in open(p) if l.strip().startswith("{")]
    return [r for r in rows if "summary" not in r]
a, b = load(a_path), load(b_path)
by = {}
for r in a: by.setdefault(r["name"], {})["a"] = r
for r in b: by.setdefault(r["name"], {})["b"] = r

bad = []
for name, pair in by.items():
    for cfg in ("a", "b"):
        r = pair.get(cfg)
        if r is None:
            bad.append(f"{name} config {cfg}: no result"); continue
        if not r["ok"]:
            bad.append(f"{name} config {cfg}: expected {r['expected']}, got {r['got']} ({r['detail']})")

# Point 6 gate: config b must block the non-API destination on 443 and 6443.
inconclusive = []
for name in ("ext-stub:443", "ext-stub:6443"):
    r = by.get(name, {}).get("b")
    if r is None or r["got"] != "blocked":
        inconclusive.append(name)

verdict = "PASS"
if inconclusive:
    verdict = "INCONCLUSIVE"
elif bad:
    verdict = "FAIL"

result = {
    "measurement": "agent-sandbox sandbox-router egress, v1.0.10 defaults vs apiServerCIDRs",
    "fixture": True,
    "upstream": {"repo": "kubernetes-sigs/agent-sandbox", "tag": tag, "commit": commit,
                 "router_image_digest": digest},
    "verdict": verdict,
    "configs": {"a": a, "b": b},
    "mismatches": bad,
    "inconclusive": inconclusive,
}
json.dump(result, open(out, "w"), indent=2)

print(f"| target | config a | config b | ok |")
print(f"|---|---|---|---|")
for name, pair in by.items():
    ra, rb = pair.get("a", {}), pair.get("b", {})
    ok = all(pair.get(c, {}).get("ok") for c in ("a", "b"))
    print(f"| {name} | {ra.get('got','?')} | {rb.get('got','?')} | {'yes' if ok else 'NO'} |")
print()
if verdict == "INCONCLUSIVE":
    print("INCONCLUSIVE: config b did not block " + ", ".join(inconclusive) +
          ". The documented apiServerCIDRs restriction did not close the non-API"
          " destination here. Stop and report the facts; do not claim.")
    sys.exit(2)
if verdict == "FAIL":
    print("FAIL:")
    for m in bad:
        print("  " + m)
    sys.exit(1)
print(f"PASS: measured on agent-sandbox {tag} defaults; the restriction closes the non-API destination.")
PY
rc=$?

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  { echo "### agent-sandbox ${UPSTREAM_TAG} router egress (measured)"; echo;
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("Verdict:", d["verdict"])' "$RESULTS"; } \
    >> "$GITHUB_STEP_SUMMARY"
fi
echo "results: $RESULTS"
exit $rc
