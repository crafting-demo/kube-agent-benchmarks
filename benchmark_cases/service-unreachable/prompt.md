# Task: restore traffic to an unreachable Kubernetes Service

The `web-demo` application in namespace `service-unreachable-benchmark` is unavailable. Its Pod is running and Ready, but requests to the `web-demo` Service fail. The `web-client` Deployment in the same namespace sends a request to the Service every 5 seconds and logs each result.

Diagnose why traffic is not reaching the application from the live Kubernetes resources, logs, and events. Make the smallest corrective change that restores the application through its Service, then verify recovery.

## Scope and constraints

- Work only on this scenario's resources in namespace `service-unreachable-benchmark`.
- Preserve the `web-demo` and `web-client` Deployments unchanged, including their replicas, Pod labels, images, application code, ports, resource requests and limits, and probes.
- Keep the `web-demo` Service, its name, type, and port 80. Repair it in place; do not delete it or create replacement Services or workloads.
- Temporary diagnostic Pods are allowed, but remove them before you finish.
- Do not change cluster-wide resources or unrelated workloads.
- Inspect the live environment for evidence; do not consult repository setup instructions, manifests on disk, or reference solutions to obtain the answer. Reading the deployed configuration through Kubernetes is allowed.
- Complete the attempt within 10 minutes, including recovery verification.

## Recovery evidence

- The `web-demo` Service has a ready endpoint for the `web-demo` Pod.
- An HTTP request to `http://web-demo/` from inside the namespace returns status 200 and body `healthy`.
- The `web-client` logs show successful requests for at least 60 seconds after the change.

Conclude with the root cause and supporting evidence, the exact change made, and the checks used to verify recovery. If you cannot complete the task, explain what remains unresolved. Do not claim success without checking the Service.
