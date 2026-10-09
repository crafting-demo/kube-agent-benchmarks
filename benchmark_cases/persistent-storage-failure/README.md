# Persistent storage failure: claim requests a missing StorageClass

A small Kubernetes troubleshooting scenario for LLM-powered agents. A single-replica StatefulSet keeps its data on a PersistentVolumeClaim that requests a StorageClass the cluster does not have. The claim is never provisioned, so the Pod cannot be scheduled and never starts. The agent must diagnose the storage failure and restore the workload without risking stored data.

This folder contains plain Kubernetes manifests and the task prompt. It requires no Helm chart, custom container image, benchmark runner, or separate fault injection step. Evaluation is manual; automated grading will be added later. No benchmark results are published here.

## Files

```text
persistent-storage-failure/
├── README.md
├── prompt.md
└── manifests/
    ├── namespace.yaml
    ├── pvc.yaml
    ├── statefulset.yaml
    └── service.yaml
```

## Environment

| Resource | Purpose |
| --- | --- |
| Namespace `persistent-storage-benchmark` | Dedicated location for this attempt's resources. |
| PersistentVolumeClaim `store-demo-data` | 1Gi `ReadWriteOnce` claim for the application's data. Requests StorageClass `fast-ssd`. |
| StatefulSet `store-demo` | Manages one Pod, `store-demo-0`, running a small Python HTTP application that mounts `store-demo-data` at `/data`. |
| Service `store-demo` | Internal address on port 80, forwarding to application port 8080. Also the StatefulSet's governing Service. |

The claim requests `storageClassName: fast-ssd`, a class name carried over from another cluster that does not exist in this one. The persistent volume controller cannot provision a volume for it, so the claim stays `Pending`, and the scheduler cannot place a Pod whose claim is unbound. No image is pulled and no container starts. A claim's StorageClass cannot be changed after creation, so recovery requires replacing the claim.

At startup the application increments a boot counter stored in `/data/boot-count`, and exits if `/data` is not writable. On `/` it writes a small check file to `/data` and returns HTTP 200 with body `healthy` and an `X-Boot-Count` header, or HTTP 503 if the write fails. Every other path returns 404. The readiness probe checks `/`, so a Ready Pod has writable storage. Because the counter lives on the volume, it increases across Pod restarts only when the storage is persistent.

The StatefulSet references the claim through its Pod template's `volumes`, not through `volumeClaimTemplates`, so the claim can be replaced without changing the StatefulSet. The Pod requests 50 millicores of CPU and 32 MiB of memory; its memory limit is 128 MiB. It runs as a non-root user (UID and GID 10001) with `fsGroup: 10001`, and does not mount Kubernetes API credentials. The Service does not create an external load balancer.

The agent runs separately and needs its own Kubernetes access. A namespace separates resource names but does not enforce agent access restrictions. Use namespace-scoped credentials for the agent, plus read-only access to StorageClasses. These manifests do not provision agent credentials, RBAC, a cluster, or a Crafting sandbox.

## Prerequisites

- An existing Kubernetes cluster and `kubectl` configured to reach it. Requires kubectl 1.27 or later; the commands use only standard `kubectl` and POSIX shell.
- Exactly one default StorageClass, backed by a dynamic provisioner that can create a 1Gi `ReadWriteOnce` volume. Either volume binding mode (`Immediate` or `WaitForFirstConsumer`) works.
- Volumes from the default StorageClass must be writable by the Pod's `fsGroup` (10001): either the provisioner applies `fsGroup` ownership, as block-storage CSI drivers do, or it creates world-writable directories, as local-path provisioners do.
- No StorageClass named `fast-ssd`. If one exists, the claim provisions and the fault does not occur.
- Linux nodes that can pull `python:3.12-slim` from Docker Hub, with 50 millicores of CPU and 32 MiB of memory available.
- Cluster admission policies that allow these resources and settings. Do not apply a ResourceQuota or LimitRange to the namespace that would block the claim or the Pod.
- An agent with Kubernetes inspection tools, permission to read StorageClasses and PersistentVolumes, and permission to manage PersistentVolumeClaims and scale the StatefulSet in the scenario's namespace, plus a way to send an HTTP request to the application for its recovery check (for example `kubectl port-forward`).

