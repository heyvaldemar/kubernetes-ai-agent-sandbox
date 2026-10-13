# Security policy

## Supported versions

| Version | Supported |
|---|---|
| The latest release | yes |
| `main` | yes |
| Older releases | no |

## Reporting a vulnerability

Report privately through GitHub: **Security → Report a vulnerability** on this repository. Email to v@valdemar.ai also works. The process is described at [heyvaldemar.com/security](https://heyvaldemar.com/security/).

You can expect an acknowledgment within 7 days. There is no bounty program; valid, responsibly disclosed reports are credited in the changelog. Please do not open public issues for security reports.

## What this repository is

A reference sandbox, not a hosted service. A vulnerability here is most likely a way for a workload in a sandbox namespace to reach something the README says it cannot: a path past the egress policies, an admission rule a manifest can slip through, a gVisor setting that weakens the boundary.

## Supply chain

- Container images are pinned by digest, and CI fails on one that is not.
- GitHub Actions are pinned by commit SHA; CLI tools by version and sha256 (`tools.lock`); CI images by digest (`ci-images.pins`); gVisor by release and the SHA-512 of its bundle per architecture (`gvisor.lock`).

## Credentials

None. The demo agent uses no model and no API key, and nothing in this repository or its CI stores a credential.
