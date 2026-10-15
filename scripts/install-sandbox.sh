#!/usr/bin/env bash
# install-sandbox.sh - apply the sandbox to the cluster in the current
# kubeconfig (kind/cluster.yaml with gVisor installed), and wait for it.
#
# Two things cannot live in manifests/ and are made here:
#   - the records key, generated on this machine and handed to kubectl on
#     stdin, so it exists only as a Secret in corp (the records service) and
#     mcp (the MCP server). No agent namespace ever holds it.
#   - the MCP server's egress rule to the API server, for TokenReview. A
#     NetworkPolicy names addresses, and the API server's is the cluster's.
set -euo pipefail
cd "$(dirname "$0")/.."

kubectl apply -k manifests/ >/dev/null
echo "applied manifests/"

if ! kubectl -n corp get secret records-api-key >/dev/null 2>&1 ||
   ! kubectl -n mcp get secret records-api-key >/dev/null 2>&1; then
  python3 - <<'PY' | kubectl apply -f - >/dev/null
import json, secrets
key = secrets.token_urlsafe(32)
print(json.dumps({"apiVersion": "v1", "kind": "List", "items": [
    {"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
     "metadata": {"name": "records-api-key", "namespace": ns}, "stringData": {"key": key}}
    for ns in ("corp", "mcp")]}))
PY
  echo "records key generated, in corp and mcp only"
fi

# The API server as the MCP server's pod sees it: the Service address, and
# the endpoint it is translated to. Network plugins differ in which of the
# two a policy is matched against, so the rule names both and nothing else.
svc_ip="$(kubectl -n default get service kubernetes -o jsonpath='{.spec.clusterIP}')"
svc_port="$(kubectl -n default get service kubernetes -o jsonpath='{.spec.ports[0].port}')"
ep_ip="$(kubectl -n default get endpointslices -l kubernetes.io/service-name=kubernetes -o jsonpath='{.items[0].endpoints[0].addresses[0]}')"
ep_port="$(kubectl -n default get endpointslices -l kubernetes.io/service-name=kubernetes -o jsonpath='{.items[0].ports[0].port}')"
python3 - "$svc_ip" "$svc_port" "$ep_ip" "$ep_port" <<'PY' | kubectl apply -f - >/dev/null
import json, sys
svc_ip, svc_port, ep_ip, ep_port = sys.argv[1:]
print(json.dumps({
    "apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy",
    "metadata": {"name": "mcp-server-to-api-server", "namespace": "mcp"},
    "spec": {"podSelector": {"matchLabels": {"app.kubernetes.io/name": "mcp-server"}},
             "policyTypes": ["Egress"],
             "egress": [{"to": [{"ipBlock": {"cidr": svc_ip + "/32"}}], "ports": [{"protocol": "TCP", "port": int(svc_port)}]},
                        {"to": [{"ipBlock": {"cidr": ep_ip + "/32"}}], "ports": [{"protocol": "TCP", "port": int(ep_port)}]}]}}))
PY
echo "the MCP server may reach the API server at $svc_ip:$svc_port and $ep_ip:$ep_port, for TokenReview"

for d in tools/tool-gateway corp/internal-records corp/records-api mcp/mcp-server; do
  kubectl -n "${d%/*}" rollout status "deployment/${d#*/}" --timeout=180s >/dev/null
  echo "ready: $d"
done
