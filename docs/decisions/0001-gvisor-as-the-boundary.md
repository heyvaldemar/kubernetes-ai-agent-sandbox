# 1. gVisor as the isolation boundary

- Status: accepted
- Date: 2026-10-13

## Context

An agent runs code and commands that nobody reviewed, chosen by a model that may have been talked into it. A container on runc shares the node's kernel with every other pod; one exploitable kernel bug reachable from inside it is the node. The sandbox needs a boundary below the container that does not depend on the agent behaving.

## Decision

Agent pods run on gVisor (`runtimeClassName: gvisor`, handler `runsc`). gVisor answers the pod's system calls in its own user-space kernel, the Sentry, and makes a much smaller set of calls to the host itself. The RuntimeClass declares gVisor's per-pod overhead (10m CPU, 32Mi memory) so the scheduler and the namespace quota count it. The release is pinned in `gvisor.lock` with the SHA-512 of its bundle per architecture, and `scripts/install-gvisor.sh` refuses a bundle that does not match.

## Consequences

- A kernel bug reachable from an agent pod is a bug in the Sentry first. The e2e run reads the kernel a sandbox pod sees (`4.19.0-gvisor`) next to the node's own.
- System calls cost more, and I/O-heavy work runs slower; agents that mostly wait on models and tools notice little.
- Not every system call is implemented. A workload that needs one gVisor lacks fails under it, which is the right failure for a sandbox.
- Memory is accounted where gVisor runs, in the pod's sandbox cgroup, not in each container's. On a node with swap, that let a pod run past its limit; the threat model has the details, and CI runs without swap.
- GPUs are out of scope here. gVisor has GPU support of its own; serving models on GPUs is a separate repository.

## Alternatives

- **Kata Containers or Firecracker microVMs.** A hardware-virtualization boundary, stronger than a user-space kernel, and each pod gets its own guest kernel. Both need hardware virtualization exposed to the node, and a kind node is a container without it by default. They belong on bare-metal nodes, such as EKS metal instances, when the threat model calls for a VM per agent.
- **runc with a strict seccomp profile.** Cheap, and it narrows the system calls a container may make, but every allowed call still reaches the host kernel.
- **A separate cluster for agents.** The strongest separation from other workloads and the most expensive; it does not, by itself, protect the node from the agent.

## How to explain this to a customer

Each agent runs on its own small, separate operating-system kernel instead of sharing the machine's. If the agent, or whatever tricked it, tries to exploit a weakness in the operating system, it meets that small kernel first, not the server. It costs some speed on heavy disk or network work, and very little for agents that spend most of their time waiting on a model.
