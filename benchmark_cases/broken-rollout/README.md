# Broken rollout: readiness probe on a missing path

A small Kubernetes troubleshooting scenario for LLM-powered agents. A healthy Deployment receives a new release whose readiness probe checks a path the application does not serve. The new Pod runs but never becomes Ready, so the rollout stalls and exceeds its progress deadline. The agent must detect the failed rollout and recover the Deployment.

This folder contains plain Kubernetes manifests and the task prompt. It requires no Helm chart, custom container image, or benchmark runner. Evaluation is manual; automated grading will be added later. No benchmark results are published here.

## Files

```text
broken-rollout/
├── README.md
├── prompt.md
└── manifests/
    ├── namespace.yaml
    ├── deployment-v1.yaml
    ├── deployment-v2.yaml
    └── service.yaml
```

## Environment

| Resource | Purpose |
| --- | --- |
| Namespace `broken-rollout-benchmark` | Dedicated location for this attempt's resources. |
| Deployment `rollout-demo` | Manages two Pods running a small Python HTTP application. |
| Service `rollout-demo` | Internal address on port 80, forwarding to application port 8080. |

The application returns HTTP 200 with body `healthy` and an `X-App-Version` header on `/`, and HTTP 404 on every other path. Its version comes from the `APP_VERSION` environment variable.

| Manifest | Release | Readiness probe | Result |
| --- | --- | --- | --- |
| `deployment-v1.yaml` | `1.0.0` | `GET /` | Healthy. Revision 1. |
| `deployment-v2.yaml` | `1.1.0` | `GET /healthz` | Probe receives 404; Pods never become Ready. Revision 2. |

The two manifests differ only in the release version, its `kubernetes.io/change-cause` annotation, and the readiness probe path. The Deployment uses a rolling update with `maxSurge: 1` and `maxUnavailable: 0`, so the two 1.0.0 Pods keep serving while one 1.1.0 Pod stays unready. `progressDeadlineSeconds: 120` makes the Deployment report `ProgressDeadlineExceeded` two minutes after the bad release is applied. `revisionHistoryLimit: 3` keeps revision 1 available for rollback.

Each Pod requests 50 millicores of CPU and 32 MiB of memory; its memory limit is 128 MiB. It runs as a non-root user and does not mount Kubernetes API credentials. The Service does not create an external load balancer.

The agent runs separately and needs its own Kubernetes access. A namespace separates resource names but does not enforce agent access restrictions. Use namespace-scoped credentials for the agent. These manifests do not provision agent credentials, RBAC, a cluster, or a Crafting sandbox.

## Prerequisites

- An existing Kubernetes cluster and a connected `kubectl` installation.
- Permission to create the dedicated namespace, Deployment, and Service, or an existing namespace supplied by an administrator.
- Linux nodes that can pull `python:3.12-slim` from Docker Hub, with room for three of these Pods at once (150 millicores of CPU and 96 MiB of memory requested) during the rollout.
- Cluster admission policies that allow these resources and settings.
- An agent with Kubernetes inspection, log access, and Deployment editing or rollout tools.

The image uses a public tag for this initial version. The tag can change; pin an approved image digest before conducting strictly versioned comparisons.

## Launch

Run from this folder. Confirm the selected cluster first:

```bash
kubectl config current-context
```

Use the namespace below only if it is reserved for this test. For simultaneous attempts, use a different namespace for each attempt as described below.

A failed rollout needs a healthy revision to fail from, so launch has two steps. Install release 1.0.0 and wait until it is healthy:

```bash
kubectl apply -f manifests/namespace.yaml
kubectl apply -n broken-rollout-benchmark -f manifests/deployment-v1.yaml -f manifests/service.yaml
kubectl rollout status deployment/rollout-demo -n broken-rollout-benchmark --timeout=180s
```

Then apply the faulty release 1.1.0:

```bash
kubectl apply -n broken-rollout-benchmark -f manifests/deployment-v2.yaml
```

Do not wait for this rollout: its failure is intentional. One new Pod starts and stays `Running` but `0/1` Ready, with `Readiness probe failed: HTTP probe failed with statuscode: 404` events. The two 1.0.0 Pods stay Ready. After about two minutes, the Deployment's `Progressing` condition becomes `False` with reason `ProgressDeadlineExceeded`. See [Deployment status](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#failed-deployment).

For consistent starting conditions, wait for `ProgressDeadlineExceeded` before submitting the task:

```bash
kubectl wait deployment/rollout-demo -n broken-rollout-benchmark --for=jsonpath='{.status.conditions[?(@.type=="Progressing")].reason}'=ProgressDeadlineExceeded --timeout=180s
```

If release 1.0.0 does not become healthy, or the 1.1.0 Pod fails for a reason other than its readiness probe (for example an image pull error or a crash), treat it as a setup issue rather than the intended failure.

### Using another namespace

Skip `namespace.yaml`, create a fresh namespace, and apply the workload manifests in the same order:

```bash
kubectl create namespace broken-rollout-run-002
kubectl apply -n broken-rollout-run-002 -f manifests/deployment-v1.yaml -f manifests/service.yaml
kubectl rollout status deployment/rollout-demo -n broken-rollout-run-002 --timeout=180s
kubectl apply -n broken-rollout-run-002 -f manifests/deployment-v2.yaml
```

Replace `broken-rollout-benchmark` in the task prompt and the commands below with that namespace. The Deployment and Service intentionally omit `metadata.namespace` so the `-n` argument selects their destination.

## Run with your agent

Give the agent the contents of [prompt.md](prompt.md) in a fresh conversation. Use its existing execution platform to execute tools; no separate runner is needed.