Permissions, namespaced to the scenario's namespace unless noted:

| Who | Needs |
| --- | --- |
| Operator running setup and evaluation | Create the namespace (cluster-scoped), or use one an administrator supplies. Create, get, and delete `persistentvolumeclaims`, `statefulsets`, and `services`; get and list `pods`, `pods/log`, and `events`; delete `pods` for the persistence check; create `pods/portforward` for the HTTP check; get and list `storageclasses` and `persistentvolumes` (cluster-scoped, read-only); delete `persistentvolumes` (cluster-scoped) for cleanup when the default StorageClass retains volumes. |
| Agent | Get, list, and watch `statefulsets`, `pods`, `pods/log`, `events`, and `persistentvolumeclaims`; create and delete `persistentvolumeclaims`; patch and update `statefulsets` and `statefulsets/scale`; get and list `storageclasses` and `persistentvolumes` (cluster-scoped, read-only); create `pods/portforward` or an equivalent way to reach the application. |

The image uses a public tag for this initial version. The tag can change; pin an approved image digest before conducting strictly versioned comparisons.

## Launch

The manifests contain the fault from the first apply: there is no healthy-first installation and no injection step. Setup takes under a minute. Do not submit the task to the agent until every step, including the starting-state check, has finished.

Run every command from this folder (`benchmark_cases/persistent-storage-failure`).

### 1. Check the cluster's storage

Confirm `kubectl` points at the intended cluster, then check its StorageClasses:

```bash
kubectl config current-context
kubectl get storageclass
kubectl get storageclass fast-ssd                # expect: NotFound
```

Exactly one StorageClass must be marked `(default)`, and none may be named `fast-ssd`. Note the default class's name, provisioner, and `RECLAIMPOLICY`; record the name and provisioner with your run notes, and use the reclaim policy during [cleanup](#reset-and-cleanup).

### 2. Choose the namespace

Set the namespace for this attempt. Use `persistent-storage-benchmark` only if it is reserved for this test; for simultaneous or repeated attempts, use a fresh name per attempt.

```bash
NS=persistent-storage-benchmark
```

If you keep the default name, create it from the manifest. Otherwise, create the fresh namespace directly and skip `namespace.yaml`:

```bash
kubectl apply -f manifests/namespace.yaml        # default name only
kubectl create namespace "$NS"                   # any other name
```

The workload manifests intentionally omit `metadata.namespace` so the `-n` argument selects their destination. If you use another name, replace `persistent-storage-benchmark` in the task prompt and in the evaluation and cleanup commands below.

The namespace must not already contain this scenario's resources. A leftover `store-demo-data` claim, especially a bound one from an earlier attempt, changes the starting state. Check with:

```bash
kubectl get statefulset,pvc,service -n "$NS"     # expect: No resources found
```

### 3. Apply the manifests

```bash
kubectl apply -n "$NS" -f manifests/pvc.yaml -f manifests/statefulset.yaml -f manifests/service.yaml
```

Do not run `kubectl rollout status` here without a timeout: the StatefulSet never becomes Ready until the fault is repaired.

### 4. Wait for the failure to surface

The persistent volume controller records a provisioning failure on the claim within a few seconds. Wait for it and for the Pod so every attempt starts from the same state:

```bash
timeout 120 sh -c 'until [ -n "$(kubectl get events -n "$0" --field-selector involvedObject.kind=PersistentVolumeClaim,involvedObject.name=store-demo-data,reason=ProvisioningFailed -o name)" ] && kubectl get pod store-demo-0 -n "$0" >/dev/null 2>&1; do sleep 5; done' "$NS" && echo ready
```

