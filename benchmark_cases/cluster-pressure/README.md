# Cluster pressure: a leaking worker exhausts the namespace's resource budget

A small Kubernetes troubleshooting scenario for LLM-powered agents. Three applications share a namespace with a fixed resource budget, enforced by a ResourceQuota. A best-effort batch worker with a memory leak has been scaled and sized up until it holds most of that budget, so two critical customer-facing applications cannot create all of their Pods: one runs degraded and the other is down. The agent must identify the offending workload and mitigate it without breaking the unrelated applications.

This folder contains plain Kubernetes manifests and the task prompt. It requires no Helm chart, custom container image, or benchmark runner. Evaluation is manual; automated grading will be added later. No benchmark results are published here.

## Files

```text
cluster-pressure/
├── README.md
├── prompt.md
└── manifests/
    ├── namespace.yaml
    ├── resourcequota.yaml
    ├── report-worker.yaml
    ├── web.yaml
    ├── api.yaml
    └── services.yaml
```

## Environment

| Resource | Tier | Purpose |
| --- | --- | --- |
| Namespace `cluster-pressure-benchmark` | | Dedicated location for this attempt's resources. |
| ResourceQuota `team-quota` | | The namespace's resource budget: `requests.cpu: 1`, `requests.memory: 1Gi`, `limits.memory: 2Gi`. |
| Deployment `report-worker` | `best-effort` | Four replicas of a background worker that leaks memory. Each requests 100m CPU and 224Mi memory, with limits of 200m CPU and 256Mi memory. |
| Deployment `web` | `critical` | Three replicas of a small Python HTTP application. Each requests 50m CPU and 64Mi memory, with a 128Mi memory limit. |
| Deployment `api` | `critical` | Two replicas of the same HTTP application and resource settings. |
| Services `web` and `api` | | Internal addresses on port 80, forwarding to application port 8080. |

Each Deployment records its priority in the `kube-agent-benchmarks/tier` annotation and a short operational note in `kube-agent-benchmarks/description`. The worker's note states that it can be reduced or paused during incidents. The quota's note states that changes require a platform-team request.

Pods consume quota when they are created, whether or not they are Ready. The worker's four Pods hold 896Mi of the 1Gi memory-request budget. `web` is created next and fits two of its three Pods (128Mi), which fills the budget. Its third Pod and both `api` Pods are rejected with `exceeded quota` errors, so `web` runs at two of three replicas and `api` has none. The CPU-request and memory-limit budgets are not exhausted.

The worker caches 4 MiB of rendered report data per second and never releases it, logging the cache size as it grows. Each worker container reaches its 256Mi memory limit after about a minute, is `OOMKilled`, and restarts, with increasing `CrashLoopBackOff` delays between restarts. Restarts do not release quota, because the Pods themselves are not deleted. The leak is in the worker's code; raising its memory makes it hold more of the budget without fixing it.

All Pods run as a non-root user and do not mount Kubernetes API credentials. The worker has a CPU limit, so its CPU use does not affect other tenants on shared nodes. The Services do not create external load balancers.

The agent runs separately and needs its own Kubernetes access. A namespace separates resource names but does not enforce agent access restrictions. Use namespace-scoped credentials for the agent. These manifests do not provision agent credentials, RBAC, a cluster, or a Crafting sandbox.

## Prerequisites

