# 5. An MCP server as the agent's only door to its tools

- Status: accepted
- Date: 2026-10-14

## Context

Until 1.0, the agent called one tool directly, and the tool answered anyone the network let through. That is enough to show what a fooled agent can reach. It cannot show who may use which tool, where the credentials a tool needs should live, or what record is left of an agent's attempts. An agent that calls real systems needs keys for them, and an agent that holds a key will be talked into sending it somewhere.

The Model Context Protocol is how agents reach tools now, so the door is an MCP server. Revision 2026-07-28 makes it stateless over Streamable HTTP. Every request carries its protocol version, is a POST of its own, and may be authorized on its own, and `tools/list` may differ by the authorization presented. That is the shape a per-caller grant needs.

## Decision

The agents' network allows DNS and one destination: the MCP server in `mcp` (`manifests/mcp/`). Every request to it is checked in this order:

1. **No browser origin.** A present `Origin` header is refused with 403, as the specification requires of every Streamable HTTP server.
2. **Who is calling.** The agent's pod carries one credential, a ServiceAccount token projected with the audience `mcp.sandbox.heyvaldemar.com` and a ten-minute lifetime. The server asks the API server's TokenReview whether that token is genuine for that audience, and reads the ServiceAccount and the pod it is bound to. A Kubernetes API token is refused here, and this token is refused by the API server.
3. **The protocol.** The version in the header and in `_meta` must agree and be 2026-07-28, and the `Mcp-Method` and `Mcp-Name` headers must match the body. Each failure gets the error code the specification assigns.
4. **The grant.** `policy.json` names the tools and resources each identity may use. A tool that is not granted is not listed, and a call to it gets the answer a tool that does not exist gets, so the grant cannot be probed. The destructive `delete_record` exists on the server and is granted to no one; a static check fails the build if it ever is.
5. **The call.** Ten tool calls per identity per ten seconds. Arguments are validated against the tool's input schema before any upstream is called. Results are capped at 4 KiB and stripped of control characters.

The key the records service wants is generated at install and exists as a Secret in two namespaces: `corp`, where the service checks it, and `mcp`, where the server uses it. Admission refuses any agent pod that references a Secret, in a volume or in its environment, or that carries a projected token for any other audience or for longer than an hour.

The MCP server runs on gVisor like the agents (a second admission policy, bound to the `tool-servers` label), because it parses whatever a fooled agent sends. Its own token can do one thing: create a TokenReview (`system:auth-delegator`). Its network reaches DNS, the two services its tools call and the API server. Every decision it makes is one JSON line with the ServiceAccount and the pod, and the e2e run reads those lines back.

The server is about 450 lines of standard-library Python, so every check above is readable in one file and testable without a cluster (`tests/mcp/test_server.py`). The official MCP Python SDK, pinned by hash, drives it as a client in CI. The SDK found the first deviation from the specification: lists that must carry caching hints did not.

## Consequences

- A fooled agent can reach the MCP server and, through it, only what its identity is granted. The e2e run proves the refusals and the controls for two identities.
- The agent never holds a credential worth stealing. Its one token is useless at the API server, expires in ten minutes and is bound to its pod.
- There is an audit trail for every attempt, with the pod that made it. The trail is the server's own log on the node; nothing ships it elsewhere yet.
- Adding a tool means a line in `server.py`, a grant in `policy.json` and a NetworkPolicy rule to its upstream, reviewed together.
- One replica, one rate limit per process. Several replicas would each allow their own ten calls.

## Not the specification's OAuth flow

MCP authorization is optional. A server that supports it over HTTP should act as an OAuth 2.1 resource server and publish Protected Resource Metadata (RFC 9728). This server does not run that flow. Inside one cluster the identity already exists: the kubelet mints a token bound to the pod and to an audience, and the API server checks it, which is the job an authorization server does. What the server does follow is the specification's rules for tokens. It accepts only tokens issued for its own audience, answers 401 to anything else, and never passes a caller's token to an upstream service. A client from outside the cluster, a desktop agent or another cluster's workload, would need the OAuth flow. That is the next step if this door ever opens to them.

## Alternatives

- **An MCP gateway product** (Docker's MCP Gateway, agentgateway and others). They aggregate servers, hold credentials and enforce policy, and they are what a team should adopt before writing its own. This repository writes the smallest version that shows each control and the check behind it.
- **Tools reached directly, with NetworkPolicy alone.** What 1.0 did. It decides where an agent can connect, not what it may ask for, and leaves every credential with the agent.
- **A Secret mounted into the agent, scoped by the upstream's own permissions.** The common case. It makes the agent the credential's holder, and a fooled agent its courier.

## How to explain this to a customer

Your AI agents reach their tools through one door that knows which agent is knocking. Each agent can see and use only the tools it has been given. The dangerous ones are given to no one, and a request for something it was not given is answered as if that thing did not exist. The passwords and keys those tools need stay behind the door; the agent asks for a result and never holds a key it could be tricked into handing over. Every attempt, allowed or refused, is written down with the agent that made it.
