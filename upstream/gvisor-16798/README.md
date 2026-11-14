# Re-testing google/gvisor#16798 on the #15756 reproducer

[google/gvisor#15756](https://github.com/google/gvisor/issues/15756) came out of this repository's e2e run (see
[the threat model](../../docs/threat-model.md)): on a node with swap, a pod's swap limit never reaches the cgroup
runsc runs in, so a gVisor pod outgrows its memory limit. [google/gvisor#16798](https://github.com/google/gvisor/pull/16798)
is the maintainers' fix. These scripts build `runsc` twice from gVisor's `go` branch, once as it is and once with the
PR's diff, and run the issue's `hog` pod against both builds on a one-node kind cluster with swap. They cover the
systemd and cgroupfs cgroup drivers and the kubelet's `NoSwap` and `LimitedSwap`.

Results posted on the PR: [2026-11-02, first version](https://github.com/google/gvisor/pull/16798#issuecomment-6580957555),
[2026-11-11, head c2c3f328](https://github.com/google/gvisor/pull/16798#issuecomment-6801968334).

## Host

An arm64 Linux host with Docker, cgroup v2 and swap on. The runs above used Docker Desktop on Apple silicon:
kernel 7.0.12, 1 GiB of swap, kind v0.33.0, `kindest/node:v1.37.0`. Tools: docker, kind, kubectl, gh, git, curl.
The build targets linux/arm64. `containerd-shim-runsc-v1` comes from the 20261012 aarch64 release, whose SHA-512
is pinned in [gvisor.lock](../../gvisor.lock); `build.sh` prints the first 16 characters of it to compare.

## Steps

1. `./fetch.sh` (PR number, default 16798): the `go` branch, the PR's current diff (`pr.diff`, head in `pr-head.txt`),
   `src-base` and `src-pr`, and master's seccomp precompile generator in `gen/`.
2. `./build.sh`: regenerates the arm64 systrap filter in both trees (the `go` branch's does not match arm64: the
   sentry panics with "cannot render precompiled seccomp program systrap_sysmsg_thread"), builds `runsc`,
   `gvisor_sentry`, `checkpointgofer` and `runsc-metric-server` for both in `golang:1.27` (cache volumes
   `gv7-gocache`, `gv7-buildcache`), the three C sidecars in `gcc:15`, and unpacks the release bundle.
3. systemd node: `kind create cluster --config kind.yaml`, then `./series.sh systemd`.
4. cgroupfs node: `kind delete cluster --name gv16798`, `kind create cluster --config kind-fs.yaml`,
   then `./series.sh cgroupfs`.
5. Clean up: `kind delete cluster --name gv16798`, `docker volume rm gv7-gocache gv7-buildcache`.

`series.sh` runs the rows of the posted table in order and switches the kubelet from `NoSwap` to `LimitedSwap`
halfway. Each `run-hog.sh <base|pr> [one|two]` installs that build into the node, starts the pod (`two` adds an idle
container with a 32Mi request and a 64Mi limit), reads `memory.max`, `memory.swap.max`, `memory.swap.current` and
the process count of the pod's cgroups while `hog` holds memory (with the systemd driver, also each scope's
`MemorySwapMax`), and prints how `hog` ended and the last MiB it printed.

- `AFTER=1` removes the exited `hog` container with `crictl rm` (runsc delete, then Destroy) and reads the cgroups
  again.
- `CHUNKS=n` caps the loop at n × 16 MiB. `CHUNKS=4` lets `hog` exit on its own while `idle` keeps running, the
  only shape in which the `AFTER` read has a sandbox left to read.
- With the PR, an OOM kill in a `two` pod takes the whole sandbox, `idle` included: under gVisor every process of
  the pod lives in one sandbox.