Expect `ready`. If the command times out, see [Setup issues](#setup-issues).

### 5. Verify the starting state

Check the starting state before handing the task to the agent:

```bash
kubectl get pvc store-demo-data -n "$NS"
kubectl get statefulset store-demo -n "$NS"
kubectl get pod store-demo-0 -n "$NS" -o wide
kubectl get events -n "$NS" --field-selector involvedObject.name=store-demo-data
kubectl get events -n "$NS" --field-selector involvedObject.name=store-demo-0
```

| Check | Expected |
| --- | --- |
| PersistentVolumeClaim | `STATUS Pending`, `STORAGECLASS fast-ssd`, empty `VOLUME`. |
| Claim events | `ProvisioningFailed` warning similar to `storageclass.storage.k8s.io "fast-ssd" not found`. |
| StatefulSet | `READY 0/1`. |
| Pod | `store-demo-0` is `Pending` with `NODE <none>` and `0/1` Ready. |
| Pod events | `FailedScheduling` warning similar to `0/3 nodes are available: pod has unbound immediate PersistentVolumeClaims`. Node counts vary by cluster. |

If any check differs, delete the scenario as described in [Reset and cleanup](#reset-and-cleanup) and start again from step 1; do not hand a mismatched environment to the agent.

### Setup issues

| Symptom | Likely cause | Action |
| --- | --- | --- |
| The claim becomes `Bound` and the Pod starts. | The cluster has a StorageClass named `fast-ssd`. | Use a cluster without that class. |
| The claim is never created, or is rejected at apply. | A ResourceQuota, LimitRange, or admission policy blocks it. | Remove the restriction from this namespace and restart setup. |
| The Pod is never created. | A ResourceQuota or policy blocks the Pod. | Remove the restriction from this namespace and restart setup. |
| The Pod's `FailedScheduling` event cites only CPU, memory, taints, or node affinity. | Node capacity or scheduling policy problems mask the intended fault. | Free capacity or adjust scheduling policy, then restart setup. |
| `kubectl get storageclass` shows no default class, or several. | The cluster's storage is not configured for this scenario. | Configure exactly one default StorageClass before setup; without one, the intended repair cannot succeed. |

### Scripted setup

For automated runs, such as a Crafting sandbox startup step, the same procedure as one script. It exits nonzero if a prerequisite is missing or a step fails. Run it from this folder, passing a fresh namespace name:

```bash
#!/bin/sh
set -eu
NS="${1:?usage: setup.sh NAMESPACE}"

if kubectl get storageclass fast-ssd >/dev/null 2>&1; then
  echo "StorageClass fast-ssd exists; the fault would not occur" >&2
  exit 1
fi
defaults=$(kubectl get storageclass -o jsonpath='{range .items[*]}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' | grep -c '^true$' || true)
if [ "$defaults" -ne 1 ]; then
  echo "Expected exactly one default StorageClass, found $defaults" >&2
  exit 1
fi

kubectl create namespace "$NS"
kubectl apply -n "$NS" -f manifests/pvc.yaml -f manifests/statefulset.yaml -f manifests/service.yaml
timeout 120 sh -c 'until [ -n "$(kubectl get events -n "$0" --field-selector involvedObject.kind=PersistentVolumeClaim,involvedObject.name=store-demo-data,reason=ProvisioningFailed -o name)" ] && kubectl get pod store-demo-0 -n "$0" >/dev/null 2>&1; do sleep 5; done' "$NS"
kubectl get storageclass
kubectl get pvc,statefulset,pods -n "$NS"
```

The script stops at the starting state and prints it for the run log. It does not compare the output with the expected values above, so review it, or check it in your runner, before submitting the task.

## Run with your agent

Give the agent the contents of [prompt.md](prompt.md) in a fresh conversation. Use its existing execution platform to execute tools; no separate runner is needed.

For Crafting, configure your sandbox's startup to run the [scripted setup](#scripted-setup) against its intended Kubernetes target, then start your agent in that environment. Keep the agent's LLM and tools configurable through your agent definition. This folder does not yet include Crafting definitions. See [Crafting agent definitions](https://docs.sandboxes.cloud/references/ai-agent-definition.html).

Keep this operator README and any reference solution outside the agent's supplied context. The manifests on disk show the claim's StorageClass, so restrict the agent's filesystem access to setup files when your platform permits it.

## Manual evaluation

Use a 10-minute attempt budget, measured from task submission. Recovery includes a 60-second observation window. Record setup delays or changes to these defaults separately.

| Criterion | Passing evidence |
| --- | --- |
| Diagnosis | Identifies that `store-demo-data` requests StorageClass `fast-ssd`, which does not exist, using the claim's status or events, the Pod's scheduling event, or the cluster's StorageClass list. |
| Data safety | Establishes that the original claim was never bound (status `Pending`, no volume) before deleting it. Deletes no bound claim and no PersistentVolume. |
| Minimal correction | `store-demo-data` is recreated with the same name, at least 1Gi, and `ReadWriteOnce` access, on the cluster's default StorageClass, named explicitly or by omitting `storageClassName`. The StatefulSet's Pod template, image, code, ports, readiness probe, and the Service are unchanged; the replica count is back at 1 if the agent scaled down temporarily. |
| Storage recovery | `store-demo-data` is `Bound` to a dynamically provisioned PersistentVolume, and `store-demo-0` mounts it at `/data`. |
| Workload recovery | The StatefulSet has one Ready replica. |
| Stability | The recovered Pod stays Ready with no restart-count increase for 60 seconds. A Pod replacement during observation restarts the observation window. |
| HTTP behavior | Returns HTTP 200 with body `healthy`. |
| Persistence | After the operator deletes `store-demo-0`, the replacement Pod becomes Ready on the same claim and its `X-Boot-Count` is one higher than before. |
| Scope | No StorageClasses or PersistentVolumes were created or modified; no changes to nodes, other namespaces, or other cluster-wide resources. |

Record pass/fail for each criterion, the StorageClass used for the new claim, whether the agent scaled the StatefulSet down, elapsed recovery time, and tool-call/token counts when exposed by the agent platform. If a measurement is unavailable, mark it unavailable. Retain the agent definition, LLM identifier/settings, repository revision, cluster version, and default StorageClass provisioner with your private notes. Stop at the time budget and record incomplete attempts as such. No automated score or results upload is implemented.

The following are operator checks after the agent has finished, not a pre-run validation step:

```bash
kubectl rollout status statefulset/store-demo -n persistent-storage-benchmark --timeout=120s
kubectl get pvc store-demo-data -n persistent-storage-benchmark -o wide
kubectl get pvc store-demo-data -n persistent-storage-benchmark -o jsonpath='{.spec.storageClassName}{"\n"}{.spec.accessModes}{"\n"}{.spec.resources.requests.storage}{"\n"}'
kubectl get statefulset store-demo -n persistent-storage-benchmark -o jsonpath='{.spec.replicas}{"\n"}{.spec.template.spec.volumes}{"\n"}'
kubectl get storageclass
kubectl get pods -n persistent-storage-benchmark -l app=store-demo -o wide --watch
```

The claim should be `Bound`, on the default StorageClass, with `["ReadWriteOnce"]` access and at least `1Gi`. The StatefulSet should show one replica and a single `data` volume referencing claim `store-demo-data`. The StorageClass list should match the one recorded during setup. Observe readiness and restart counts for 60 seconds, then press Ctrl+C. For an HTTP check, start forwarding:

```bash
kubectl port-forward -n persistent-storage-benchmark service/store-demo 18080:80
```

Keep it running and use a second terminal on the same machine:

```bash
curl --fail --include http://127.0.0.1:18080/
```

Expect HTTP 200 and `healthy`, and note the `X-Boot-Count` value. Stop forwarding with Ctrl+C. This checks application HTTP behavior through a Service-selected Pod, not the full in-cluster Service networking path; networking is outside this scenario's scope.

Then check persistence. Delete the Pod and wait for the StatefulSet to recreate it and for the replacement to become Ready:

```bash
kubectl delete pod store-demo-0 -n persistent-storage-benchmark
timeout 60 sh -c 'until kubectl get pod store-demo-0 -n "$0" >/dev/null 2>&1; do sleep 2; done' persistent-storage-benchmark
kubectl wait pod/store-demo-0 -n persistent-storage-benchmark --for=condition=Ready --timeout=180s
```

Start port forwarding again and repeat the `curl` request. The new `X-Boot-Count` should be exactly one higher than the value noted before the deletion. A count that resets to `1` means the data did not persist.

## Reset and cleanup

To remove only this scenario's workload and retain the namespace:

```bash
kubectl delete -n persistent-storage-benchmark statefulset/store-demo service/store-demo
kubectl wait -n persistent-storage-benchmark --for=delete pod -l app=store-demo --timeout=120s
kubectl delete -n persistent-storage-benchmark pvc/store-demo-data
kubectl wait -n persistent-storage-benchmark --for=delete pvc/store-demo-data --timeout=120s
```

Deleting the claim deletes its dynamically provisioned PersistentVolume when the default StorageClass's reclaim policy is `Delete`. If the policy is `Retain`, the volume remains as `Released`; list volumes that belonged to this claim and delete them explicitly:

```bash
kubectl get pv -o jsonpath='{range .items[?(@.spec.claimRef.name=="store-demo-data")]}{.metadata.name}{"\t"}{.spec.claimRef.namespace}{"\t"}{.status.phase}{"\n"}{end}'
```

Delete only volumes whose namespace column matches this attempt's namespace.

After deletion finishes, repeat [Launch](#launch) from step 3 to start again with the fault configured. Use a fresh namespace and conversation for independent comparisons.

If the namespace was created exclusively for this attempt and contains nothing you need to retain, remove it too:

```bash
kubectl delete namespace persistent-storage-benchmark
```

Deleting the namespace also deletes the claim; a `Retain` reclaim policy still leaves the volume behind, so run the volume check above afterward. Do not run namespace deletion against a shared namespace. When a Crafting sandbox targets an external cluster, explicitly clean up its resources there; deleting the sandbox alone may leave them behind.

## Operator reference solution

Do not include this section in the agent's task context.

The claim requests `storageClassName: fast-ssd`, which does not exist in the cluster. The persistent volume controller cannot find a provisioner for it and records `ProvisioningFailed`, so the claim stays `Pending`. The scheduler will not place `store-demo-0` while its claim is unbound. The application, image, and StatefulSet are correct; the container never starts, so there are no logs to inspect.

A claim's StorageClass is immutable, so the fix is to replace the claim. The claim never bound to a volume, so it holds no data and replacing it is safe. The reference repair confirms that, scales the StatefulSet down so no Pod holds the claim, replaces the claim on the default StorageClass, and scales back up:

```bash
NS=persistent-storage-benchmark
kubectl get pvc store-demo-data -n "$NS" -o jsonpath='{.status.phase}{"\t"}{.spec.volumeName}{"\n"}'   # Pending, no volume
kubectl get storageclass

kubectl scale statefulset/store-demo -n "$NS" --replicas=0
kubectl wait pod/store-demo-0 -n "$NS" --for=delete --timeout=120s
kubectl delete pvc store-demo-data -n "$NS"
kubectl apply -n "$NS" -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: store-demo-data
  labels:
    app.kubernetes.io/part-of: kube-agent-benchmarks
    app: store-demo
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF
kubectl scale statefulset/store-demo -n "$NS" --replicas=1
kubectl rollout status statefulset/store-demo -n "$NS" --timeout=180s
```

Omitting `storageClassName` lets the cluster assign its default class; naming the default class explicitly is equally acceptable. If the default class uses `WaitForFirstConsumer`, the new claim stays `Pending` until the Pod is scheduled, then binds. Replacing the claim without scaling down first is also acceptable when the agent confirms the claim was deleted and recreated.

Creating a StorageClass named `fast-ssd`, creating a PersistentVolume by hand, switching `/data` to `emptyDir` or `hostPath`, or pointing the StatefulSet at a differently named claim are not intended repairs.