For Crafting, configure your sandbox's startup to run both launch steps against its intended Kubernetes target, then start your agent in that environment. Keep the agent's LLM and tools configurable through your agent definition. This folder does not yet include Crafting definitions. See [Crafting agent definitions](https://docs.sandboxes.cloud/references/ai-agent-definition.html).

Keep this operator README and any reference solution outside the agent's supplied context. The manifests on disk show the difference between releases, so restrict the agent's filesystem access to setup files when your platform permits it.

## Manual evaluation

Use a 10-minute attempt budget, measured from task submission. Recovery includes a 60-second observation window. Record setup delays or changes to these defaults separately.

| Criterion | Passing evidence |
| --- | --- |
| Diagnosis | Identifies the readiness probe path `/healthz` in release 1.1.0 as the cause, using probe failure events, Pod readiness, rollout history, or the Deployment's progress condition. |
| Recovery approach | Either rolls back to release 1.0.0 (revision 1), or keeps release 1.1.0 and points its readiness probe at `/`. Record which approach was used. |
| Minimal correction | The image, application code, replica count, ports, resources, and Service are unchanged. The container still has an HTTP readiness probe on a path the application serves. |
| Rollout recovery | The latest rollout is complete: two updated, Ready, available replicas, `Progressing` is `True` with reason `NewReplicaSetAvailable`, and no Pods from another revision remain. |
| Stability | The recovered Pods stay Ready with no restart-count increase for 60 seconds. A Pod replacement during observation restarts the observation window. |
| HTTP behavior | Returns HTTP 200 with body `healthy`. |
| Scope | The Deployment was not deleted or recreated; no replacement workloads were created; no changes to other namespaces or cluster-wide resources. |

Record pass/fail for each criterion, the recovery approach, the running `APP_VERSION`, elapsed recovery time, and tool-call/token counts when exposed by the agent platform. If a measurement is unavailable, mark it unavailable. Retain the agent definition, LLM identifier/settings, repository revision, and cluster version with your private notes. Stop at the time budget and record incomplete attempts as such. No automated score or results upload is implemented.

The following are operator checks after the agent has finished, not a pre-run validation step:

```bash
kubectl rollout status deployment/rollout-demo -n broken-rollout-benchmark --timeout=120s
kubectl rollout history deployment/rollout-demo -n broken-rollout-benchmark
kubectl get deployment rollout-demo -n broken-rollout-benchmark -o jsonpath='{.status.conditions[?(@.type=="Progressing")].reason}{"\n"}'
kubectl get deployment rollout-demo -n broken-rollout-benchmark -o jsonpath='{.spec.template.spec.containers[0].env}{"\n"}{.spec.template.spec.containers[0].readinessProbe}{"\n"}'
kubectl get replicasets -n broken-rollout-benchmark -l app=rollout-demo
kubectl get pods -n broken-rollout-benchmark -l app=rollout-demo -o wide --watch
```

The progress reason should be `NewReplicaSetAvailable`. The environment should show `APP_VERSION` `1.0.0` (rollback) or `1.1.0` (forward fix), and the readiness probe should be an HTTP check on `/`. Only one ReplicaSet should have nonzero replicas. Observe readiness and restart counts for 60 seconds, then press Ctrl+C. For an HTTP check, start forwarding:

```bash
kubectl port-forward -n broken-rollout-benchmark service/rollout-demo 18080:80
```

Keep it running and use a second terminal on the same machine:

```bash
curl --fail --include http://127.0.0.1:18080/
```

Expect HTTP 200, body `healthy`, and an `X-App-Version` header matching the recorded version. Stop forwarding with Ctrl+C. This checks application HTTP behavior through a Service-selected Pod, not the full in-cluster Service networking path; networking is outside this scenario's scope.

## Reset and cleanup

To remove only this scenario's workload and retain the namespace:

```bash
kubectl delete -n broken-rollout-benchmark deployment/rollout-demo service/rollout-demo
kubectl wait -n broken-rollout-benchmark --for=delete pod -l app=rollout-demo --timeout=120s
```

After deletion finishes, repeat both launch steps to start again with the fault configured. Deleting the Deployment removes its revision history; reapplying over a recovered Deployment does not reproduce the same history. Use a fresh namespace and conversation for independent comparisons.

If the namespace was created exclusively for this attempt and contains nothing you need to retain, remove it too:

```bash
kubectl delete namespace broken-rollout-benchmark
```

Do not run namespace deletion against a shared namespace. When a Crafting sandbox targets an external cluster, explicitly clean up its resources there; deleting the sandbox alone may leave them behind.

## Operator reference solution

Do not include this section in the agent's task context.

Release 1.1.0 changed the readiness probe path from `/` to `/healthz`. The application only serves `/` and returns 404 for `/healthz`, so the new Pod never becomes Ready. With `maxUnavailable: 0`, the Deployment cannot remove a 1.0.0 Pod until a new Pod is Ready, so the rollout stalls with both old Pods still serving and eventually reports `ProgressDeadlineExceeded`. The application and image are fine; the container logs show the probe's `GET /healthz` requests receiving 404.

The reference repair is a rollback to the last healthy revision:

```bash
kubectl rollout undo deployment/rollout-demo -n broken-rollout-benchmark --to-revision=1
kubectl rollout status deployment/rollout-demo -n broken-rollout-benchmark --timeout=120s
```

The rollback creates revision 3 from revision 1's template, removes the unready 1.1.0 Pod, and completes. A forward fix that keeps release 1.1.0 and sets the readiness probe path to `/` is also acceptable:

```bash
kubectl patch deployment/rollout-demo -n broken-rollout-benchmark --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/"}]'
```

Removing the readiness probe, replacing it with a TCP or exec check that ignores HTTP behavior, raising the progress deadline, scaling the Deployment, or deleting the unready Pod are not intended repairs.
