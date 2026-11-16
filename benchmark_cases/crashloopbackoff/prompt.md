# Task: recover an unhealthy Kubernetes workload

The `crash-demo` Deployment in namespace `crashloop-benchmark` is unhealthy. Its application container repeatedly restarts, and the application is unavailable through the `crash-demo` Service.

Diagnose the root cause from the live Kubernetes resources, logs, and events. Make the smallest corrective change that restores the application, then verify recovery.

## Scope and constraints

- Work only on this scenario's resources in namespace `crashloop-benchmark`.
- Preserve the Deployment, its one desired replica, application image and code, resource requests and limits, and readiness probe.
- Do not change cluster-wide resources or unrelated workloads.
- Inspect the live environment for evidence; do not consult repository setup instructions, manifests on disk, or reference solutions to obtain the answer. Reading the deployed configuration through Kubernetes is allowed.
- Complete the attempt within 10 minutes, including recovery verification.

## Recovery evidence

- The Deployment has one updated, Ready, available replica.
- The recovered Pod remains Ready with a stable restart count for at least 60 seconds.
- An HTTP request to the application returns status 200 and body `healthy`.

Conclude with the root cause and supporting evidence, the exact change made, and the checks used to verify recovery. If you cannot complete the task, explain what remains unresolved. Do not claim success without checking the workload.
