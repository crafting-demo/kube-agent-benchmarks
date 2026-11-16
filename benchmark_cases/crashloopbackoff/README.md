# CrashLoopBackOff: invalid application configuration

A small Kubernetes troubleshooting scenario for LLM-powered agents. A Deployment starts with an invalid environment value, causing its application container to exit and restart repeatedly. The agent must diagnose the cause and make a minimal correction.

This folder contains plain Kubernetes manifests and the task prompt. It requires no Helm chart, custom container image, benchmark runner, or separate fault injection step. Evaluation is manual; automated grading will be added later. No benchmark results are published here.

## Files

```text
crashloopbackoff/
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
| Namespace `crashloop-benchmark` | Dedicated location for this attempt's resources. |
| Deployment `crash-demo` | Manages one Pod running a small Python HTTP application. |
| Service `crash-demo` | Internal address on port 80, forwarding to application port 8080. |

The Pod requests 50 millicores of CPU and 32 MiB of memory; its limits are 200 millicores and 128 MiB. It runs as a non-root user and does not mount Kubernetes API credentials. The Service does not create an external load balancer.

The agent runs separately and needs its own Kubernetes access. A namespace separates resource names but does not enforce agent access restrictions or reserve dedicated nodes. Use namespace-scoped credentials for the agent and capacity appropriate to your cluster. These manifests do not provision agent credentials, RBAC, a cluster, or a Crafting sandbox.

## Prerequisites

- An existing Kubernetes cluster and a connected `kubectl` installation.
- Permission to create the dedicated namespace, Deployment, and Service, or an existing namespace supplied by an administrator.
- A Linux node that can pull `python:3.12-slim` from Docker Hub and has capacity for the Pod.
- Cluster admission policies that allow these resources and settings.
- An agent with Kubernetes inspection and Deployment configuration-editing tools.

The image uses a public tag for this initial version. The tag can change; pin an approved image digest before conducting strictly versioned comparisons.

## Launch

Run from this folder. Confirm the selected cluster first:

```bash
kubectl config current-context
```

Use the namespace below only if it is reserved for this test. For simultaneous attempts, use a different namespace for each attempt as described below.

```bash
kubectl apply -f manifests/namespace.yaml
kubectl apply -n crashloop-benchmark -f manifests/deployment.yaml -f manifests/service.yaml
```

The Deployment is faulty immediately: there is no healthy-first installation and no subsequent injection command. After the image is pulled and the container fails repeatedly, Kubernetes will display `CrashLoopBackOff`. The display may alternate with other statuses during retries. See [Kubernetes Pod lifecycle](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/).

No automatic fault check is included. Do not make sandbox startup wait for this Deployment to become Ready: its unhealthy state is intentional. A registry, scheduling, or authorization error is a setup issue rather than the intended configuration failure.

### Using another namespace

Skip `namespace.yaml`, create a fresh namespace, and apply only the workload manifests:

```bash
kubectl create namespace crashloop-run-002
kubectl apply -n crashloop-run-002 -f manifests/deployment.yaml -f manifests/service.yaml
```

Replace `crashloop-benchmark` in the task prompt and the commands below with that namespace. The Deployment and Service intentionally omit `metadata.namespace` so the `-n` argument selects their destination.

## Run with your agent

Give the agent the contents of [prompt.md](prompt.md) in a fresh conversation. Use its existing execution platform to execute tools; no separate runner is needed.

For Crafting, configure your sandbox's startup to apply the manifests to its intended Kubernetes target, then start your agent in that environment. Keep the agent's LLM and tools configurable through your agent definition. This folder does not yet include Crafting definitions. See [Crafting agent definitions](https://docs.sandboxes.cloud/references/ai-agent-definition.html).

Keep this operator README and any reference solution outside the agent's supplied context. The prompt requests live diagnosis; for controlled comparisons, also restrict filesystem access to setup files when your platform permits it.

## Manual evaluation

Use a 10-minute attempt budget, measured from task submission. Recovery includes a 60-second observation window. Record setup delays or changes to these defaults separately.

| Criterion | Passing evidence |
| --- | --- |
| Diagnosis | Identifies the invalid environment value using live logs or configuration evidence. |
| Minimal correction | Fixes the configuration while preserving application code, image, replica count, resource settings, and readiness probe. |
| Deployment recovery | One updated, Ready, available replica; no obsolete application Pod remains running. |
| Stability | The recovered Pod stays Ready with no restart-count increase for 60 seconds. A Pod replacement during observation restarts the observation window. |
| HTTP behavior | Returns HTTP 200 with body `healthy`. |
| Scope | No changes outside the assigned scenario resources. |

Record pass/fail for each criterion, elapsed recovery time, and tool-call/token counts when exposed by the agent platform. If a measurement is unavailable, mark it unavailable. Retain the agent definition, LLM identifier/settings, repository revision, and cluster version with your private notes. Stop at the time budget and record incomplete attempts as such. No automated score or results upload is implemented.

The following are operator checks after the agent has finished, not a pre-run validation step:

```bash
kubectl rollout status deployment/crash-demo -n crashloop-benchmark --timeout=120s
kubectl get deployment crash-demo -n crashloop-benchmark
kubectl get pods -n crashloop-benchmark -l app=crash-demo --watch
```

Observe readiness and restart counts for 60 seconds, then press Ctrl+C. For an HTTP check, start forwarding:

```bash
kubectl port-forward -n crashloop-benchmark service/crash-demo 18080:80
```

Keep it running and use a second terminal on the same machine:

```bash
curl --fail --include http://127.0.0.1:18080/
```

Expect HTTP 200 and `healthy`. Stop forwarding with Ctrl+C. This checks application HTTP behavior through a Service-selected Pod, not the full in-cluster Service networking path; networking is outside this scenario's scope.

## Reset and cleanup

To remove only this scenario's workload and retain the namespace:

```bash
kubectl delete -n crashloop-benchmark -f manifests/deployment.yaml -f manifests/service.yaml
kubectl wait -n crashloop-benchmark --for=delete pod -l app=crash-demo --timeout=120s
```

After deletion finishes, reapply the workload manifests to start again with the fault configured. This removes the previous Deployment's revision history; simply reapplying over a repaired Deployment does not provide the same clean history. Use a fresh namespace and conversation for independent comparisons.

If the namespace was created exclusively for this attempt and contains nothing you need to retain, remove it too:

```bash
kubectl delete namespace crashloop-benchmark
```

Do not run namespace deletion against a shared namespace. When a Crafting sandbox targets an external cluster, explicitly clean up its resources there; deleting the sandbox alone may leave them behind.

## Operator reference solution

Do not include this section in the agent's task context.

The application requires `APP_MODE=production`, while the initial Deployment supplies `APP_MODE=invalid`. Its process logs the invalid value and exits with code 1. Kubernetes restarts that process; the readiness probe is not the cause of the crash.

The reference repair is:

```bash
kubectl set env deployment/crash-demo -n crashloop-benchmark APP_MODE=production
```

The Deployment creates a replacement Pod using the corrected configuration. Verify recovery using the criteria above. A fresh installation has no earlier healthy revision, so rollback is not the intended repair.
