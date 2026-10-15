#!/usr/bin/env bash
# validate.sh [check...] - the static checks, without a cluster:
#
#   kubeconform   every manifest, the agent's Job and every plant are valid
#                 Kubernetes 1.37 objects
#   images        every image outside the plants is referenced by digest
#   agent         the demo agent compiles
#   mcp           the MCP server and the records service compile; every
#                 grant in policy.json names a tool or resource the server
#                 has, and none is a destructive tool; the audience the
#                 server checks is the one admission and the agents' Jobs
#                 use; and the server's protocol and grant tests pass
#                 (tests/mcp/test_server.py)
#
# With no arguments every check runs. tests/static/plants.tsv shows each
# check the violation it exists for (tests/static/plant_violations.py).
# The check_* functions are called by name from the loop at the bottom.
# shellcheck disable=SC2329
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

KUBE_VERSION=1.37.0
# yannh/kubernetes-json-schema at a fixed commit. K8S_SCHEMAS may point at a
# local checkout of the same commit instead. (The default is assigned on its
# own line: the template's braces would close a ${VAR:-default} early.)
default_schemas='https://raw.githubusercontent.com/yannh/kubernetes-json-schema/817113f21a2643311cbc3e992bb44ffe1c416c54/{{.NormalizedKubernetesVersion}}-standalone{{.StrictSuffix}}/{{.ResourceKind}}{{.KindSuffix}}.json'
K8S_SCHEMAS="${K8S_SCHEMAS:-$default_schemas}"

check_kubeconform() {
  mkdir -p .cache/kubeconform out
  kubectl kustomize manifests >out/manifests.yaml || return 1
  kubeconform -strict -summary -output text -kubernetes-version "$KUBE_VERSION" \
    -cache .cache/kubeconform -schema-location "$K8S_SCHEMAS" \
    out/manifests.yaml manifests/agent/job.yaml tests/e2e/plants
}

check_images() {
  # The plants are excluded on purpose: one of them is a tag-only image.
  local bad
  bad="$(grep -rnE '(image:|"image":|^[A-Z]+=)[[:space:]]*"?[a-z0-9.-]+\.[a-z]+/[^@[:space:]"]+:[^@[:space:]"]+("|$|[[:space:]])' \
    manifests tests/e2e/run.sh .github/workflows 2>/dev/null | grep -v '@sha256:' || true)"
  if [ -n "$bad" ]; then echo "images without a digest:"; echo "$bad"; return 1; fi
  echo "every image is referenced by digest"
}

check_agent() { python3 -m py_compile manifests/agent/agent.py && echo "agent.py compiles"; }

check_mcp() {
  python3 - <<'PY' || return 1
import importlib.util, json, py_compile, re, sys
for f in ("manifests/mcp/server.py", "manifests/records/records_api.py"):
    py_compile.compile(f, doraise=True)
spec = importlib.util.spec_from_file_location("server", "manifests/mcp/server.py")
srv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(srv)
with open("manifests/mcp/policy.json") as f:
    policy = json.load(f)
bad = []
for who, grant in sorted(policy["identities"].items()):
    for t in grant["tools"]:
        if t not in srv.TOOLS:
            bad.append("%s is granted %s, a tool the server does not have" % (who, t))
        elif srv.TOOLS[t]["definition"]["annotations"].get("destructiveHint", True):
            bad.append("%s is granted %s, a destructive tool" % (who, t))
    for r in grant["resources"]:
        if r not in srv.RESOURCES:
            bad.append("%s is granted %s, a resource the server does not have" % (who, r))
aud = policy["audience"]
if "audience == '%s'" % aud not in open("manifests/admission.yaml").read():
    bad.append("manifests/admission.yaml requires a different audience than the MCP server checks (%s)" % aud)
job_auds = re.findall(r"audience:\s*(\S+)", open("manifests/agent/job.yaml").read())
if not job_auds or any(a != aud for a in job_auds):
    bad.append("an agent Job's token is not for the MCP server's audience (%s): %s" % (aud, job_auds))
print("\n".join(bad) or "every grant names a tool or resource the server has; none is destructive; one audience")
sys.exit(1 if bad else 0)
PY
  python3 tests/mcp/test_server.py 2>&1 | tail -3
  return "${PIPESTATUS[0]}"
}

checks=("$@")
[ ${#checks[@]} -eq 0 ] && checks=(kubeconform images agent mcp)
failed=0
for c in "${checks[@]}"; do
  if "check_$c"; then echo "-- $c: ok"; else echo "-- $c: FAILED"; failed=1; fi
done
exit "$failed"
