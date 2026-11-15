# Measuring sandboxd file-op defaults across two tags

This is a measurement of an upstream project, [kubernetes-sigs/agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox), not a check of this repository. It is not a row of the README's claims table. See [ADR 8](../../docs/decisions/0008-measured-sandboxd-fileops.md).

`sandboxd` is agent-sandbox's per-sandbox runtime daemon (KEP-539.2): it serves a REST `FilesystemService` on `:8080` and a gRPC `ProcessService` on `:9090` from inside a sandbox Pod. It takes a `--root-dir` (default `/workspace`) that file operations are confined to, and needs no controller or Kubernetes to run. `run.sh` builds it from source at two tags, runs each standalone under `docker`, and sends a few file operations to the REST API, recording what the daemon answers.

## What is measured

| fix | probe | baseline (v1.0.10) | candidate (v1.0.11) |
|-----|-------|--------------------|---------------------|
| [#2222](https://github.com/kubernetes-sigs/agent-sandbox/pull/2222) | `GET` a named pipe | hangs open (no answer) | `400 INVALID_ARGUMENT` |
| [#2222](https://github.com/kubernetes-sigs/agent-sandbox/pull/2222) | `GET` a device node | opens it, `200` | `400 INVALID_ARGUMENT` |
| [#2218](https://github.com/kubernetes-sigs/agent-sandbox/pull/2218) | `DELETE` an in-root symlink to a file | follows the link, deletes the target | removes the link, target survives |
| [#2218](https://github.com/kubernetes-sigs/agent-sandbox/pull/2218) | `DELETE ?recursive=true` an in-root symlink to a dir | follows the link, clears the directory | removes the link, directory survives |

Two honest limits on the "before":

- The device node measured is `/dev/zero` (major 1, minor 5). On the baseline the daemon opens it and answers `200` with an empty body (the file's `Stat` size is 0); it is not a hang. The hang is the named pipe. The candidate rejects both.
- A symlink whose target is **outside** the root is already refused on the baseline by a separate path-traversal guard (`403 PERMISSION_DENIED`), so its outside target is never touched on either tag. The data-loss difference #2218 fixes is for symlinks whose target is **inside** the root, which is what the two symlink probes use. The escaping link is kept as a control.

## Controls and the plant

Every dimension is paired with a control, so a result is a property of the input and not a broken endpoint: `GET` of a regular file returns `200`, `DELETE` of a regular file returns `204`, on both tags. The verdict is `CONFIRMED` only when both controls pass and every dimension moves from the baseline behaviour to the fix.

A check is trusted only after it has failed (AGENTS.md). `verdict.py plant` feeds the gate a candidate that is still vulnerable on one dimension and fails the run unless the gate rejects it; `run.sh` runs it before it measures anything.

## Running

```bash
./tests/upstream-sandboxd/run.sh                 # defaults, writes $SBXD_RESULTS
BASELINE_TAG=v1.0.10 CANDIDATE_TAG=v1.0.11 ./tests/upstream-sandboxd/run.sh
```

Needs `docker` (privileged, to `mknod` a device fixture) and `python3`. The workflow [`upstream-sandboxd.yml`](../../.github/workflows/upstream-sandboxd.yml) runs it on demand and when these files change, and uploads the result as `upstream-sandboxd-results`.

## Files

- `run.sh` — builds each tag from source, lays the fixtures, runs the daemon, probes it, writes the verdict.
- `probe.py` — the file operations, run inside a client container against `http://sbxd:8080`.
- `verdict.py` — compares the two tags into a before/after table and a verdict; `plant` self-tests the gate.
- `UPSTREAM.txt` — the pinned tags, their commits, and the release-age rule.
