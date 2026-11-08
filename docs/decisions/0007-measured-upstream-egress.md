# 7. Measuring an upstream default, and why this repository does not use agent-sandbox

- Status: accepted
- Date: 2026-11-08

## Context

[kubernetes-sigs/agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox) is the upstream project for running agent sandboxes on Kubernetes. Its `sandbox-router` is the entry point that forwards a caller's request to a sandbox Pod. Release [v1.0.10](https://github.com/kubernetes-sigs/agent-sandbox/releases/tag/v1.0.10) (2026-11-06) changed the router's default `NetworkPolicy` (#1550, #2144): `sandbox-router/deploy/networkpolicy.yaml`, applied by `kubectl apply -k sandbox-router/deploy/`, now allows the router egress on TCP `443` and `6443` to any destination, with a port-only rule and no `to:` selector. The release note states that with the default `--authz-mode=allow-all` a caller can target `443` and `6443` via the `X-Sandbox-Pod-IP` header, and that to scope the API-server egress you set `networkPolicy.apiServerCIDRs` (Helm) or add an `ipBlock` for the API server endpoint addresses. This is the upstream default and its documented restriction, not a defect.

This repository is a reference architecture about exactly this kind of boundary, and its boundary probe (ADR 6) already measures what a sandbox can reach. A measurement of the upstream default, in the same form, is worth having: it shows, on a running cluster, what the default permits and that the documented restriction closes it.

## Decision

A measurement job, separate from the repository's own checks, under `tests/upstream-egress/`:

- The upstream `sandbox-router/deploy/` manifests are vendored verbatim at v1.0.10 (commit `0d94fc0`) under `tests/upstream-egress/vendor/`. The `NetworkPolicy`, the object under measurement, is byte for byte upstream.
- An operational kustomize overlay changes only what a CI run needs: it creates the namespace, pins the router image by digest, runs one replica, and sets the router to a pure proxy (`--cache-enabled=false`, so no API or RBAC dependency) with a short upstream timeout and no retries. None of this touches the `NetworkPolicy`.
- `probes/router_egress_probe.py` (the ADR 6 boundary-probe family) sends the router one request per target carrying `X-Sandbox-Pod-IP` and `X-Sandbox-Port`, through a caller Pod, and records reached or blocked. Every target is an in-cluster plain-HTTP stub; nothing reaches the real internet or a cloud.
- `tests/upstream-egress/run.sh` measures config (a), the upstream default, then applies config (b), the documented `apiServerCIDRs` restriction (replacing the port-only `443`/`6443` rule with an `ipBlock` scoped to the API-server stand-in), and measures again.

The matrix (measured 2026-11-08 on kind):

| target | config a | config b | what it shows |
|---|---|---|---|
| ext-stub:443 | reached | blocked | 443 to a non-API destination, open by default, scoped out by the restriction |
| ext-stub:6443 | reached | blocked | same on 6443 |
| apisrv-stub:6443 | reached | reached | the API-server stand-in stays reachable under the restriction |
| ext-stub:8888 | blocked | blocked | a non-443/6443 port to a non-sandbox pod is never reached |
| hash-stub:8888 | reached | reached | the sandbox-egress path (any port to a Pod carrying the sandbox-name-hash label) works |

Config (a) reaching ext-stub on 443/6443 is the demonstration the egress is open by default; config (b) blocking it is the demonstration the restriction closes it. Each is the other's control, so neither passes because the environment refuses or allows everything. If config (b) does not block ext-stub, `run.sh` stops `INCONCLUSIVE` and the measurement claims nothing.

The Go router v1.0.10 already rejects loopback, link-local, multicast and unspecified addresses in `X-Sandbox-Pod-IP` (its own SSRF class check), so the cloud-metadata address is not reachable through it. This measurement is about egress to a routable, non-API destination on `443`/`6443`, which the default `NetworkPolicy` permits; it is not about reaching metadata.

## Why this repository does not use agent-sandbox

This repository's sandbox is built from its own parts, not from agent-sandbox: the agents run on gVisor (ADR 1), admission refuses any agent workload that is not set up that way (ADR 2), and the agents' own `NetworkPolicy` allows egress only to their resolver and the MCP server, with a second wall at each destination (ADR 3, ADR 5). There is no router with a port-only `443`/`6443` egress rule, and no allow-all authorizer in front of a caller-chosen dial target. The measurement here is of the upstream default, kept beside this repository's own design on purpose, so the difference is visible rather than asserted.

## Consequences

- One measurement, in the boundary-probe form, of a documented upstream default and its documented restriction, reproducible on kind at no cloud cost.
- It measures agent-sandbox v1.0.10, pinned by tag, commit and image digest. It is not a row of this repository's own claims table and does not write the badges. A later agent-sandbox release is a new measurement, not a regression here.
- The vendored manifests and the router image digest are pinned to v1.0.10 on purpose and are not freshness-tracked: the point is to measure that fixed version.

## Alternatives

- **Measure the NetworkPolicy from a co-labelled Pod, without the router.** It would measure the same egress, but the release note's behaviour is specifically that the allow-all router accepts a caller-chosen `X-Sandbox-Pod-IP`; running the real router measures that path as documented.
- **Reach the real API server on 6443 as the in-scope target.** The API server speaks TLS and the router sends plain HTTP, so reach would be read from an error rather than a clean answer. A plain-HTTP stand-in on 6443 makes reached unambiguous, and the measurement is of L4 egress, which the `NetworkPolicy` decides.
- **File it upstream first.** This is the documented default with a documented restriction; the measurement stands on its own, and any upstream contribution is a separate decision.

## How to explain this to a customer

The upstream agent-sandbox router, on its v1.0.10 default settings, lets a caller send traffic out to any address on the two API-server ports, because its default network rule is written by port rather than by destination; the project documents how to scope that to the API server, and this measurement runs both settings on a throwaway cluster and shows the default is open and the documented setting closes it. This project's own sandbox is built differently and does not have that rule.
