# Working on this repository as an agent

Most of the code here is written by an AI agent, and the decisions and the verification are the maintainer's. This file is what the agent is held to. A reviewer can hold it to the same rules.

## What this repository claims

Every row of the README's table "What is proven, and how" is a check that runs in CI: `tests/e2e/run.sh` on a fresh kind cluster with gVisor (`.github/workflows/e2e.yml`), or `scripts/validate.sh` with its planted violations and `tests/mcp/sdk_client.py` (`.github/workflows/verify.yml`). Each refusal is paired with a control that must succeed, so a check cannot pass because the environment refuses everything. A claim with no check is not written, and in `docs/threat-model.md` a control with no check is listed as a residual risk. It is a reference architecture on kind, CPU only, at no cloud cost, and nothing says otherwise: no wording about running anywhere in production or holding a certification (the fleet's conformance check refuses it).

## Before changing anything

- Read the decision record that covers it, under `docs/decisions/`. A change that alters a decision amends that record (the "Revisited" section of ADR 3 is the example) or adds one, in the same format, ending with how the choice is explained to a customer. A change to a threat or a control changes its row in `docs/threat-model.md`.
- `make check` runs `scripts/validate.sh` (kubeconform, images, agent, mcp), then `tests/static/plant_violations.py`, which shows each check its planted violation from `tests/static/plants.tsv`. It must end all caught, none missed, none stale. Verify also runs actionlint and shellcheck and drives the MCP server with the official MCP SDK; `make check` does not.
- `make test` runs the e2e against the cluster `make up` creates, and fails on a machine with swap, on purpose. Docker Desktop has swap, so the e2e is proved in CI.

## A check is trusted only after it has failed

A new or changed check ships with the violation it exists for: a planted manifest under `tests/e2e/plants/` whose `# expect:` line names the refusal it must get (or `admitted`, for a control), a row in `tests/static/plants.tsv`, or a deliberate sabotage run whose failing output is recorded in the commit message. A plant whose text is no longer in its file is reported stale and fails the run, so a change to a planted file updates its row in the same commit. A check that has never been seen to fail proves nothing.

## Proving a risky change

A change to the runtime, admission, a network policy, the MCP server, a pin or a workflow runs the full e2e and Verify on a branch before it reaches main:

```bash
gh workflow run e2e.yml --ref <branch>
gh workflow run verify.yml --ref <branch>
```

`scripts/status.py` reads e2e runs on main only, so branch runs never touch the badges. A dispatched Verify also runs the freshness job, which fails when upstream has moved past a pin; that failure is about upstream, not the branch.

## Pins

Everything is pinned:

- gVisor: the release and the SHA-512 of its bundle per architecture in `gvisor.lock`. `scripts/install-gvisor.sh` refuses a bundle that does not match.
- kind, kubectl and kubeconform: version and sha256 per platform in `tools.lock`. `scripts/install-tools.sh` refuses a file that does not match.
- CI images (actionlint, shellcheck): by digest in `ci-images.pins`.
- Container images: by digest where they are used, in `manifests/`, `tests/e2e/run.sh`, `tests/e2e/plants/` and `kind/cluster.yaml`. One image can be pinned in many files (busybox is in most plants and in `tests/e2e/run.sh`), and a bump moves every copy in one commit. The first row of `tests/static/plants.tsv` quotes the podinfo digest in `manifests/tools.yaml` and moves with it.
- The MCP SDK: by hash in `tests/mcp/requirements.txt`, compiled with uv from `tests/mcp/requirements.in`.
- The Kubernetes schemas: a fixed commit of yannh/kubernetes-json-schema in `scripts/validate.sh`.
- Actions: by commit SHA, bumped weekly by Dependabot in one group and merged by `dependabot-automerge.yml` only after the e2e and Verify pass. The SLSA generator in `release-assets.yml` is the exception: it refuses a SHA, so it is referenced by tag.

Dependabot reads only the actions. Everything else is moved by hand, with the new hash checked against the publisher's. `scripts/check-freshness.py` reports each pin upstream has moved past and changes nothing.

## Numbers

The second row of README badges is written by `.github/workflows/status.yml` (`scripts/status.py`) to the `status` branch, from the e2e runs on main and their `e2e-results` artifacts. It is never edited by hand. The counts the README states (twelve planted manifests refused and two controls admitted, nine planted violations, 26 protocol and grant tests) are the counts in `tests/e2e/plants/`, `tests/static/plants.tsv` and `tests/mcp/test_server.py`, and change with them in the same commit. Agent output in the README is pasted from a run on kind, not written. When a check fails on one run and passes on the next, find what changed (the runner, its swap, an image, the gVisor release) before calling it noise: the swap finding came from a check that failed during the build. A threshold comes from a stated cause, as the memory hog's 160 MiB ceiling is its 128Mi limit plus the RuntimeClass's 32Mi overhead, and is never loosened to get a green run.

## Releases

- Fill `CHANGELOG.md` `[Unreleased]` in the same commit as the change. The compare links at the bottom move when a version is cut.
- Tag only a commit whose e2e and Verify are green, or a docs-only commit right after one, and say which in the release notes: what is new, what was found while building it, how it was checked.
- Publishing a release runs `release-assets.yml`: an archive of the tag, a keyless cosign signature and SLSA provenance. Then verify them the way a stranger would, with the `cosign verify-blob` and `slsa-verifier verify-artifact --source-tag <tag>` commands at the top of that workflow.

## Writing

Plain and specific. No em dashes, no marketing words, no claim the evidence does not carry. Name runs, commits and files. Commit subjects follow the log: `type(scope): what changed`. Commits are authored `Vladimir Mikhalev <10498744+heyvaldemar@users.noreply.github.com>` and carry no AI attribution lines.

## Never

- Print a secret or a credential, pass one as a command-line argument, or put one in a file or a log. The records key is generated at install and handed to kubectl on stdin; the e2e run gives its tokens to curl on stdin (`curl --config -`).
- Turn off or weaken a check, a policy, a test or a gate to get a run green.
- Touch anything outside this repository's own CI to test a change: no cloud resources, no outside services.
- Put a model or a model API key into CI. The demo agent is a script that is fooled the same way every run (ADR 4).
- Let an agent pod or a tool server run without gVisor, or loosen what `manifests/admission.yaml` holds them to, the namespace labels it binds to, or Pod Security `restricted`.
- Open the agents' egress past DNS and the MCP server (`manifests/network-policies.yaml`), or let `corp` take calls from a sandbox namespace. A new tool is a tool in `manifests/mcp/server.py`, a grant in `manifests/mcp/policy.json` and a rule from the MCP server to its upstream, reviewed together (ADR 5).
- Grant `delete_record` to anyone, or let an agent namespace hold the records key or any Secret. The key exists in `corp` and `mcp` only.
- Let the MCP server take a token for another audience, or pass a caller's token on to an upstream.
- Drop the e2e's refusal of a node with swap. The systemd drop-in in the threat model is a mitigation for nodes that must keep swap, not a reason to stop checking.
