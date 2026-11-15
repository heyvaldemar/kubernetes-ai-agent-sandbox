#!/usr/bin/env bash
# tests/upstream-sandboxd/run.sh - measure how a kubernetes-sigs/agent-sandbox
# sandboxd daemon answers a few file operations, on two upstream tags, and
# print a before/after table.
#
# This is a measurement of an upstream project, not a check of this repository
# (AGENTS.md: a measurement is never a row of the README table). No per-tag
# sandboxd image is published, so each tag is built from its own source with
# the project's own packages/sandboxd/Dockerfile, run standalone (no
# controller, no Kubernetes), and probed over its REST FilesystemService. Every
# path is a fixture in the daemon's own --root-dir; nothing reaches the
# internet or a cloud. See docs/decisions/0008-measured-sandboxd-fileops.md.
#
# The four dimensions, each an upstream fix, baseline (a) vs candidate (b):
#
#   fifo          #2222  GET of a named pipe:  a hangs open        b 400
#   device        #2222  GET of a device node: a opens, 200        b 400
#   symlink_file  #2218  DELETE in-root link:  a deletes target    b removes link
#   symlink_dir   #2218  DELETE in-root link:  a clears directory  b removes link
#
# Each dimension's control is a regular file (GET 200, DELETE 204) and an
# escaping symlink (refused 403 on a, link removed on b, outside target intact
# on both), so a result is a property of the input and not a broken endpoint.
# The verdict is CONFIRMED only when both controls pass and every dimension
# moves from the baseline behaviour to the fix; verdict.py's `plant` self-test
# fails the run unless the gate rejects a still-vulnerable candidate.
#
# Needs docker (privileged, to mknod a device fixture) and python3. Writes the
# result JSON to $SBXD_RESULTS.
# shellcheck disable=SC2015
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
UPSTREAM_REPO="https://github.com/kubernetes-sigs/agent-sandbox"
BASELINE_TAG="${BASELINE_TAG:-v1.0.10}"
CANDIDATE_TAG="${CANDIDATE_TAG:-v1.0.11}"
# These tags reach `git clone --branch` and a docker image name. They come from
# a workflow_dispatch input (write access only), but accept nothing but a
# vX.Y.Z release tag so no value can turn into a clone option or a shell token.
for t in "$BASELINE_TAG" "$CANDIDATE_TAG"; do
  case "$t" in
    v[0-9]*.[0-9]*.[0-9]*) : ;;
    *) echo "refusing tag $t: expected a vMAJOR.MINOR.PATCH release tag"; exit 1 ;;
  esac
done
TIMEOUT="${PROBE_TIMEOUT:-6}"
PYIMG="python:3.13-alpine@sha256:2d9aefe2fef018a7eb2c13064c89c71929800fd2e5dccdbf52ea5da5bb8d929a"
RESULTS="${SBXD_RESULTS:-$(mktemp)}"
BUILD="$(mktemp -d)"

say()  { printf '\n== %s\n' "$*"; }
note() { printf '  ..    %s\n' "$*"; }

# shellcheck disable=SC2329  # called by the EXIT trap
cleanup() { rm -rf "$BUILD"; }
trap cleanup EXIT

# build_image TAG: ensure sandboxd-under-test:TAG exists, built from TAG's
# source, and echo the resolved upstream commit on stdout.
build_image() {
  local tag="$1" img="sandboxd-under-test:$1" src="$BUILD/src-$1" commit
  if [ -d "$src/.git" ]; then :; else
    git clone --quiet --depth 1 --branch "$tag" "$UPSTREAM_REPO" "$src" >&2
  fi
  commit="$(git -C "$src" rev-parse HEAD)"
  if ! docker image inspect "$img" >/dev/null 2>&1; then
    note "building $img from $tag ($commit)" >&2
    docker build -q -f "$src/packages/sandboxd/Dockerfile" \
      --build-arg GIT_VERSION="$tag" --build-arg GIT_SHA="$commit" \
      -t "$img" "$src" >&2
  fi
  echo "$commit"
}

