# Task: make a Pending Kubernetes workload runnable

The `pending-demo` Deployment in namespace `pending-pod-benchmark` has no available replicas. Its Pod never starts running, and the application is unavailable through the `pending-demo` Service.

Diagnose the root cause from the live Kubernetes resources, events, and cluster state. Make the smallest corrective change that lets the workload run, then verify recovery.

## Scope and constraints

- Work only on this scenario's resources in namespace `pending-pod-benchmark`.
- Preserve the Deployment, its one desired replica, application image and code, ports, and readiness probe.
- Keep explicit CPU and memory requests on the container, sized appropriately for this small HTTP application. Change resource settings only as needed to fix the problem.
- Do not modify nodes (including labels, taints, or cordoning), add capacity, evict or scale other workloads, or change priority classes or other cluster-wide resources.
- Inspect the live environment for evidence; do not consult repository setup instructions, manifests on disk, or reference solutions to obtain the answer. Reading the deployed configuration and node information through Kubernetes is allowed.
- Complete the attempt within 10 minutes, including recovery verification.

## Recovery evidence

- The Deployment has one updated, Ready, available replica.
- The recovered Pod is scheduled to a node and remains Ready with a stable restart count for at least 60 seconds.
- An HTTP request to the application returns status 200 and body `healthy`.

Conclude with the root cause and supporting evidence, the exact change made, and the checks used to verify recovery. If you cannot complete the task, explain what remains unresolved. Do not claim success without checking the workload.
