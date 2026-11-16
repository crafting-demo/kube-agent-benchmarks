# Task: recover a failed Kubernetes rollout

A new release of the `rollout-demo` Deployment in namespace `broken-rollout-benchmark` was deployed recently, and the rollout has not completed. The application is served through the `rollout-demo` Service.

Diagnose why the rollout is failing from the live Kubernetes resources, events, logs, and rollout history. Recover the Deployment to a healthy, fully rolled-out state with the smallest appropriate change, then verify recovery.

## Scope and constraints

- Work only on this scenario's resources in namespace `broken-rollout-benchmark`.
- Preserve the Deployment, its two desired replicas, application code, ports, and the Service.
- Keep a readiness probe on the container that checks the application's HTTP endpoint. Do not remove or weaken health checking to force the rollout through.
- Do not delete and recreate the Deployment, and do not create replacement workloads.
- Inspect the live environment for evidence; do not consult repository setup instructions, manifests on disk, or reference solutions to obtain the answer.
- Complete the attempt within 10 minutes, including recovery verification.

## Recovery evidence

- The Deployment's latest rollout has completed: two updated, Ready, available replicas, and no Pods from any other revision remain.
- The recovered Pods remain Ready with stable restart counts for at least 60 seconds.
- An HTTP request to the application returns status 200 and body `healthy`.

Conclude with the root cause and supporting evidence, the exact change made, which application version is now running, and the checks used to verify recovery. If you cannot complete the task, explain what remains unresolved. Do not claim success without checking the workload.
