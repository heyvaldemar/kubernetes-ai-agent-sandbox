# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

_(no unreleased changes yet)_

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

[Unreleased]: https://github.com/heyvaldemar/kubernetes-ai-agent-sandbox/compare/v1.0.1...HEAD
[1.0.1]: https://github.com/heyvaldemar/kubernetes-ai-agent-sandbox/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/heyvaldemar/kubernetes-ai-agent-sandbox/releases/tag/v1.0.0
