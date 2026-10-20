# Threat model

What the sandbox defends against when an AI agent misbehaves, the control for each threat, and the check that proves it. A control without a check is listed as a residual risk, not as a control.

The checks are `tests/e2e/run.sh` on a fresh kind cluster with gVisor (every change), and `scripts/validate.sh` with its planted violations (every change).

## The assumption

The agent will be fooled. A model that reads untrusted text, whether a web page, a ticket, a document or a tool's answer, can be talked into acting on instructions it found there, and no prompt is a reliable defence against that. This sandbox does not try to stop the agent from being fooled. It decides what a fooled agent can reach, and the demo agent (`manifests/agent/agent.py`) is fooled on purpose in every run.

## What is protected

| Asset | Why it matters |
|---|---|
| The node's kernel | one kernel bug reachable from a pod is every pod on the node |
| The cluster API | a token with the right verbs is the cluster |
| Other workloads and their data | stands in `corp`; another team's API, a database, a secrets store |
| Cloud credentials | the instance metadata service hands them to whoever asks from the node's network |
| The task's own data | what the agent was given is what an attacker wants sent out |
| The credentials tools need | a key an agent holds is a key a fooled agent can send |
| Cluster capacity | an agent in a loop can take a node |

## Threats, controls and evidence

| Threat | Control | Evidence |
|---|---|---|
| The agent follows an injected instruction and sends its task to an outside address | nothing leaves an agent pod but DNS to the agents' own resolver, which answers for the cluster's names only, and the MCP server (`network-policies.yaml`, `agent-dns.yaml`) | the demo agent follows the injection in its tool's answer and is blocked; a pod outside the sandbox reaches the same address, so the block is the sandbox's |
| The agent asks the instance metadata service for cloud credentials | the same egress allowlist; 169.254.169.254 is not on it | the demo agent's request times out |
| The agent carries data out in the names it looks up | the agents ask a resolver of their own, CoreDNS with no forward block, so no outside name is answered or relayed; their network policy refuses the cluster's CoreDNS, which forwards (`agent-dns.yaml`, `network-policies.yaml`) | e2e step 6: a sandbox pod resolves the MCP server's name and no outside name, and cannot ask the cluster's CoreDNS; outside the sandbox the same name resolves |
| The agent reaches another team's service | the egress allowlist, and a second wall: `corp` refuses any namespace labelled as a sandbox | the demo agent is blocked; with the sandbox's egress opened by mistake, `corp` still refuses it while the internet answers |
| The agent uses the Kubernetes API | no service account token in the pod (admission refuses one, and refuses a projected token for any audience but the MCP server's), and the API server is not on the egress allowlist | planted pods with an API token, a projected token with no audience and one valid for a day refused; the demo agents find no API token and cannot connect |
| The agent's MCP token is replayed at the API server, or an API token at the MCP server | each token names one audience: the MCP server checks its own with TokenReview, the API server refuses any other | the API server answers the MCP token with 401; the MCP server answers an API token with 401 and its own with 200; a static check fails if an agent's Job asks for another audience |
| The agent calls a tool it was not granted, or the destructive one | per-identity grants in the MCP server (`policy.json`); a tool not granted is not listed and is answered as if it did not exist; `delete_record` is granted to no one | the researcher is refused the records tool, the destructive tool and the records resource; the records clerk is refused the destructive tool and the report tool; the refusals are in the MCP server's log with the pod; static plants: a destructive grant, a grant of a tool that does not exist, a server that lists grants without enforcing them |
| The agent steals a credential a tool needs | the MCP server holds the records key and calls the service for the agent; admission refuses any Secret in an agent pod, in a volume or in its environment | planted pods with the key in a volume and in the environment refused; the records clerk gets a record and holds only its MCP token; the key exists in `corp` and `mcp` only |
| The agent goes around the MCP server to the service behind a tool | the report service takes calls from the MCP server only; the records service sits in `corp`, behind the second wall | both demo agents are blocked going direct; with the sandbox's egress opened, both services still refuse it |
| The agent floods a tool | ten calls per identity per ten seconds | the researcher's loop is limited, and the log shows it; a static plant removes the limit and the tests catch it |
| The agent passes a crafted argument to a tool | arguments validated against the tool's input schema before any upstream is called | the records clerk's injection-shaped customer ID is refused; `tests/mcp/test_server.py` |
| A web page drives the MCP server through a browser (DNS rebinding) | a request with an `Origin` header is refused with 403 | `tests/mcp/test_server.py`; a static plant that weakens the check is caught |
| A parsing bug in the MCP server, reached by what an agent sends | the MCP server runs on gVisor, read-only, by digest, with limits (a second admission policy, `tool-server-sandbox`) | planted tool server without gVisor refused |
| A kernel exploit from inside the pod | gVisor: the pod's system calls are answered by gVisor's user-space kernel, not the node's; Pod Security `restricted` (no privilege, no capabilities, seccomp) | a sandbox pod reports kernel `4.19.0-gvisor` while the node runs its own; planted pods without gVisor, or privileged, refused |
| A workload placed outside the sandbox through a controller | the admission policy reads the pod template of Deployments, StatefulSets, ReplicaSets, DaemonSets, Jobs and CronJobs | planted Deployment without gVisor refused |
| The agent leaves something behind in its image | read-only root filesystem, required by admission | planted pod with a writable root refused; the demo agent's write is refused |
| An image changes under its tag | images by digest, required by admission and by the static check | planted tag-only pod refused; `validate.sh images` with its plant |
| An agent in a loop takes the node | CPU and memory limits required; a namespace quota; gVisor's overhead counted by the scheduler and the quota | planted pod without limits refused; a memory hog killed at its limit; a pod asking for 3Gi refused by the quota |

## A finding: swap and the memory limit

On a node with swap, a pod running under gVisor is not held to its memory limit. In this repository's first run, on a kind node in Docker Desktop with 1 GiB of swap, a pod with a 128Mi limit kept writing memory until it held about 1 GiB, then died. The same program under runc, on the same node, died at 112 MiB.

The reason is where gVisor runs. Kubernetes sets the memory limit and `memory.swap.max=0` on the cgroup of each container. gVisor runs the pod's processes inside its own sandbox process, and that process sits in the cgroup of the pod's sandbox container, not the application container's. The pod's cgroup above it holds the pod's total limit (the container's 128Mi plus the 32Mi overhead the RuntimeClass declares), and neither carries `memory.swap.max=0`. The application container's cgroup, the one with the limit and no swap, was empty. Everything past 160Mi went to swap until swap ran out.

