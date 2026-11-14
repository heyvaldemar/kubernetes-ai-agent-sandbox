#!/bin/bash
# series.sh <systemd|cgroupfs>: the run order used for the comment's table.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
D=$1; N=gv16798-control-plane; K="kubectl --context kind-gv16798"
limited() {
  docker exec "$N" sh -c "sed -i 's/^memorySwap: {}\$/memorySwap:\n  swapBehavior: LimitedSwap/' /var/lib/kubelet/config.yaml && systemctl restart kubelet"
  sleep 10; $K wait node --all --for=condition=Ready --timeout=120s >/dev/null; sleep 5
}
run() { echo "===== $D $*"; DRIVER=$D AFTER=1 ./run-hog.sh "$@"; }
if [ "$D" = systemd ]; then
  run base; run pr
  limited
  run pr; run base; run pr two; run base two
else
  run pr; run base
  limited
  run pr two; run base two; CHUNKS=4 run pr two
fi
echo SERIES-DONE
