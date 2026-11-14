#!/bin/bash
# fetch.sh [pr-number]: the sources for one re-test. Clones (or updates) the
# `go` branch of gVisor, the tree that builds with plain `go build`, takes the
# PR's current diff, and makes two copies of the tree: src-base as it is and
# src-pr with the diff applied. The `go` branch carries no _test.go files and
# no BUILD files, so those parts of the diff are left out. Also fetches
# master's seccomp precompile generator, which build.sh uses to regenerate
# the arm64 systrap filter. Needs git, gh and curl.
set -euo pipefail
W=${W:-$(cd "$(dirname "$0")" && pwd)}
cd "$W"
PR=${1:-16798}

if [ -d gvisor-go ]; then
  git -C gvisor-go fetch -q --depth 1 origin go
  git -C gvisor-go checkout -q --detach -f FETCH_HEAD
else
  git clone -q --depth 1 --branch go https://github.com/google/gvisor.git gvisor-go
fi

gh pr view "$PR" -R google/gvisor --json headRefOid --jq .headRefOid > pr-head.txt
gh pr diff "$PR" -R google/gvisor > pr.diff

rm -rf src-base src-pr
cp -R gvisor-go src-base
cp -R gvisor-go src-pr
git -C src-pr apply --exclude='test/root/*' --exclude='*/BUILD' --exclude='*_test.go' ../pr.diff

mkdir -p gen
for f in precompile_gen.go precompiled_lib.tmpl.go; do
  curl -fsSL --retry 3 -o "gen/$f" "https://raw.githubusercontent.com/google/gvisor/master/pkg/seccomp/precompiledseccomp/$f"
done

echo "go branch $(git -C gvisor-go rev-parse --short HEAD): $(git -C gvisor-go log -1 --format=%s)"
echo "PR #$PR head $(cut -c1-8 pr-head.txt); diff: $(git -C src-pr diff --shortstat)"
