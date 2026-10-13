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
| Cluster capacity | an agent in a loop can take a node |

## Threats, controls and evidence

| Threat | Control | Evidence |
|---|---|---|
| The agent follows an injected instruction and sends its task to an outside address | nothing leaves an agent pod but DNS and the one tool it is given (`network-policies.yaml`) | the demo agent follows the injection in its tool's answer and is blocked; a pod outside the sandbox reaches the same address, so the block is the sandbox's |
| The agent asks the instance metadata service for cloud credentials | the same egress allowlist; 169.254.169.254 is not on it | the demo agent's request times out |
| The agent reaches another team's service | the egress allowlist, and a second wall: `corp` refuses any namespace labelled as a sandbox | the demo agent is blocked; with the sandbox's egress opened by mistake, `corp` still refuses it while the internet answers |
| The agent uses the Kubernetes API | no service account token in the pod (admission refuses one), and the API server is not on the egress allowlist | planted pod with a token refused; the demo agent finds no token and cannot connect |
| A kernel exploit from inside the pod | gVisor: the pod's system calls are answered by gVisor's user-space kernel, not the node's; Pod Security `restricted` (no privilege, no capabilities, seccomp) | a sandbox pod reports kernel `4.19.0-gvisor` while the node runs its own; planted pods without gVisor, or privileged, refused |
| A workload placed outside the sandbox through a controller | the admission policy reads the pod template of Deployments, StatefulSets, ReplicaSets, DaemonSets, Jobs and CronJobs | planted Deployment without gVisor refused |
| The agent leaves something behind in its image | read-only root filesystem, required by admission | planted pod with a writable root refused; the demo agent's write is refused |
| An image changes under its tag | images by digest, required by admission and by the static check | planted tag-only pod refused; `validate.sh images` with its plant |
| An agent in a loop takes the node | CPU and memory limits required; a namespace quota; gVisor's overhead counted by the scheduler and the quota | planted pod without limits refused; a memory hog killed at its limit; a pod asking for 3Gi refused by the quota |

## A finding: swap and the memory limit

On a node with swap, a pod running under gVisor is not held to its memory limit. In this repository's first run, on a kind node in Docker Desktop with 1 GiB of swap, a pod with a 128Mi limit kept writing memory until it held about 1 GiB, then died. The same program under runc, on the same node, died at 112 MiB.

The reason is where gVisor runs. Kubernetes sets the memory limit and `memory.swap.max=0` on the cgroup of each container. gVisor runs the pod's processes inside its own sandbox process, and that process sits in the cgroup of the pod's sandbox container, not the application container's. The pod's cgroup above it holds the pod's total limit (the container's 128Mi plus the 32Mi overhead the RuntimeClass declares), and neither carries `memory.swap.max=0`. The application container's cgroup, the one with the limit and no swap, was empty. Everything past 160Mi went to swap until swap ran out.

The LimitedSwap variant of this, where a pod is meant to get a swap budget and a gVisor pod got none, was reported as [gVisor issue 13267](https://github.com/google/gvisor/issues/13267) and fixed in June 2026: runsc now writes the swap limit it is given to the cgroup it joins. The release pinned here, 20261005, includes that fix. Under the default NoSwap behaviour the cgroup runsc joins is still given no swap limit, which is what this repository measured.

Production Kubernetes nodes usually run without swap. Machines people test on often have it: the GitHub-hosted runner this repository's CI uses had a 3 GiB swap file ([the e2e log](https://github.com/heyvaldemar/kubernetes-ai-agent-sandbox/actions/runs/38346033604) prints it before turning it off). CI turns swap off before it creates the cluster, and the e2e run fails if the node has any; with swap off, the same gVisor pod is killed at 112 MiB. A cluster that enables swap on its nodes for other reasons needs it accounted for before agent workloads run there.

## Residual risks

- **DNS is open.** An agent can resolve any name, and a query is itself a way out: data can be encoded into the names it looks up. Closing it needs a DNS policy that answers only for allowed names, which this sandbox does not have.
- **The tool is trusted.** The agent may call the tool gateway, so whatever the tool will do on the agent's behalf, a fooled agent can ask for. A tool that fetches arbitrary URLs is an exit. Tools must validate what they are asked to do.
- **NetworkPolicy works on addresses, not names.** Allowing `api.example.com` by name needs an FQDN-aware network plugin (Cilium, for example); with NetworkPolicy alone, an outside service is allowed by IP range or not at all.
- **The namespace label is the sandbox.** The admission binding and the second wall key on `sandbox.heyvaldemar.com/agents`. Whoever can edit namespaces can remove it; only cluster administrators can here.
- **gVisor is a smaller kernel, not no kernel.** The Sentry is software and can have bugs of its own. It narrows what a pod can reach in the host kernel; it does not remove the need to patch.
- **No runtime detection and no record of what the agent did.** Nothing watches system calls or keeps an audit of the agent's attempts beyond its own report.
- **One node.** On EKS, agent workloads would run on their own node group, tainted so nothing else lands there.

## How to explain this to a customer

Assume the AI agent will eventually be tricked by something it reads; every model can be. This setup decides what a tricked agent can do: it can call the one tool it was given and nothing else, it cannot read the cloud's credentials or the cluster's, it cannot reach other teams' systems, it cannot change its own software, and it runs on a separate, smaller kernel so a kernel bug does not hand it the machine. Every one of those limits is tested on every change by an agent that is tricked on purpose.
