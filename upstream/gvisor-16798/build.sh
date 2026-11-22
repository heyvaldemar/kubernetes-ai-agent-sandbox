#!/bin/bash
# build.sh: regenerate the arm64 systrap filter, build runsc + Go sidecars for
# base and pr, build the C sidecars, fetch the pinned release bundle.
set -euo pipefail
W=${W:-$(cd "$(dirname "$0")" && pwd)}
cd "$W"
V=${V:-$(git -C "$W/gvisor-go" rev-parse --short HEAD)}
for v in base pr; do
  d=$W/src-$v/tools/gen_stubfilter; mkdir -p "$d"
  cp "$W/gen/precompiled_lib.tmpl.go" "$d/precompiled_lib.tmpl"
  sed -e 's#^\t"gvisor.dev/gvisor/pkg/seccomp/precompiledseccomp/example" // REPLACED_IMPORT.*#\trules "gvisor.dev/gvisor/pkg/sentry/platform/systrap/stubfilter"#' \
      -e 's#^var loadProgramsFn = example.PrecompiledPrograms.*#var loadProgramsFn = rules.PrecompiledPrograms#' \
      -e 's#^//go:embed precompiled_lib.tmpl.go#//go:embed precompiled_lib.tmpl#' "$W/gen/precompile_gen.go" > "$d/main.go"
done
cp "$W/src-base/pkg/sentry/platform/systrap/stubfilter_precompiled.go" "$W/stubfilter_precompiled.go.orig"
for v in base pr; do
  docker run --rm -v gv7-gocache:/go -v gv7-buildcache:/root/.cache -v "$W/src-$v:/src" -w /src -e CGO_ENABLED=0 golang:1.27 \
    sh -c 'go run ./tools/gen_stubfilter --package=systrap --out=/tmp/gen.go && cp /tmp/gen.go /src/pkg/sentry/platform/systrap/stubfilter_precompiled.go'
done
cmp -s "$W/stubfilter_precompiled.go.orig" "$W/src-base/pkg/sentry/platform/systrap/stubfilter_precompiled.go" && echo "filter: SAME as go branch" || echo "filter: regenerated (differs from the go branch's)"
cmp -s "$W/src-base/pkg/sentry/platform/systrap/stubfilter_precompiled.go" "$W/src-pr/pkg/sentry/platform/systrap/stubfilter_precompiled.go" && echo "filter: base and pr identical"
for v in base pr; do
  docker run --rm -v gv7-gocache:/go -v gv7-buildcache:/root/.cache -v "$W/src-$v:/src" -w /src -e CGO_ENABLED=0 -e GOOS=linux -e GOARCH=arm64 golang:1.27 sh -c "set -e; L='-X gvisor.dev/gvisor/runsc/version.version=go-$V-$v'; mkdir -p out/gvisor-bin; go build -ldflags \"\$L\" -o out/runsc ./runsc; go build -ldflags \"\$L\" -o out/gvisor-bin/gvisor_sentry ./runsc/cmd/sentry; go build -ldflags \"\$L\" -o out/gvisor-bin/checkpointgofer ./runsc/checkpointgofer; go build -ldflags \"\$L\" -o out/gvisor-bin/runsc-metric-server ./runsc/cmd/metricserver"
  ls -la "$W/src-$v/out" "$W/src-$v/out/gvisor-bin" | awk 'NF>5{print $5, $9}'
done
mkdir -p "$W/csidecars"
docker run --rm -v "$W/src-base/runsc:/src:ro" -v "$W/csidecars:/out" gcc:15 sh -c 'set -e; F="-Os -ffreestanding -fno-sanitize=all -fno-stack-protector -fno-asynchronous-unwind-tables -fno-unwind-tables -static -nostdlib -nostartfiles -no-pie -Wl,--build-id=none -Wl,--gc-sections -Wl,-s -Wl,-n"; gcc $F -o /out/gvisor-proc-umounter /src/procumounter/procumounter.c; gcc $F -o /out/gvisor-sentry-prewarmer /src/prewarmer/prewarmer.c; gcc $F -o /out/runsc-fd-parking /src/fdparking/fdparking.c'
ls -la "$W/csidecars" | awk 'NF>5{print $5, $9}'
mkdir -p "$W/bundle/rel" && cd "$W/bundle"
# The SHA-512 published with the 20261012 aarch64 bundle (the value
# gvisor.lock held when these re-tests began). Only the containerd shim is
# taken from it; runsc and its sidecars are the builds above.
SUM=2fe7425abd16ad6ca649ab9bc3d7e8e76756834d86ffcc08dbe97c82c3b7262a7d6401f23632f2b296649cc1408b560416b2ab65a4043aa123fc7b90f3a1b2e2
[ -f gvisor-20261012-aarch64.tar.bz2 ] || curl -fsSL --retry 3 -o gvisor-20261012-aarch64.tar.bz2 https://storage.googleapis.com/gvisor/releases/release/20261012/aarch64/gvisor.tar.bz2
got=$( (sha512sum gvisor-20261012-aarch64.tar.bz2 2>/dev/null || shasum -a 512 gvisor-20261012-aarch64.tar.bz2) | cut -d' ' -f1)
[ "$got" = "$SUM" ] || { echo "bundle sha512 $got, pinned $SUM. Not using it." >&2; exit 1; }
echo "bundle sha512 matches the pin"
tar -xjf gvisor-20261012-aarch64.tar.bz2 -C rel && ls rel
echo BUILD-DONE
