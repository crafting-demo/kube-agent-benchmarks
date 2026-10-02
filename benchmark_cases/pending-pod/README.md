# Pending pod: unschedulable CPU request

A small Kubernetes troubleshooting scenario for LLM-powered agents. A Deployment starts with a CPU request that no node can satisfy, so its Pod stays `Pending` and never runs. The agent must diagnose the scheduling failure and make a minimal correction.

This folder contains plain Kubernetes manifests and the task prompt. It requires no Helm chart, custom container image, benchmark runner, or separate fault injection step. Evaluation is manual; automated grading will be added later. No benchmark results are published here.

## Files

```text
pending-pod/
├── README.md
├── prompt.md
└── manifests/
    ├── namespace.yaml
    ├── deployment.yaml
    └── service.yaml
```

## Environment

| Resource | Purpose |
| --- | --- |
| Namespace `pending-pod-benchmark` | Dedicated location for this attempt's resources. |
| Deployment `pending-demo` | Manages one Pod running a small, healthy Python HTTP application. |
| Service `pending-demo` | Internal address on port 80, forwarding to application port 8080. |

The Pod initially requests 500 CPUs (`cpu: "500"`, a unit error for `500m`) and 32 MiB of memory; its memory limit is 128 MiB, and it has no CPU limit. The 500-CPU request exceeds the allocatable CPU of any realistic node, so the fault does not depend on the cluster's node sizes. It runs as a non-root user and does not mount Kubernetes API credentials. The Service does not create an external load balancer.

The agent runs separately and needs its own Kubernetes access. A namespace separates resource names but does not enforce agent access restrictions or reserve dedicated nodes. Use namespace-scoped credentials for the agent and capacity appropriate to your cluster. These manifests do not provision agent credentials, RBAC, a cluster, or a Crafting sandbox.

## Prerequisites

- An existing Kubernetes cluster and a connected `kubectl` installation.
- Permission to create the dedicated namespace, Deployment, and Service, or an existing namespace supplied by an administrator.
- A Linux node that can pull `python:3.12-slim` from Docker Hub and has at least 500 millicores of unrequested CPU and 32 MiB of memory, so the reference repair can schedule.
- Cluster admission policies that allow these resources and settings. A namespace ResourceQuota or LimitRange that rejects the 500-CPU request would block Pod creation instead of leaving it `Pending`; do not apply one to this namespace.
- An agent with Kubernetes inspection and Deployment configuration-editing tools. Read-only access to nodes (`kubectl get nodes`, `kubectl describe node`) helps the agent compare requests with capacity but is not required: the scheduling event states the reason.

The image uses a public tag for this initial version. The tag can change; pin an approved image digest before conducting strictly versioned comparisons.

## Launch

Run from this folder. Confirm the selected cluster first:

```bash
kubectl config current-context
```

Use the namespace below only if it is reserved for this test. For simultaneous attempts, use a different namespace for each attempt as described below.

```bash
kubectl apply -f manifests/namespace.yaml
kubectl apply -n pending-pod-benchmark -f manifests/deployment.yaml -f manifests/service.yaml
```

The Deployment is faulty immediately: there is no healthy-first installation and no subsequent injection command. The Pod is created but stays `Pending`, with a `FailedScheduling` event similar to `0/3 nodes are available: 3 Insufficient cpu`. No image is pulled and no container starts. See [Kubernetes resource management](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/).

If the cluster runs an autoscaler, it reports that the Pod would not fit on a new node and does not add capacity. Record any autoscaler activity as a setup issue.

No automatic fault check is included. Do not make sandbox startup wait for this Deployment to become Ready: its unhealthy state is intentional. A Pod that is rejected at admission, or `Pending` for a reason other than insufficient CPU, indicates a setup issue rather than the intended failure.

### Using another namespace

Skip `namespace.yaml`, create a fresh namespace, and apply only the workload manifests:

```bash
kubectl create namespace pending-pod-run-002
kubectl apply -n pending-pod-run-002 -f manifests/deployment.yaml -f manifests/service.yaml
```

Replace `pending-pod-benchmark` in the task prompt and the commands below with that namespace. The Deployment and Service intentionally omit `metadata.namespace` so the `-n` argument selects their destination.

## Run with your agent

Give the agent the contents of [prompt.md](prompt.md) in a fresh conversation. Use its existing execution platform to execute tools; no separate runner is needed.

