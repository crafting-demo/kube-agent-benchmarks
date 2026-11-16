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

- An existing Kubernetes cluster (any conformant distribution) and `kubectl` configured to reach it. Requires kubectl 1.27 or later; the commands use only standard `kubectl` and POSIX shell.
- Linux nodes that can pull `python:3.12-slim` from Docker Hub, with room for three of these Pods at once (150 millicores of CPU and 96 MiB of memory requested) during the rollout.
- Cluster admission policies that allow these resources and settings. Do not apply a ResourceQuota or LimitRange to the namespace that would prevent the third, surge Pod from being created, and do not run admission webhooks that rewrite readiness probes; either changes the starting state.
- An agent with Kubernetes inspection, log access, and Deployment editing or rollout tools, plus a way to send an HTTP request to the application for its recovery check (for example `kubectl port-forward`).

Permissions, all namespaced to the scenario's namespace unless noted:

| Who | Needs |
| --- | --- |
| Operator running setup and evaluation | Create the namespace (cluster-scoped), or use one an administrator supplies. Create, get, and patch `deployments` and `services`; get and list `replicasets`, `pods`, `pods/log`, and `events`; create `pods/portforward` for the HTTP check; delete for cleanup. |
| Agent | Get, list, and watch `deployments`, `replicasets`, `pods`, `pods/log`, and `events`; patch and update `deployments` (`kubectl rollout undo` reads the ReplicaSets and patches the Deployment); create `pods/portforward` or an equivalent way to reach the application. No cluster-scoped permissions are required. |

The image uses a public tag for this initial version. The tag can change; pin an approved image digest before conducting strictly versioned comparisons.

## Launch

A failed rollout needs a healthy revision to fail from, so setup installs release 1.0.0, waits for it to become healthy, applies release 1.1.0, and waits for the Deployment to report the failure. Setup takes about three to five minutes, mostly the 120-second progress deadline and the first image pull. Do not submit the task to the agent until every step, including the starting-state check, has finished.

Run every command from this folder (`benchmark_cases/broken-rollout`).

### 1. Choose the cluster and namespace

Confirm `kubectl` points at the intended cluster:

```bash
kubectl config current-context
```

Set the namespace for this attempt. Use `broken-rollout-benchmark` only if it is reserved for this test; for simultaneous or repeated attempts, use a fresh name per attempt.

```bash
NS=broken-rollout-benchmark
```

If you keep the default name, create it from the manifest. Otherwise, create the fresh namespace directly and skip `namespace.yaml`:

```bash
kubectl apply -f manifests/namespace.yaml        # default name only
kubectl create namespace "$NS"                   # any other name
```

The Deployment and Service intentionally omit `metadata.namespace` so the `-n` argument selects their destination. If you use another name, replace `broken-rollout-benchmark` in the task prompt and in the evaluation and cleanup commands below.

The namespace must not already contain a `rollout-demo` Deployment. Applying over an existing one, even a deleted-and-recreated one that has not finished terminating, changes the revision history the scenario depends on. Check with:

```bash
kubectl get deployment rollout-demo -n "$NS"     # expect: NotFound
```

### 2. Install release 1.0.0 and wait until it is healthy

```bash
kubectl apply -n "$NS" -f manifests/deployment-v1.yaml -f manifests/service.yaml
kubectl rollout status deployment/rollout-demo -n "$NS" --timeout=300s
```

Expect `deployment "rollout-demo" successfully rolled out`. The timeout allows for the first pull of `python:3.12-slim`; if the image is already cached on the nodes, this takes a few seconds. Do not continue until this succeeds. Applying release 1.1.0 while 1.0.0 is still rolling out produces a different, unintended starting state.

### 3. Apply the faulty release 1.1.0

Apply it with `kubectl apply` so it updates the existing Deployment in place and creates revision 2. Do not use `kubectl replace --force`, `kubectl create`, or delete the Deployment first; those discard revision 1.

```bash
kubectl apply -n "$NS" -f manifests/deployment-v2.yaml
```

Do not run `kubectl rollout status` here without a timeout: this rollout never completes.

### 4. Wait for the progress deadline

The Deployment reports the failure about 120 seconds after the new Pod is created, occasionally a little later because the controller checks the deadline periodically. Wait for it so every attempt starts from the same state:

```bash
timeout 240 sh -c 'until [ "$(kubectl get deployment rollout-demo -n "$0" -o jsonpath="{.status.conditions[?(@.type==\"Progressing\")].reason}")" = ProgressDeadlineExceeded ]; do sleep 5; done' "$NS" && echo ready
```

