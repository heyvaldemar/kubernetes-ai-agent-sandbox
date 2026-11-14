#!/bin/bash
# run-hog.sh <base|pr> [one|two]: install that runsc build into the kind node,
# run the issue's hog pod (128Mi limit, loop capped at 512 MiB, 1 s per 16 MiB),
# read the cgroups while it holds memory, and report how it ended.
# DRIVER=systemd (default) or cgroupfs selects the node's cgroup layout.
# "two" adds a second, idle container (32Mi request, 64Mi limit) to the pod.
set -uo pipefail
V=$1; SHAPE=${2:-one}; DRIVER=${DRIVER:-systemd}
W=${W:-$(cd "$(dirname "$0")" && pwd)}
N=gv16798-control-plane
K="kubectl --context kind-gv16798"

docker cp "$W/src-$V/out/runsc" "$N:/usr/local/bin/runsc"
docker cp "$W/bundle/rel/containerd-shim-runsc-v1" "$N:/usr/local/bin/containerd-shim-runsc-v1"
docker exec "$N" rm -rf /usr/local/bin/gvisor-bin
docker cp "$W/src-$V/out/gvisor-bin" "$N:/usr/local/bin/"
for c in gvisor-proc-umounter gvisor-sentry-prewarmer runsc-fd-parking; do docker cp "$W/csidecars/$c" "$N:/usr/local/bin/gvisor-bin/"; done
if [ "$DRIVER" = systemd ]; then SC='  systemd-cgroup = \"true\"\n'; else SC=''; fi
docker exec "$N" sh -c "printf \"[runsc_config]\n$SC  debug = \\\"true\\\"\n  debug-log = \\\"/tmp/runsc/\\\"\n\" > /etc/containerd/runsc.toml; mkdir -p /tmp/runsc; rm -rf /tmp/runsc/*; chmod 755 /usr/local/bin/runsc /usr/local/bin/containerd-shim-runsc-v1 /usr/local/bin/gvisor-bin/*; systemctl restart containerd"
sleep 5
echo "runsc: $(docker exec "$N" runsc --version | head -1); driver=$DRIVER; swapBehavior=$(docker exec "$N" sh -c 'grep -A1 "^memorySwap" /var/lib/kubelet/config.yaml | tr -d "\n "')"

IDLE=""
if [ "$SHAPE" = two ]; then IDLE='
    - name: idle
      image: python:3.13-alpine
      command: ["sleep", "600"]
      resources:
        requests: {memory: 32Mi}
        limits: {memory: 64Mi}'; fi
$K delete pod hog --ignore-not-found --wait=true >/dev/null 2>&1
$K apply -f - >/dev/null <<YAML
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: runsc
overhead:
  podFixed: {cpu: 10m, memory: 32Mi}
---
apiVersion: v1
kind: Pod
metadata:
  name: hog
spec:
  runtimeClassName: gvisor
  restartPolicy: Never
  containers:
    - name: hog
      image: python:3.13-alpine
      command: ["python3", "-c", "import time\nchunks=[]\nfor i in range(${CHUNKS:-32}):\n  chunks.append(b'\\\\x01'*(16*1024*1024)); print(len(chunks)*16, flush=True); time.sleep(1.0)"]
      resources:
        requests: {memory: 64Mi}
        limits: {memory: 128Mi}$IDLE
YAML
uid=""; for _ in $(seq 1 90); do uid=$($K get pod hog -o jsonpath='{.metadata.uid}' 2>/dev/null); ph=$($K get pod hog -o jsonpath='{.status.phase}' 2>/dev/null); [ "$ph" = Running ] && break; sleep 2; done
sleep 2
u=${uid//-/_}
if [ "$DRIVER" = systemd ]; then FIND="-name \"*pod${u}.slice\""; SUB='"$pod"/*.scope'; else FIND="-name \"pod${uid}\""; SUB='"$pod"/*/'; fi
readcg() { docker exec "$N" sh -c '
  pod=$(find /sys/fs/cgroup -type d '"$FIND"' | head -1)
  r() { printf "%-34s memory.max=%-10s memory.swap.max=%-8s swap.current=%-10s procs=%s\n" "$2" "$(cat $1/memory.max)" "$(cat $1/memory.swap.max)" "$(cat $1/memory.swap.current)" "$(wc -l < $1/cgroup.procs)"; }
  r "$pod" "pod slice"
  for d in '"$SUB"'; do d=${d%/}; r "$d" "  $(basename "$d" | cut -c1-30)"; done
  if [ "'"$DRIVER"'" = systemd ]; then for d in "$pod"/*.scope; do printf "  %-32s systemd %s\n" "$(basename "$d" | cut -c1-30)" "$(systemctl show -p MemorySwapMax "$(basename "$d")")"; done; fi'; }
readcg
for _ in $(seq 1 90); do st=$($K get pod hog -o jsonpath='{.status.containerStatuses[?(@.name=="hog")].state.terminated.reason}'); [ -n "$st" ] && break; sleep 2; done
echo "phase=$($K get pod hog -o jsonpath='{.status.phase}') hog=$st last MiB printed=$($K logs hog -c hog 2>/dev/null | tail -1)"
[ "$SHAPE" = two ] && echo "idle: $($K get pod hog -o jsonpath='{.status.containerStatuses[?(@.name=="idle")].state}')"
# AFTER=1: remove the exited hog container (runsc delete -> Destroy) while the
# sandbox stays up, then read the cgroups again.
if [ "${AFTER:-0}" = 1 ]; then
  cid=$(docker exec "$N" crictl ps -a --label io.kubernetes.pod.name=hog --label io.kubernetes.container.name=hog -q | head -1)
  docker exec "$N" crictl rm "$cid" >/dev/null && sleep 3 && echo "after crictl rm of the exited hog container:" && readcg
fi
$K delete pod hog --wait=false >/dev/null 2>&1
exit 0
