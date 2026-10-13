# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

_(no unreleased changes yet)_

## [1.0.0] - 2026-10-13

### Added

- A sandbox for AI agent workloads on Kubernetes: gVisor as the runtime, an egress allowlist with a second wall at the destination, a native ValidatingAdmissionPolicy that refuses unsandboxed agent workloads, no API token, a read-only root filesystem, limits and a namespace quota.
- A demo agent that follows a prompt injection in its tool's answer and reports every attempt, run in every e2e pass.
- The kind e2e suite and the static checks, each shown its planted violation.
- A threat model, including a finding: on a node with swap, a pod under gVisor is held to its pod's RAM plus unlimited swap, not to its memory limit.
- Four decision records.

[Unreleased]: https://github.com/heyvaldemar/kubernetes-ai-agent-sandbox/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/heyvaldemar/kubernetes-ai-agent-sandbox/releases/tag/v1.0.0