# run_version TAG COMMIT OUTFILE: lay the fixtures, run sandboxd at TAG, probe
# it, and write the per-version JSON (commit, probes, surviving fixtures).
run_version() {
  local tag="$1" commit="$2" out="$3" img="sandboxd-under-test:$1"
  local sfx net ws ov sbx
  sfx="$(date +%s)-$$-$RANDOM"; net="sbxd-net-$sfx"; ws="sbxd-ws-$sfx"
  ov="sbxd-out-$sfx"; sbx="sbxd-$sfx"
  # Tear down this version's containers, volumes and network. Called by hand
  # at the end of run_version and on each early return, not from a trap, so a
  # failure in one version still cleans up before the next.
  _vcleanup() { docker rm -f "$sbx" >/dev/null 2>&1 || true
    docker volume rm "$ws" "$ov" >/dev/null 2>&1 || true
    docker network rm "$net" >/dev/null 2>&1 || true; }

  docker network create "$net" >/dev/null
  docker volume create "$ws" >/dev/null; docker volume create "$ov" >/dev/null

  # Fixtures. Privileged for mknod; chown both trees to the daemon's uid so a
  # file permission never stands in for the behaviour under test.
  docker run --rm --privileged -v "$ws":/workspace -v "$ov":/outside "$PYIMG" sh -c '
    set -e
    printf REGULAR  > /workspace/regular.txt
    printf KEEPFILE > /workspace/realfile
    mkdir -p /workspace/realdir; printf KEEPDIR > /workspace/realdir/keep
    ln -s realfile /workspace/link-to-file
    ln -s realdir  /workspace/link-to-dir
    printf OUTSIDE  > /outside/sentinel
    ln -s /outside/sentinel /workspace/escape-link
    mkfifo /workspace/pipe
    mknod  /workspace/zero c 1 5
    chmod 666 /workspace/zero /workspace/pipe
    chown -R 1000:1000 /workspace /outside
  ' >/dev/null

  docker run -d --name "$sbx" --network "$net" --network-alias sbxd \
    -v "$ws":/workspace -v "$ov":/outside "$img" \
    --listen-host=0.0.0.0 --rest-port=8080 --root-dir=/workspace >/dev/null

  if ! docker run --rm --network "$net" "$PYIMG" sh -c \
    'for i in $(seq 1 40); do wget -q -O- http://sbxd:8080/v1/health >/dev/null 2>&1 && exit 0; sleep 0.5; done; exit 1'; then
    note "sandboxd $tag did not become healthy"
    docker logs "$sbx" 2>&1 | tail -5
    _vcleanup; return 1
  fi

  local probes survive
  probes="$(docker run --rm --network "$net" -v "$HERE/probe.py":/probe.py:ro "$PYIMG" python /probe.py "$TIMEOUT")"
  survive="$(docker run --rm -v "$ws":/workspace:ro -v "$ov":/outside:ro "$PYIMG" sh -c '
    rf=no; rd=no; sf=no; lf=gone; ld=gone
    [ -f /workspace/realfile ] && rf=yes
    [ -f /workspace/realdir/keep ] && rd=yes
    [ -f /outside/sentinel ] && sf=yes
    [ -L /workspace/link-to-file ] && lf=present
    [ -L /workspace/link-to-dir ] && ld=present
    printf "{\"realfile\":\"%s\",\"realdir_keep\":\"%s\",\"outside_sentinel\":\"%s\",\"link_file\":\"%s\",\"link_dir\":\"%s\"}" "$rf" "$rd" "$sf" "$lf" "$ld"
  ')"
  _vcleanup

  TAG="$tag" COMMIT="$commit" PROBES="$probes" SURVIVE="$survive" python3 - "$out" <<'PY'
import json, os, sys
json.dump({
    "version": os.environ["TAG"],
    "commit": os.environ["COMMIT"],
    "probes": json.loads(os.environ["PROBES"]),
    "after": json.loads(os.environ["SURVIVE"]),
}, open(sys.argv[1], "w"), indent=2)
PY
}

command -v docker >/dev/null || { echo "docker is required"; exit 1; }

say "Self-test the gate (plant): a still-vulnerable candidate must be rejected"
if ! python3 "$HERE/verdict.py" plant; then
  echo "gate self-test failed; refusing to report a measurement"; exit 1
fi

say "Build sandboxd from source: baseline $BASELINE_TAG, candidate $CANDIDATE_TAG"
base_commit="$(build_image "$BASELINE_TAG")"
cand_commit="$(build_image "$CANDIDATE_TAG")"
note "baseline  $BASELINE_TAG  $base_commit"
note "candidate $CANDIDATE_TAG  $cand_commit"

say "Probe $BASELINE_TAG (baseline)"
run_version "$BASELINE_TAG" "$base_commit" "$BUILD/baseline.json" || exit 1
say "Probe $CANDIDATE_TAG (candidate)"
run_version "$CANDIDATE_TAG" "$cand_commit" "$BUILD/candidate.json" || exit 1

say "Verdict"
python3 "$HERE/verdict.py" "$BUILD/baseline.json" "$BUILD/candidate.json" \
  "$BASELINE_TAG" "$CANDIDATE_TAG" "$RESULTS"
rc=$?
note "result written to $RESULTS"
exit $rc