For Crafting, configure your sandbox's startup to apply the manifests to its intended Kubernetes target, then start your agent in that environment. Keep the agent's LLM and tools configurable through your agent definition. This folder does not yet include Crafting definitions. See [Crafting agent definitions](https://docs.sandboxes.cloud/references/ai-agent-definition.html).

Keep this operator README and any reference solution outside the agent's supplied context. The prompt requests live diagnosis; for controlled comparisons, also restrict filesystem access to setup files when your platform permits it.

## Manual evaluation

Use a 10-minute attempt budget, measured from task submission. Recovery includes a 60-second observation window. Record setup delays or changes to these defaults separately.

| Criterion | Passing evidence |
| --- | --- |
| Diagnosis | Identifies the excessive CPU request as the cause, using the scheduling event, Pod or Deployment configuration, or node capacity evidence. |
| Minimal correction | Reduces the CPU request to a schedulable value no greater than 1 CPU, keeping explicit CPU and memory requests. The memory request and limit, image, code, replica count, ports, and readiness probe are unchanged. |
| Deployment recovery | One updated, Ready, available replica; no obsolete `Pending` Pod remains. |
| Stability | The recovered Pod stays Ready with no restart-count increase for 60 seconds. A Pod replacement during observation restarts the observation window. |
| HTTP behavior | Returns HTTP 200 with body `healthy`. |
| Scope | No changes to nodes, other workloads, priority classes, or other resources outside the assigned scenario. |

Record pass/fail for each criterion, the CPU request the agent chose, elapsed recovery time, and tool-call/token counts when exposed by the agent platform. If a measurement is unavailable, mark it unavailable. Retain the agent definition, LLM identifier/settings, repository revision, and cluster version with your private notes. Stop at the time budget and record incomplete attempts as such. No automated score or results upload is implemented.

The following are operator checks after the agent has finished, not a pre-run validation step:

```bash
kubectl rollout status deployment/pending-demo -n pending-pod-benchmark --timeout=120s
kubectl get deployment pending-demo -n pending-pod-benchmark
kubectl get deployment pending-demo -n pending-pod-benchmark -o jsonpath='{.spec.template.spec.containers[0].resources}{"\n"}'
kubectl get pods -n pending-pod-benchmark -l app=pending-demo -o wide --watch
```

The resources output should show a CPU request of at most `1` (for example `500m`), a memory request of `32Mi`, and a memory limit of `128Mi`. Observe readiness and restart counts for 60 seconds, then press Ctrl+C. For an HTTP check, start forwarding:

```bash
kubectl port-forward -n pending-pod-benchmark service/pending-demo 18080:80
```

Keep it running and use a second terminal on the same machine:

```bash
curl --fail --include http://127.0.0.1:18080/
```

Expect HTTP 200 and `healthy`. Stop forwarding with Ctrl+C. This checks application HTTP behavior through a Service-selected Pod, not the full in-cluster Service networking path; networking is outside this scenario's scope.

## Reset and cleanup

To remove only this scenario's workload and retain the namespace:

```bash
kubectl delete -n pending-pod-benchmark -f manifests/deployment.yaml -f manifests/service.yaml
kubectl wait -n pending-pod-benchmark --for=delete pod -l app=pending-demo --timeout=120s
```

After deletion finishes, reapply the workload manifests to start again with the fault configured. This removes the previous Deployment's revision history; simply reapplying over a repaired Deployment does not provide the same clean history. Use a fresh namespace and conversation for independent comparisons.

If the namespace was created exclusively for this attempt and contains nothing you need to retain, remove it too:

```bash
kubectl delete namespace pending-pod-benchmark
```

Do not run namespace deletion against a shared namespace. When a Crafting sandbox targets an external cluster, explicitly clean up its resources there; deleting the sandbox alone may leave them behind.

## Operator reference solution

Do not include this section in the agent's task context.

The container requests `cpu: "500"`, which Kubernetes reads as 500 whole CPUs rather than 500 millicores. The scheduler finds no node with that much allocatable CPU and leaves the Pod `Pending` with an `Insufficient cpu` event. The application, image, and memory settings are correct; the container never starts, so there are no logs to inspect.

The reference repair is:

```bash
kubectl set resources deployment/pending-demo -n pending-pod-benchmark -c app --requests=cpu=500m
```

The Deployment replaces the `Pending` Pod with one using the corrected request, which schedules and becomes Ready. Other values up to 1 CPU are acceptable. Removing the CPU request, adding nodes, or changing node labels or taints is not the intended repair.
