# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Security

- **DNS no longer leaves the sandbox.** The agents asked the cluster's CoreDNS, which forwards to the internet, so a fooled agent could carry data out in the names it looked up; the threat model listed it as a residual risk. The agents now ask a resolver of their own, CoreDNS with no `forward` block, answering for `cluster.local` only (`manifests/agent-dns.yaml`), and their network policy refuses the cluster's CoreDNS. New e2e step 6: a sandbox pod resolves the MCP server's name and no outside name, cannot ask the cluster's CoreDNS, and outside the sandbox the same name resolves. Run against the sandbox before the change, the step failed on both sandbox lookups (run 39441398734; ADR 3, revisited).
- **A new pod's first instant was not policed.** kind's network plugin judges a pod's packets only once the pod's address is in its rules, a moment after the pod starts: a new sandbox pod's first query to the cluster's CoreDNS got an answer its policy refuses (run 39445988635). The agents' Jobs now start behind a gate, an init container that waits until the agents' resolver answers and the cluster's CoreDNS does not. The e2e measures the first instant on every run, and step 7 now also requires the first wall to close again once the policy that opened it is deleted.

### Added

- A demo at the top of the README: the e2e run of 39234194257, from installing gVisor and the sandbox to every check, replayed from the run's own log (`docs/demo/e2e.cast`, `docs/demo/e2e.gif`) by the new `scripts/cast-from-log.py`. The e2e refuses a node with swap, so it cannot be recorded on Docker Desktop; the log keeps every line with its time.
- `AGENTS.md` (and a `CLAUDE.md` that imports it): the rules an AI agent working on this repository is held to: claims only as CI checks, a check trusted only after it has failed, risky changes proved on a branch, every pin and where it lives, counts that change with the files they count, how a release is cut and verified, and what is never loosened: gVisor, admission, the egress allowlist, the MCP server's grants and its audience.
- A weekly check of every pin against upstream: `scripts/check-freshness.py`, run by the verify workflow on its schedule and by hand. It compares the charts the scripts install with their repository's index, every image pinned by digest with what its tag resolves to now, the tools in `tools.lock` with their newest releases, gVisor with its newest release, and the CI images. Dependabot here watched the workflows' actions and nothing else, so a chart, an image or a tool could fall behind without a sound.

### Changed

- The status workflow hands its push credential to git through git's environment, not its command line, which any process on the runner can read.
- The threat model's swap finding now carries a tested mitigation for nodes that must keep swap: a systemd drop-in that sets `MemorySwapMax=0` on the pods' slice, proposed on gVisor issue 15756 and measured here on 17 October (the gVisor pod killed at its 128Mi limit instead of reaching 848 MiB in swap), and the cgroupfs counterpart reported there a day later.

## [1.1.0] - 2026-10-14

### Added

- An MCP server as the agents' only door to their tools ([ADR 5](docs/decisions/0005-an-mcp-server-as-the-only-door.md)). It speaks MCP 2026-07-28 over Streamable HTTP, runs on gVisor and is written in standard-library Python. Each agent proves who it is with a ServiceAccount token bound to the server's audience, checked by TokenReview. `policy.json` grants each identity its tools and resources; anything else is answered as if it did not exist, and the destructive `delete_record` is granted to no one. The server holds the records key, limits each identity to ten calls in ten seconds, validates arguments against each tool's schema, caps and strips results, refuses browser origins, and logs every decision with the caller's pod.
- A service that wants a key (`manifests/records/`), and a second demo agent, the records clerk, who gets a record through the MCP server without ever holding the key. The key is generated at install and exists in `corp` and `mcp` only (`scripts/install-sandbox.sh`).
- Admission: an agent pod may reference no Secret, in a volume or in its environment, and may carry a projected token only for the MCP server's audience and for an hour at most. A second policy holds tool servers to gVisor, digests, limits and a read-only root. Five more planted manifests are refused and a second control is admitted.
- An e2e step for the MCP server: the API server refuses the MCP token, the MCP server refuses an API token and takes its own, the audit log shows each agent's refusals and allowed calls with its pod, and the key exists only where it is used. The wall check now covers the records service and the report service.
- The static check `mcp`, with six planted violations: a destructive tool granted, a grant of a tool that does not exist, a server that lists grants without enforcing them, no rate limit, a browser origin accepted, an agent token minted for the Kubernetes API. Behind it, 26 protocol and grant tests without a cluster (`tests/mcp/test_server.py`), and in Verify the official MCP Python SDK 2.3.0, pinned by hash, driving the server as two identities. The SDK found the first deviation: lists that must carry caching hints did not.

### Changed

- The agents' egress is DNS and the MCP server; it was the tool gateway, which now takes calls only from the MCP server.

### Fixed

- Waiting for a Job: a finished Job has two True conditions in Kubernetes 1.37, so waiting on them by jsonpath could match twice and fail. The e2e run and `make demo` wait for the succeeded or failed count.
- `make up` on macOS: its make (3.81) ran a simple recipe without a shell, so the `PATH` the Makefile exports never reached it and `kind` was not found. Every recipe now runs in bash.

### Added

- Live status: every e2e run uploads its checks and measurements (`E2E_RESULTS`), and `.github/workflows/status.yml` rewrites the `status` branch after each run with the last 30 days on main: green days, the streak, the latest checks (`scripts/status.py`). The README's second row of badges reads it.
- CodeQL (security-extended) on the Python and the workflows, on every push and weekly.
- The OpenSSF Best Practices badge, passing, and a README section on where a bug, a question or a change goes.

### Changed

- The threat model cites [gVisor issue 13267](https://github.com/google/gvisor/issues/13267), the LimitedSwap variant of the swap finding, fixed in June 2026 and included in the pinned release 20261005, and links the report of the default NoSwap case this repository measured, [gVisor issue 15756](https://github.com/google/gvisor/issues/15756).

### Removed

- A compiled Python file committed under `manifests/agent/__pycache__/`; `.gitignore` keeps them out.

## [1.0.1] - 2026-10-13

### Fixed

- Dependabot updates merge once the sandbox e2e and Verify pass. The auto-merge workflow waited for a workflow named `kind e2e` and read `verification.yml`, neither of which this repository has, so it never ran.

### Changed

- The e2e workflow logs the runner's swap before it turns swap off, and the threat model cites that log: the GitHub-hosted runner had a 3-gibibyte swap file.
- The README links the supply chain admission repository, the third piece next to the platform.

## [1.0.0] - 2026-10-13

### Added

- A sandbox for AI agent workloads on Kubernetes: gVisor as the runtime, an egress allowlist with a second wall at the destination, a native ValidatingAdmissionPolicy that refuses unsandboxed agent workloads, no API token, a read-only root filesystem, limits and a namespace quota.
- A demo agent that follows a prompt injection in its tool's answer and reports every attempt, run in every e2e pass.
- The kind e2e suite and the static checks, each shown its planted violation.
- A threat model, including a finding: on a node with swap, a pod under gVisor is held to its pod's RAM plus unlimited swap, not to its memory limit.
- Four decision records.

[Unreleased]: https://github.com/heyvaldemar/kubernetes-ai-agent-sandbox/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/heyvaldemar/kubernetes-ai-agent-sandbox/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/heyvaldemar/kubernetes-ai-agent-sandbox/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/heyvaldemar/kubernetes-ai-agent-sandbox/releases/tag/v1.0.0
