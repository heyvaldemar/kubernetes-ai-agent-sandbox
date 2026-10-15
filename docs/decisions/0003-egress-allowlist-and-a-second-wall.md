# 3. Egress as an allowlist, and a second wall at the destination

- Status: accepted
- Date: 2026-10-13

## Context

What a fooled agent does next is mostly a network question: send the task to an outside address, ask the metadata service for credentials, call another team's service, talk to the Kubernetes API. Each of those is a connection the agent did not need to make.

## Decision

The `agents` namespace denies all ingress and egress by default (`network-policies.yaml`). Two egress rules open what an agent needs: DNS to the cluster's DNS service, and TCP 9898 to the tool gateway in `tools`. The tool gateway accepts calls only from sandbox namespaces. A second wall stands at the destination: `corp` refuses every namespace labelled as a sandbox, so a mistake in the sandbox's own policies does not open it.

## Consequences

- The agent reaches its tool and nothing else, and the e2e run proves both halves: the demo agent is blocked, and a pod outside the sandbox reaches the same addresses.
- With the sandbox's egress opened on purpose, the e2e run shows the internet answering and `corp` still refusing. The first wall is what keeps the internet out; the second is what keeps other teams' services out when the first is wrong.
- DNS stays open, and DNS can carry data. Closing it needs a resolver that answers only allowed names.
- Every new tool is a policy change, reviewed as one.

## Alternatives

- **An egress gateway or a forward proxy with an allowlist of names.** Allows `api.example.com` by name and logs every call; one more component on the path of every request.
- **FQDN-aware network policies (Cilium).** Names instead of IP ranges in the policy itself; ties the sandbox to one network plugin.
- **A service mesh with mTLS and authorization policies.** Identity-based rules between services; far more than an agent sandbox needs to start with.

## Revisited, 2026-10-14

The one destination is now the MCP server ([ADR 5](0005-an-mcp-server-as-the-only-door.md)), on TCP 8080 in `mcp`. The tool gateway takes calls only from the MCP server, and the records service behind the records tool sits in `corp`, behind the second wall. With the sandbox's egress opened on purpose, the e2e run shows `corp`, the records service and the report service all still refusing it.

## How to explain this to a customer

An agent can talk to the one tool it was given and nothing else: not the internet, not the cloud's credential service, not other teams' systems, not the cluster's control plane. The systems it must never reach also refuse it themselves, so a single mistake in the agent's own rules does not open them.