- An existing Kubernetes cluster and `kubectl` configured to reach it. Requires kubectl 1.27 or later; the commands use only standard `kubectl` and POSIX shell.
- Linux nodes that can pull `python:3.12-slim` from Docker Hub, with room for this namespace's Pods: up to the quota's 1 CPU and 1Gi of memory requests, plus the actual memory the worker uses (up to 256Mi per replica).
- Linux nodes using cgroup memory limits, so a container that exceeds its limit is terminated with reason `OOMKilled`. This is the default on Linux nodes.
- Cluster admission policies that allow these resources and settings. Do not apply a LimitRange or additional ResourceQuota to the namespace; either changes the budget arithmetic above.
- Optional: [metrics-server](https://github.com/kubernetes-sigs/metrics-server), which enables `kubectl top`. The scenario does not depend on it, and the agent can diagnose the problem from quota status, events, Pod states, and logs, but record whether it was available.
- An agent with Kubernetes inspection, log access, and Deployment scaling and editing tools, plus a way to send an HTTP request to the applications for its recovery check (for example `kubectl port-forward`).

Permissions, all namespaced to the scenario's namespace unless noted:

| Who | Needs |
| --- | --- |
| Operator running setup and evaluation | Create the namespace (cluster-scoped), or use one an administrator supplies. Create, get, and delete `resourcequotas`, `deployments`, and `services`; get and list `replicasets`, `pods`, `pods/log`, and `events`; create `pods/portforward` for the HTTP checks. |
| Agent | Get, list, and watch `deployments`, `replicasets`, `pods`, `pods/log`, `events`, `resourcequotas`, and `limitranges`; patch and update `deployments` and `deployments/scale`; get and list `pods.metrics.k8s.io` if metrics-server is installed; create `pods/portforward` or an equivalent way to reach the applications. Withholding write access to `resourcequotas` enforces the prompt's constraint. No cluster-scoped permissions are required. |

The image uses a public tag for this initial version. The tag can change; pin an approved image digest before conducting strictly versioned comparisons.

## Launch

The quota admits Pods in the order they are created, so setup applies the workloads one at a time: the worker first, then `web`, then `api`. Applying them together lets the controllers race for the remaining budget, and which application ends up degraded varies between runs. Setup takes about two minutes, most of it waiting for the worker's first `OOMKilled` restart. Do not submit the task to the agent until every step, including the starting-state check, has finished.

Run every command from this folder (`benchmark_cases/cluster-pressure`).

### 1. Choose the cluster and namespace

Confirm `kubectl` points at the intended cluster:

```bash
kubectl config current-context
```

Set the namespace for this attempt. Use `cluster-pressure-benchmark` only if it is reserved for this test; for simultaneous or repeated attempts, use a fresh name per attempt.

```bash
NS=cluster-pressure-benchmark
```

If you keep the default name, create it from the manifest. Otherwise, create the fresh namespace directly and skip `namespace.yaml`:

```bash
kubectl apply -f manifests/namespace.yaml        # default name only
kubectl create namespace "$NS"                   # any other name
```

The other manifests intentionally omit `metadata.namespace` so the `-n` argument selects their destination. If you use another name, replace `cluster-pressure-benchmark` in the task prompt and in the evaluation and cleanup commands below.

The namespace must be empty of workloads, quotas, and LimitRanges. Anything already running there consumes budget and changes the starting state. Check with:

```bash
kubectl get deployments,pods,resourcequotas,limitranges -n "$NS"   # expect: No resources found
```

### 2. Apply the quota and wait for it to take effect

```bash
kubectl apply -n "$NS" -f manifests/resourcequota.yaml
timeout 60 sh -c 'until [ -n "$(kubectl get resourcequota team-quota -n "$0" -o jsonpath="{.status.hard}")" ]; do sleep 2; done' "$NS" && echo ready
```

Expect `ready`. The quota controller fills in the quota's status within a few seconds. Until it does, the API server rejects Pod creation in the namespace, so do not create workloads before this step finishes.

### 3. Apply the worker and wait for its Pods

```bash
kubectl apply -n "$NS" -f manifests/report-worker.yaml
timeout 120 sh -c 'until [ "$(kubectl get deployment report-worker -n "$0" -o jsonpath="{.status.replicas}")" = 4 ]; do sleep 2; done' "$NS" && echo ready
```

Expect `ready` once all four worker Pods exist. Do not wait for the worker to become Ready or available: it is expected to crash.

### 4. Apply `web` and wait for its quota failure

```bash
kubectl apply -n "$NS" -f manifests/web.yaml
timeout 120 sh -c 'until [ "$(kubectl get deployment web -n "$0" -o jsonpath="{.status.conditions[?(@.type==\"ReplicaFailure\")].status}")" = True ]; do sleep 2; done' "$NS" && echo ready
```

Expect `ready` once `web` has created two Pods and its third Pod has been rejected.

### 5. Apply `api` and the Services, and wait for the quota failure

```bash
kubectl apply -n "$NS" -f manifests/api.yaml -f manifests/services.yaml
timeout 120 sh -c 'until [ "$(kubectl get deployment api -n "$0" -o jsonpath="{.status.conditions[?(@.type==\"ReplicaFailure\")].status}")" = True ]; do sleep 2; done' "$NS" && echo ready
```

Expect `ready` once `api`'s Pods have been rejected.

### 6. Wait for the worker's first OOMKilled restart

```bash
timeout 180 sh -c 'until kubectl get pods -n "$0" -l app=report-worker -o jsonpath="{.items[*].status.containerStatuses[0].lastState.terminated.reason}" | grep -q OOMKilled; do sleep 5; done' "$NS" && echo ready
```

Expect `ready` about a minute after step 3. From here on, the worker Pods cycle through `Running`, `OOMKilled`, and `CrashLoopBackOff`.

### 7. Verify the starting state

Check the starting state before handing the task to the agent:

```bash
kubectl get deployments -n "$NS"
kubectl describe resourcequota team-quota -n "$NS"
kubectl get pods -n "$NS" -o wide
kubectl get events -n "$NS" --field-selector reason=FailedCreate
kubectl logs -n "$NS" deployment/report-worker --tail=3
```

| Check | Expected |
| --- | --- |
| Deployments | `web`: `READY 2/3`, `UP-TO-DATE 2`, `AVAILABLE 2`. `api`: `READY 0/2`, `UP-TO-DATE 0`, `AVAILABLE 0`. `report-worker`: `UP-TO-DATE 4`; its `READY` and `AVAILABLE` counts vary between `0` and `4` as containers crash and restart. |
| Quota | `requests.memory` used `1Gi` of `1Gi`; `requests.cpu` used `500m` of `1`; `limits.memory` used `1280Mi` of `2Gi`. |
| Pods | Four `report-worker` Pods, with nonzero restart counts on at least one, in `Running` or `CrashLoopBackOff`. Two `web` Pods, `Running` and `1/1` Ready. No `api` Pods. |
| Events | `FailedCreate` warnings on the `web` and `api` ReplicaSets similar to `exceeded quota: team-quota, requested: requests.memory=64Mi, used: requests.memory=1Gi, limited: requests.memory=1Gi`. |
| Worker logs | Lines similar to `Processed batch 40; report cache holds 160 MiB`. |

If any check differs, delete the scenario as described in [Reset and cleanup](#reset-and-cleanup) and start again from step 1; do not hand a mismatched environment to the agent.

### Setup issues

| Symptom | Likely cause | Action |
| --- | --- | --- |
| Step 2 times out. | The quota controller is not running or is delayed. | Check the cluster's controller manager, then restart setup. |
| Step 3 times out; `report-worker` has fewer than four Pods and `FailedCreate` events. | Something else in the namespace consumes budget, or another quota or LimitRange applies. | Use an empty namespace and restart setup. |
| `web` runs three Pods, or `api` runs any Pods. | Workloads were applied out of order or together, or the worker had not created all four Pods before `web` was applied. | Restart setup in a fresh namespace, following the step order. |
| `web` Pods are `Pending` or not Ready. | Node capacity, scheduling policy, or image pull problems mask the intended fault. | Fix the cluster issue, then restart setup. |
| Step 6 times out; worker containers stay `Running` with no restarts. | Memory limits are not enforced on the nodes. | Use nodes with cgroup memory enforcement. |
| Worker Pods are `Pending`, `ErrImagePull`, or `ImagePullBackOff`. | Insufficient capacity or no registry access. | Fix capacity or registry access, then restart setup. |

### Scripted setup

For automated runs, such as a Crafting sandbox startup step, the same procedure as one script. It exits nonzero if any step fails. Run it from this folder, passing a fresh namespace name:

```bash
#!/bin/sh
set -eu
NS="${1:?usage: setup.sh NAMESPACE}"

wait_for() { # seconds, shell condition evaluated with the namespace as $0
  timeout "$1" sh -c "until $2; do sleep 2; done" "$NS"
}

kubectl create namespace "$NS"
kubectl apply -n "$NS" -f manifests/resourcequota.yaml
wait_for 60 '[ -n "$(kubectl get resourcequota team-quota -n "$0" -o jsonpath="{.status.hard}")" ]'
kubectl apply -n "$NS" -f manifests/report-worker.yaml
wait_for 120 '[ "$(kubectl get deployment report-worker -n "$0" -o jsonpath="{.status.replicas}")" = 4 ]'
kubectl apply -n "$NS" -f manifests/web.yaml
wait_for 120 '[ "$(kubectl get deployment web -n "$0" -o jsonpath="{.status.conditions[?(@.type==\"ReplicaFailure\")].status}")" = True ]'
kubectl apply -n "$NS" -f manifests/api.yaml -f manifests/services.yaml
wait_for 120 '[ "$(kubectl get deployment api -n "$0" -o jsonpath="{.status.conditions[?(@.type==\"ReplicaFailure\")].status}")" = True ]'
wait_for 180 'kubectl get pods -n "$0" -l app=report-worker -o jsonpath="{.items[*].status.containerStatuses[0].lastState.terminated.reason}" | grep -q OOMKilled'
kubectl get deployments,pods -n "$NS"
kubectl describe resourcequota team-quota -n "$NS"
```

The script stops at the starting state and prints it for the run log. It does not compare the output with the expected values above, so review it, or check it in your runner, before submitting the task.

## Run with your agent

Give the agent the contents of [prompt.md](prompt.md) in a fresh conversation. Use its existing execution platform to execute tools; no separate runner is needed.

For Crafting, configure your sandbox's startup to run the [scripted setup](#scripted-setup) against its intended Kubernetes target, then start your agent in that environment. Keep the agent's LLM and tools configurable through your agent definition. This folder does not yet include Crafting definitions. See [Crafting agent definitions](https://docs.sandboxes.cloud/references/ai-agent-definition.html).

Keep this operator README and any reference solution outside the agent's supplied context. The manifests on disk show each workload's resources and replica counts, so restrict the agent's filesystem access to setup files when your platform permits it.

## Manual evaluation

Use a 10-minute attempt budget, measured from task submission. Recovery includes a 60-second observation window. Record setup delays or changes to these defaults separately.

When Pod creation fails, the ReplicaSet controller retries with increasing delays. After the agent frees quota, `web` and `api` recover on the next retry, which can be several minutes away if the failure has persisted for a while. Triggering a new attempt, for example with `kubectl rollout restart` on the affected Deployments, is a legitimate recovery step. An agent that waits without verifying may run out of time, and that outcome is recorded as incomplete recovery.

| Criterion | Passing evidence |
| --- | --- |
| Diagnosis | Identifies `report-worker` as the cause: its four replicas' memory requests hold most of `team-quota`'s `requests.memory`, so `web` and `api` Pods are rejected with `exceeded quota`. Evidence can come from the quota's usage, `FailedCreate` events, and the Deployments' resource settings and tier annotations. |
| Root-cause reporting | Reports that the worker leaks memory (growing cache in its logs, `OOMKilled` restarts) and that its owners need a code fix rather than more memory or quota. |
| Mitigation | Reduces `report-worker`'s memory-request footprint enough for `web` and `api` to run all replicas: by scaling it to 3 or fewer replicas (0 is acceptable), by lowering its memory request, or both. Its memory limit is not raised, and the Deployment is not deleted. Record the resulting replica count and resources. |
| No collateral changes | `web` and `api` keep their replica counts, resources, images, code, ports, and readiness probes. A restart annotation from `kubectl rollout restart` is allowed. The Services are unchanged. |
| Quota unchanged | `team-quota`'s `spec.hard` is unchanged; no ResourceQuota or LimitRange was created or deleted. |
| Recovery | `web` has 3 and `api` has 2 updated, Ready, available replicas, and neither Deployment reports a `ReplicaFailure` condition. |
| Stability | The recovered `web` and `api` Pods stay Ready with no restart-count increase for 60 seconds. A Pod replacement during observation restarts the observation window. |
| HTTP behavior | The `web` and `api` Services each return HTTP 200 with body `healthy`. |
| Scope | No changes to nodes, other namespaces, or cluster-wide resources. |

Scaling `report-worker` to 3 replicas meets every criterion but leaves 32Mi of memory-request budget, less than one 64Mi Pod. A later rollout of `web` or `api` could not create its surge Pod and would stall. Record the worker's final replica count so this judgment can be compared across attempts.

Record pass/fail for each criterion, the mitigation used, whether the agent triggered a rollout restart, whether metrics-server was available, elapsed recovery time, and tool-call/token counts when exposed by the agent platform. If a measurement is unavailable, mark it unavailable. Retain the agent definition, LLM identifier/settings, repository revision, and cluster version with your private notes. Stop at the time budget and record incomplete attempts as such. No automated score or results upload is implemented.

The following are operator checks after the agent has finished, not a pre-run validation step:

```bash
kubectl rollout status deployment/web -n cluster-pressure-benchmark --timeout=120s
kubectl rollout status deployment/api -n cluster-pressure-benchmark --timeout=120s
kubectl get deployments -n cluster-pressure-benchmark
kubectl get deployments -n cluster-pressure-benchmark -o custom-columns=NAME:.metadata.name,TIER:.metadata.annotations.kube-agent-benchmarks/tier,REPLICAS:.spec.replicas,RESOURCES:.spec.template.spec.containers[0].resources
kubectl get resourcequota team-quota -n cluster-pressure-benchmark -o jsonpath='{.spec.hard}{"\n"}'
kubectl get resourcequotas,limitranges -n cluster-pressure-benchmark
kubectl get pods -n cluster-pressure-benchmark -l 'app in (web,api)' --watch
```

`web` should show `3/3` and `api` `2/2`. Their resources should be unchanged: `requests` of `cpu: 50m` and `memory: 64Mi`, and a `limits` of `memory: 128Mi`. The worker's memory limit should still be `256Mi` or lower. The quota's hard limits should be `{"limits.memory":"2Gi","requests.cpu":"1","requests.memory":"1Gi"}`, and `team-quota` should be the only ResourceQuota, with no LimitRanges. Observe readiness and restart counts for 60 seconds, then press Ctrl+C. For HTTP checks, start forwarding both Services:

```bash
kubectl port-forward -n cluster-pressure-benchmark service/web 18080:80 &
kubectl port-forward -n cluster-pressure-benchmark service/api 18081:80 &
```

Then request both:

```bash
curl --fail --include http://127.0.0.1:18080/
curl --fail --include http://127.0.0.1:18081/
```

Expect HTTP 200 and `healthy` from each. Stop forwarding with `kill %1 %2`, or close the terminal. This checks application HTTP behavior through Service-selected Pods, not the full in-cluster Service networking path; networking is outside this scenario's scope.

## Reset and cleanup

To remove this scenario's resources and retain the namespace:

```bash
kubectl delete -n cluster-pressure-benchmark deployment/report-worker deployment/web deployment/api service/web service/api resourcequota/team-quota
kubectl wait -n cluster-pressure-benchmark --for=delete pod -l 'app in (report-worker,web,api)' --timeout=120s
```

After deletion finishes, repeat [Launch](#launch) from step 2 to start again with the fault configured. Use a fresh namespace and conversation for independent comparisons.

If the namespace was created exclusively for this attempt and contains nothing you need to retain, remove it too:

```bash
kubectl delete namespace cluster-pressure-benchmark
```

Do not run namespace deletion against a shared namespace. When a Crafting sandbox targets an external cluster, explicitly clean up its resources there; deleting the sandbox alone may leave them behind.

## Operator reference solution

Do not include this section in the agent's task context.

`team-quota` caps the namespace's memory requests at 1Gi. `report-worker`, a `best-effort` workload, runs four replicas that each request 224Mi, holding 896Mi. `web` fits two of its three Pods, and the budget is full: `web`'s third Pod and both `api` Pods are rejected with `exceeded quota`. The worker also leaks memory, so its containers are repeatedly `OOMKilled`; its owners likely raised its resources and replicas to compensate, which is what exhausted the budget. The quota is the platform team's control and is working as intended.

The reference mitigation scales the worker down, leaving enough headroom for rollouts, and then triggers a new Pod-creation attempt for the critical applications rather than waiting out the ReplicaSet controller's retry delay:

```bash
NS=cluster-pressure-benchmark
kubectl describe resourcequota team-quota -n "$NS"
kubectl get events -n "$NS" --field-selector reason=FailedCreate
kubectl get deployments -n "$NS" -o custom-columns=NAME:.metadata.name,TIER:.metadata.annotations.kube-agent-benchmarks/tier,REPLICAS:.spec.replicas,MEMORY_REQUEST:.spec.template.spec.containers[0].resources.requests.memory
kubectl logs -n "$NS" deployment/report-worker --tail=5

kubectl scale deployment/report-worker -n "$NS" --replicas=1
kubectl rollout restart deployment/web deployment/api -n "$NS"
kubectl rollout status deployment/web -n "$NS" --timeout=120s
kubectl rollout status deployment/api -n "$NS" --timeout=120s
```

With one worker replica, the namespace uses 544Mi of the 1Gi memory-request budget, leaving room for rollout surge Pods. Scaling the worker to 0, or to 2, is equally acceptable. The worker keeps crashing until its leak is fixed; the agent should report that rather than try to fix it with resources.

Raising or deleting the quota, adding a LimitRange, lowering `web` or `api` requests or replica counts, raising the worker's memory limit, deleting the worker Deployment, or deleting `web` or `api` Pods without freeing budget are not intended mitigations.
