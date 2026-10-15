# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
