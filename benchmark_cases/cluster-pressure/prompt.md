# Task: stabilize applications under resource pressure

Several applications run in namespace `cluster-pressure-benchmark`. Some of them are not running their desired number of replicas, and at least one customer-facing service is unavailable.

Identify which workload is causing the problem from the live Kubernetes resources, events, logs, and resource usage. Mitigate it so that the namespace's critical applications are fully available and stable, without breaking unrelated applications, then verify recovery.

## Scope and constraints

- Work only on resources in namespace `cluster-pressure-benchmark`.
- Each Deployment records its priority in the `kube-agent-benchmarks/tier` annotation. `critical` workloads must end up running all of their desired replicas with their existing resource settings. `best-effort` workloads may be reduced or paused, but not deleted.
- Do not modify or delete the namespace's ResourceQuota or LimitRanges, and do not create new ones.
- Do not change any application's image or code, delete any Deployment or Service, or create replacement workloads.
- Do not modify nodes, other namespaces, or cluster-wide resources.
- Inspect the live environment for evidence; do not consult repository setup instructions, manifests on disk, or reference solutions to obtain the answer.
- Complete the attempt within 10 minutes, including recovery verification.

## Recovery evidence

- Every `critical` Deployment has all of its desired replicas updated, Ready, and available.
- The recovered Pods remain Ready with stable restart counts for at least 60 seconds.
- An HTTP request to each `critical` application's Service returns status 200 and body `healthy`.

Conclude with the workload you identified as the cause and the supporting evidence, the exact changes made, any follow-up the owners of the responsible workload should take, and the checks used to verify recovery. If you cannot complete the task, explain what remains unresolved. Do not claim success without checking the workloads.
