# 8. Measuring sandboxd file-operation defaults across two upstream tags

- Status: accepted
- Date: 2026-11-15

## Context

[kubernetes-sigs/agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox) ships `sandboxd`, the per-sandbox runtime daemon defined by KEP-539.2. It serves a REST `FilesystemService` on `:8080` and a gRPC `ProcessService` on `:9090` from inside a sandbox Pod, confined to a `--root-dir` (default `/workspace`). [ADR 7](0007-measured-upstream-egress.md) measures the upstream `sandbox-router`'s default egress; `sandboxd` is a different component, and its file-transfer and delete handlers are a surface worth the same treatment.

Release [v1.0.11](https://github.com/kubernetes-sigs/agent-sandbox/releases/tag/v1.0.11) (2026-11-12) hardened three things in that daemon:

- **#2218** `DELETE /v1/files/{path}` now removes the symlink in the last path component rather than following it. On v1.0.10 a `DELETE` of an in-root symlink follows it: the pointed-to file is deleted, and `DELETE link?recursive=true` on a symlink to a directory clears that directory.
- **#2222** the file-transfer handlers (`GET`, `HEAD`, append) open with `O_NONBLOCK` and reject named pipes and device files with `INVALID_ARGUMENT`. On v1.0.10 a `GET` of a named pipe blocks the handler open, waiting for a peer that never comes.
- **#2164** `sandboxd` accepts a bearer token in the `X-Sandboxd-Token` header, for proxies that strip `Authorization`.

These are upstream fixes, not defects we found. A before/after measurement of the first two, on a running daemon, shows exactly what each changed. (#2164 is an added header, not a behaviour that differs on a default; it is not measured here.)

No per-tag `sandboxd` image is published: the project pushes only a moving staging tag (`.../agent-sandbox/sandboxd:latest-main`). So each tag is built from its own source with the project's own `packages/sandboxd/Dockerfile`, which is how the version becomes a parameter rather than a vendored tree.

## Decision

A measurement job, separate from the repository's own checks, under `tests/upstream-sandboxd/`:

- `run.sh` builds `sandboxd` from two tags (`BASELINE_TAG`, `CANDIDATE_TAG`, default v1.0.10 and v1.0.11, recorded with their commits in `UPSTREAM.txt`), runs each standalone under `docker` with a `--root-dir` on a volume, and probes its REST API from a client container on the same network. Nothing touches Kubernetes, the internet or a cloud; every path is a fixture in the daemon's own root.
- `probe.py` sends one file operation per probe and records the daemon's answer: a status, an error code, or no answer within the deadline (a hang). `verdict.py` compares the two tags into a before/after table and a verdict.

The matrix (measured 2026-11-15, built from the tags' own source):

| fix | probe | v1.0.10 (baseline) | v1.0.11 (candidate) |
|---|---|---|---|
| #2222 | `GET` named pipe | hang (no answer in 6s) | `400 INVALID_ARGUMENT` |
| #2222 | `GET` device node (`/dev/zero`) | `200`, opened the device (0 bytes) | `400 INVALID_ARGUMENT` |
| #2218 | `DELETE` in-root symlink to a file | `204`, followed the link, target deleted | `204`, removed the link, target survives |
| #2218 | `DELETE ?recursive=true` in-root symlink to a dir | `204`, followed the link, directory cleared | `204`, removed the link, directory survives |

Two limits are stated with the result, so the wording stays honest:

- The device node here is `/dev/zero`; on v1.0.10 the daemon opens it and answers `200` with an empty body, which is not a hang. The hang is the named pipe. The fix rejects both.
- A symlink whose target is **outside** the root is already refused on v1.0.10 by a path-traversal guard (`403`), so its outside target is untouched on either tag. The data loss #2218 fixes is for **in-root** symlink targets, which the two symlink probes use; the escaping link is kept as a control.

Each dimension is paired with a control that must succeed (`GET` of a regular file `200`, `DELETE` of a regular file `204`, on both tags), so a refusal is a property of the input and not a broken endpoint. The verdict is `CONFIRMED` only when both controls pass and every dimension moves from the baseline behaviour to the fix. `verdict.py plant` feeds the gate a still-vulnerable candidate and fails the run unless the gate rejects it; `run.sh` runs it first.

The baseline default moves from v1.0.10 to v1.0.11 only after this measurement is green and the release is three days old (AGENTS.md, "Pins"); measuring a candidate is not adopting it.

## What it costs

Two `go build`s of the daemon per run, from a shallow clone of each tag, so the job is a few minutes and depends on upstream staying reachable. A built image is not pinned by digest the way a used image is; the measured object is instead pinned by tag and commit, recorded in `UPSTREAM.txt` and in the result. Building from a moving upstream is acceptable for a measurement, where the point is to run the upstream code; it would not be for anything this repository's claims table rests on.

## What was considered instead

- **Extending `tests/upstream-egress`.** Rejected: that module measures the router's `NetworkPolicy` on kind; this measures a daemon's file handlers under `docker`. A different component and mechanism kept legible in its own module, each with its own "measured on vX defaults" scope.
- **Pulling the staging image.** Rejected: `sandboxd:latest-main` moves and is not a release tag, so it cannot stand for v1.0.10 or v1.0.11.
- **Pointing the symlink outside the root.** Rejected as the main probe: v1.0.10 already refuses it (the path-traversal guard), so it shows no before/after. Kept as a control.

## How this is explained to a customer

agent-sandbox v1.0.11 hardened its runtime daemon's file handlers: a `DELETE` of a symlink no longer follows it to the target, and reading a named pipe or device file no longer hangs the handler. We measured both on the daemon built from its own source, v1.0.10 against v1.0.11, with controls and a self-testing gate, and we keep the before/after. This repository does not run sandboxd; the measurement is how we read an upstream default, the same way we read the router's egress in ADR 7.