Expect `ready`. If the command times out, see [Setup issues](#setup-issues).

### 5. Verify the starting state

Check the starting state before handing the task to the agent:

```bash
kubectl get deployment rollout-demo -n "$NS"
kubectl get replicasets -n "$NS" -l app=rollout-demo
kubectl get pods -n "$NS" -l app=rollout-demo \
  -o custom-columns=NAME:.metadata.name,VERSION:.spec.containers[0].env[0].value,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount,PHASE:.status.phase
kubectl rollout history deployment/rollout-demo -n "$NS"
kubectl get events -n "$NS" --field-selector reason=Unhealthy
```

| Check | Expected |
| --- | --- |
| Deployment | `READY 2/2`, `UP-TO-DATE 1`, `AVAILABLE 2`. |
| ReplicaSets | Two. The 1.0.0 ReplicaSet has `DESIRED 2`, `CURRENT 2`, `READY 2`. The 1.1.0 ReplicaSet has `DESIRED 1`, `CURRENT 1`, `READY 0`. |
| Pods | Three, all `Running`. Two with version `1.0.0` and `READY true`; one with version `1.1.0` and `READY false`. All restart counts are `0`. |
| Rollout history | Revision `1` with `Release 1.0.0` and revision `2` with `Release 1.1.0`. |
| Events | `Unhealthy` warnings on the 1.1.0 Pod: `Readiness probe failed: HTTP probe failed with statuscode: 404`. |
| Progressing condition | `False` with reason `ProgressDeadlineExceeded` (step 4). The `Available` condition stays `True`. |

ReplicaSet and Pod names include generated hashes and differ between runs. If any check differs, delete the scenario as described in [Reset and cleanup](#reset-and-cleanup) and start again from step 1; do not hand a mismatched environment to the agent.

### Setup issues

| Symptom | Likely cause | Action |
| --- | --- | --- |
| Step 2 times out; Pods show `ErrImagePull` or `ImagePullBackOff`. | Nodes cannot reach Docker Hub, or are rate-limited. | Fix registry access or pre-pull the image, then restart setup. |
| Step 2 times out; Pods are `Pending`. | Insufficient node capacity, or a quota or policy blocks the Pods. | Free capacity or adjust the namespace policy, then restart setup. |
| The 1.1.0 Pod is never created after step 3. | A ResourceQuota or LimitRange blocks the surge Pod. | Remove the restriction from this namespace and restart setup. |
| The 1.1.0 Pod becomes Ready, or crashes, or fails for a reason other than a 404 readiness probe. | The wrong manifest was applied, or an admission webhook changed the Pod. | Confirm `deployment-v2.yaml` was applied unmodified, then restart setup. |
| Rollout history shows only one revision, or more than two. | Release 1.1.0 was applied without release 1.0.0 first, the Deployment was recreated, or a release was applied more than once with changes. | Restart setup in a fresh namespace. |
| Step 4 times out with `Progressing` still `True`. | The rollout is not stalled as intended. | Inspect the 1.1.0 Pod and its events; restart setup. |

### Scripted setup

For automated runs, such as a Crafting sandbox startup step, the same procedure as one script. It exits nonzero if any step fails. Run it from this folder, passing a fresh namespace name:

```bash
#!/bin/sh
set -eu
NS="${1:?usage: setup.sh NAMESPACE}"

kubectl create namespace "$NS"
kubectl apply -n "$NS" -f manifests/deployment-v1.yaml -f manifests/service.yaml
kubectl rollout status deployment/rollout-demo -n "$NS" --timeout=300s
kubectl apply -n "$NS" -f manifests/deployment-v2.yaml
timeout 240 sh -c 'until [ "$(kubectl get deployment rollout-demo -n "$0" -o jsonpath="{.status.conditions[?(@.type==\"Progressing\")].reason}")" = ProgressDeadlineExceeded ]; do sleep 5; done' "$NS"
kubectl get deployment,replicasets,pods -n "$NS" -l app=rollout-demo
kubectl rollout history deployment/rollout-demo -n "$NS"
```

The script stops at the starting state and prints it for the run log. It does not compare the output with the expected values above, so review it, or check it in your runner, before submitting the task.

## Run with your agent

Give the agent the contents of [prompt.md](prompt.md) in a fresh conversation. Use its existing execution platform to execute tools; no separate runner is needed.

For Crafting, configure your sandbox's startup to run the [scripted setup](#scripted-setup) against its intended Kubernetes target, then start your agent in that environment. Keep the agent's LLM and tools configurable through your agent definition. This folder does not yet include Crafting definitions. See [Crafting agent definitions](https://docs.sandboxes.cloud/references/ai-agent-definition.html).

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

After deletion finishes, repeat [Launch](#launch) from step 2 to start again with the fault configured. Deleting the Deployment removes its revision history; reapplying over a recovered Deployment does not reproduce the same history. Use a fresh namespace and conversation for independent comparisons.

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
