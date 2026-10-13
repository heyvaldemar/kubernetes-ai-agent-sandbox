# 4. A deterministic stand-in agent in CI, not a model

- Status: accepted
- Date: 2026-10-13

## Context

The sandbox has to be proven against an agent that misbehaves. A real model in CI costs money per run, answers differently from one run to the next, and needs a credential stored somewhere. None of that tests the sandbox.

## Decision

The demo agent (`manifests/agent/agent.py`) is a script that behaves like a fooled agent every time: it calls its tool, follows the instruction the tool's answer carries, and then tries the metadata service, another team's service, the Kubernetes API and the internet by IP address. It reports each attempt as a JSON line and exits non-zero if any outcome differs from what the sandbox promises. Standard library only, on a pinned `python:3.13-alpine`.

## Consequences

- Every run is the same run, free, with no API key anywhere.
- The test is about containment, not about whether a given model would be fooled. A model that resists this injection would still be run in the same sandbox.
- What a real agent does that this one does not (more tools, longer plans, code it writes and runs) is the reason the sandbox does not trust any of it.

## Alternatives

- **A small local model on CPU.** Realistic, slow, and still non-deterministic; it would make the e2e run flaky for no gain in what it proves.
- **A hosted model API.** A cost per run and a stored credential, in a repository whose point is that the workload is not trusted.

## How to explain this to a customer

The safety tests use a scripted agent that misbehaves the same way every time, so each test run proves the same thing and costs nothing. The protections do not depend on which AI model runs inside; they assume any of them can be tricked.