The LimitedSwap variant of this, where a pod is meant to get a swap budget and a gVisor pod got none, was reported as [gVisor issue 13267](https://github.com/google/gvisor/issues/13267) and fixed in June 2026: runsc now writes the swap limit it is given to the cgroup it joins. The release pinned here, 20261005, includes that fix. Under the default NoSwap behaviour the cgroup runsc joins is still given no swap limit, which is what this repository measured. That case is reported as [gVisor issue 15756](https://github.com/google/gvisor/issues/15756).

Production Kubernetes nodes usually run without swap. Machines people test on often have it: the GitHub-hosted runner this repository's CI uses had a 3 GiB swap file ([the e2e log](https://github.com/heyvaldemar/kubernetes-ai-agent-sandbox/actions/runs/38346033604) prints it before turning it off). CI turns swap off before it creates the cluster, and the e2e run fails if the node has any; with swap off, the same gVisor pod is killed at 112 MiB. A cluster that enables swap on its nodes for other reasons needs it accounted for before agent workloads run there.

A node can also hold the line itself. On 17 October a user on the issue traced the cause under the systemd cgroup driver and proposed a systemd drop-in that sets `MemorySwapMax=0` on the slice all pods live under; this repository tested it on the same kind node the same day. kind runs the kubelet with `cgroupRoot: /kubelet`, so its slice is `kubelet-kubepods.slice` (on a node with the default root it is `kubepods.slice`):

```sh
mkdir -p /etc/systemd/system/kubelet-kubepods.slice.d
printf '[Slice]\nMemorySwapMax=0\n' > /etc/systemd/system/kubelet-kubepods.slice.d/override.conf
systemctl daemon-reload
```

With it, the same gVisor pod was killed at its limit, at 128 MiB, instead of reaching 848 MiB in swap. The next day another user showed the same gap on a node in the cgroupfs layout, where runsc runs without `systemd-cgroup`: the pod's cgroup there reads `memory.swap.max=max` too, so the cause is not the driver. The cgroupfs counterpart of the drop-in is `echo 0 > /sys/fs/cgroup/kubelet/kubepods/memory.swap.max`, which does not survive a restart. It takes swap from every pod on the node, which is what NoSwap promises anyway; on a node set to LimitedSwap it would also take the budget those pods are allowed, so that case still needs the fix in runsc. The e2e run keeps refusing a node with swap: the drop-in is a mitigation for nodes that must keep swap, not a reason to stop checking.

## Residual risks

- **A new pod's first instant is not policed on kind.** kind's network plugin judges a pod's packets only once it has learned the pod's address, a moment after the pod starts; Kubernetes asks that filtering hold from a pod's very first instant. The e2e measures it every run (a new pod's first query to the cluster's CoreDNS was answered in run 39445988635). The agents' Jobs wait at a gate, an init container that lets the agent start only once the pod's own policy refuses the cluster's CoreDNS; a workload that skips the gate gets that moment. On another network plugin, measure it before relying on it.
- **A name inside the cluster can still carry a few bytes.** The agents' resolver answers only for `cluster.local`, so nothing it hears leaves the cluster; a workload that read its query log could still be told something. Its log records errors only, and nothing else reads its queries.
- **The tools are trusted.** The MCP server decides who may call a tool, not what a granted tool does. `quarterly_report` fetches one fixed address; a tool that fetched whatever URL it was given would be an exit, granted or not.
- **An instruction in plain words passes the MCP server.** It caps a result's size and strips control characters. It cannot tell an instruction from data, and the report tool hands the agent its injection every run. The sandbox is what decides what acting on it can reach.
- **Whoever can create a pod in `agents` chooses its ServiceAccount, and with it the grant.** The agents themselves have no API access; cluster administrators do.
- **A credential pasted into a pod spec is not caught.** Admission refuses references to Secrets. A key written as a plain environment value is just a string to it.
- **The MCP server is not the specification's OAuth flow.** It accepts in-cluster ServiceAccount tokens only (ADR 5). A client from outside the cluster has no way in, which is the point today and the work if that changes.
- **One MCP server replica.** The rate limit is per process; with several replicas each would allow its own ten calls.
- **NetworkPolicy works on addresses, not names.** Allowing `api.example.com` by name needs an FQDN-aware network plugin (Cilium, for example); with NetworkPolicy alone, an outside service is allowed by IP range or not at all.
- **The namespace label is the sandbox.** The admission binding and the second wall key on `sandbox.heyvaldemar.com/agents`. Whoever can edit namespaces can remove it; only cluster administrators can here.
- **gVisor is a smaller kernel, not no kernel.** The Sentry is software and can have bugs of its own. It narrows what a pod can reach in the host kernel; it does not remove the need to patch.
- **No runtime detection, and the audit trail stays on the node.** The MCP server logs every decision with the caller's ServiceAccount and pod, and the e2e run reads it back. Nothing ships that log off the node or alerts on it, and nothing watches system calls.
- **One node.** On EKS, agent workloads would run on their own node group, tainted so nothing else lands there.

## How to explain this to a customer

Assume the AI agent will eventually be tricked by something it reads; every model can be. This setup decides what a tricked agent can do: it reaches its tools through one door that knows which agent is calling and lets it use only what it was given, it holds no key worth stealing, it cannot read the cloud's credentials or the cluster's, it cannot reach other teams' systems, it cannot change its own software, and it runs on a separate, smaller kernel so a kernel bug does not hand it the machine. Every one of those limits is tested on every change by an agent that is tricked on purpose.
