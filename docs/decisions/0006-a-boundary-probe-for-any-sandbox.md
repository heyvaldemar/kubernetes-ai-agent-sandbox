# 6. A boundary probe that runs in any sandbox, trusted only after it has failed

- Status: accepted
- Date: 2026-11-05

## Context

The e2e asks this sandbox what a fooled agent can reach, from inside the sandbox, on kind. Agents also run in other sandboxes: a coding agent on a laptop runs in a microVM such as Docker Sandboxes, with a workspace mounted from the host, a proxy in front of the network and a Docker daemon of its own. The questions are the same (a host off the allowlist, the host's files, its credentials, its Docker socket, its environment, writes outside the workspace, DNS, root), and an answer is only worth something when it comes from a check that is known to see an open door when there is one.

## Decision

`probes/boundary_probe.py` makes eight planted attempts to get out from inside whatever sandbox it runs in, and reports each as a JSON line in the demo agents' format, marked as a test fixture: 1 a host the network policy does not allow, through the proxy, around it and by address; 2 a planted host file outside the workspace, and the host user's home; 3 credential files, an SSH agent and the instance metadata service; 4 a Docker socket, judged the host's only when its daemon ID is the host's; 5 a variable set only in the host's shell; 6 files written outside the workspace; 7 a random token carried out as a DNS name, through the resolver, straight to a resolver over UDP and TCP, and over DNS over HTTPS; 8 root, and from root the planted file through PID 1, the host's file shares mounted again, and a setuid file left in the workspace. What only the host can see is settled on the host by `verify`. It reads no credential's value. Standard library only.

The probe is shown the failure it exists to catch on every Verify run (`tests/probe/run.sh`): in a container with every door open each attempt must get through and the token must reach the target's DNS log, and in a container with every door shut each must be blocked. The target is a container on the runner. `probes/sbx-probe.sh` runs the probe in a Docker Sandboxes sandbox and keeps the sandbox's policy log beside the results.

## Consequences

- One probe, one output format, for this sandbox and any other: a run elsewhere can be read line by line against what this repository proves on kind.
- CI proves the probe, not any other sandbox. A run in Docker Sandboxes is a measurement of that sandbox on that day, with its versions written next to it, and this repository claims nothing about it.
- Run by hand, the default targets are on the internet (example.com, 1.1.1.1, a wildcard DNS zone on sslip.io, dns.google), and the only data they receive is the random token. CI points every target at the container on the runner.
- Two open-door checks need a Linux host: on Docker Desktop the host's PID namespace and file ownership are the VM's, so the planted file through PID 1 and the setuid file's owner come back blocked there. CI runs on Linux.

## Alternatives

- **A probe per sandbox.** Each would answer in its own words, and nothing would line the answers up.
- **Run the probe inside the kind e2e's agent pods.** The demo agents already make those attempts there, with the sandbox's own targets; the probe can join them later without changing its format.
- **Trust the probe because its code reads right.** A check that has never been seen to fail proves nothing; the open container is that failure, on every run.

## How to explain this to a customer

The same eight escape attempts run in any sandbox an agent might live in, and each sandbox's answers come back in the same form. Before anyone trusts a "blocked", the probe is run where every door is open and has to report each one as open.
