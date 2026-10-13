# 2. Admission by a native ValidatingAdmissionPolicy

- Status: accepted
- Date: 2026-10-13

## Context

A sandbox that a workload can opt out of is a convention. The rules that make a pod a sandboxed pod (gVisor, no API token, a read-only image, limits, an image by digest) have to be enforced when the pod or its controller is created, by something that cannot be switched off by accident.

## Decision

One ValidatingAdmissionPolicy (`manifests/admission.yaml`) carries the rules, bound by a ValidatingAdmissionPolicyBinding to every namespace labelled `sandbox.heyvaldemar.com/agents: "true"`. The API server evaluates it in-process: there is no webhook, no controller and no add-on to keep running. One CEL variable reads the pod spec of a Pod, a Deployment, a StatefulSet, a ReplicaSet, a DaemonSet, a Job or a CronJob, so a controller cannot carry an unsandboxed pod past it. Pod Security `restricted` on the namespace covers privilege, capabilities, host namespaces and root underneath it.

## Consequences

- Nothing to install and nothing that can be scaled to zero. The companion platform found that Kyverno deletes its own webhooks when its admission controller is scaled down; this sandbox has no such path.
- Each rule is shown its violation: a planted manifest per rule, applied with a server-side dry run in every e2e run, plus a compliant control that must be admitted.
- CEL only: the policy can refuse, not mutate. A team writes the sandbox fields into its manifests; the refusal message says which one is missing.
- The namespace label is the sandbox. Whoever can edit namespaces can remove it, so that right stays with cluster administrators.

## Alternatives

- **Kyverno or Gatekeeper.** More expressive, and able to mutate (add the runtime class instead of refusing its absence). One more controller to run, and a webhook that fails open or closed when it is down.
- **A mutating policy that adds gVisor.** Friendlier to teams, but a sandbox applied silently is a sandbox nobody knows they are in; a refusal teaches the rule.

## How to explain this to a customer

The rules for running an agent are checked by Kubernetes itself, at the moment anyone tries to start one, and there is nothing extra running that could be switched off to get around them. A request that breaks a rule is refused with a message that says which rule.
