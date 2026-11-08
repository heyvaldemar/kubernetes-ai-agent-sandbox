# Decisions

Each record states the context, the decision, what it costs, what was considered instead, and how the choice would be explained to a customer.

| # | Decision | Status |
|---|---|---|
| 1 | [gVisor as the isolation boundary](0001-gvisor-as-the-boundary.md) | accepted |
| 2 | [Admission by a native ValidatingAdmissionPolicy](0002-admission-by-native-policy.md) | accepted |
| 3 | [Egress as an allowlist, and a second wall at the destination](0003-egress-allowlist-and-a-second-wall.md) | accepted |
| 4 | [A deterministic stand-in agent in CI, not a model](0004-a-deterministic-agent-in-ci.md) | accepted |
| 5 | [An MCP server as the agent's only door to its tools](0005-an-mcp-server-as-the-only-door.md) | accepted |
| 6 | [A boundary probe that runs in any sandbox, trusted only after it has failed](0006-a-boundary-probe-for-any-sandbox.md) | accepted |
| 7 | [Measuring an upstream default, and why this repository does not use agent-sandbox](0007-measured-upstream-egress.md) | accepted |
