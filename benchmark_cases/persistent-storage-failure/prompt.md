# Task: restore a stateful workload that cannot start

The `store-demo` StatefulSet in namespace `persistent-storage-benchmark` has no Ready replicas. Its Pod never starts, and the application is unavailable through the `store-demo` Service. The application keeps its data on a persistent volume.

Diagnose the root cause from the live Kubernetes resources, events, and cluster state. Make the smallest safe change that lets the workload run with persistent storage, then verify recovery.

## Scope and constraints

- Work only on this scenario's resources in namespace `persistent-storage-benchmark`.
- Preserve the StatefulSet, its one desired replica, application image and code, ports, readiness probe, and the Service.
- The application must keep using persistent storage: its `/data` volume must remain backed by a PersistentVolumeClaim named `store-demo-data`, with at least 1Gi of storage and `ReadWriteOnce` access. Do not replace it with `emptyDir`, `hostPath`, or other non-persistent storage.
- Treat storage as potentially holding data. Before deleting or replacing any PersistentVolumeClaim or PersistentVolume, establish that doing so cannot lose data.
- Do not create, modify, or delete StorageClasses, PersistentVolumes, nodes, or other cluster-wide resources, and do not change other namespaces.
- Inspect the live environment for evidence; do not consult repository setup instructions, manifests on disk, or reference solutions to obtain the answer. Reading StorageClasses and other cluster information through Kubernetes is allowed.
- Complete the attempt within 10 minutes, including recovery verification.

## Recovery evidence

- The PersistentVolumeClaim `store-demo-data` is `Bound`.
- The StatefulSet has one Ready replica, and its Pod mounts `store-demo-data` at `/data`.
- The recovered Pod remains Ready with a stable restart count for at least 60 seconds.
- An HTTP request to the application returns status 200 and body `healthy`.

Conclude with the root cause and supporting evidence, the exact changes made, how you established that they were safe for stored data, and the checks used to verify recovery. If you cannot complete the task, explain what remains unresolved. Do not claim success without checking the workload.
