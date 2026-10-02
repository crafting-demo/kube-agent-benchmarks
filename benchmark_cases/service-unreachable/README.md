# Service unreachable: mismatched Service selector

A small Kubernetes troubleshooting scenario for LLM-powered agents. An application Pod is running and Ready, but its Service starts with a selector that matches no Pods, so the Service has no endpoints and requests to it fail. The agent must find why traffic is not reaching the Pod and make a minimal correction.

This folder contains plain Kubernetes manifests and the task prompt. It requires no Helm chart, custom container image, benchmark runner, or separate fault injection step. Evaluation is manual; automated grading will be added later. No benchmark results are published here.

## Files

```text
service-unreachable/
├── README.md
├── prompt.md
└── manifests/
    ├── namespace.yaml
    ├── deployment.yaml
    └── service.yaml
```

## Environment

| Resource | Purpose |
| --- | --- |
| Namespace `service-unreachable-benchmark` | Dedicated location for this attempt's resources. |
| Deployment `web-demo` | Manages one Pod running a small, healthy Python HTTP application. |
| Service `web-demo` | Internal address on port 80, intended to forward to application port 8080. |
| Deployment `web-client` | Manages one Pod that requests `http://web-demo/` every 5 seconds and logs `OK` or `FAIL` for each attempt. |

`deployment.yaml` contains both Deployments. The `web-demo` Pod requests 50 millicores of CPU and 32 MiB of memory; its limits are 200 millicores and 128 MiB. The `web-client` Pod requests 10 millicores and 32 MiB; its limits are 100 millicores and 64 MiB. Both run as a non-root user and do not mount Kubernetes API credentials. The Service does not create an external load balancer.

The client gives the agent and operator in-cluster evidence of the Service path. It addresses the Service by its short DNS name, so it works in any namespace.

The agent runs separately and needs its own Kubernetes access. A namespace separates resource names but does not enforce agent access restrictions or reserve dedicated nodes. Use namespace-scoped credentials for the agent and capacity appropriate to your cluster. These manifests do not provision agent credentials, RBAC, a cluster, or a Crafting sandbox.

## Prerequisites

- An existing Kubernetes cluster and a connected `kubectl` installation.
- Permission to create the dedicated namespace, Deployments, and Service, or an existing namespace supplied by an administrator.
- A Linux node that can pull `python:3.12-slim` from Docker Hub and has capacity for both Pods.
- Working cluster DNS and Service networking (for example, kube-proxy or an equivalent CNI implementation).
- Cluster admission policies that allow these resources and settings.
- An agent with Kubernetes inspection and Service configuration-editing tools. Reading Pod logs and either `kubectl exec` or permission to create temporary Pods lets the agent test the Service from inside the cluster.

The image uses a public tag for this initial version. The tag can change; pin an approved image digest before conducting strictly versioned comparisons.

## Launch

Run from this folder. Confirm the selected cluster first:

```bash
kubectl config current-context
```

Use the namespace below only if it is reserved for this test. For simultaneous attempts, use a different namespace for each attempt as described below.

```bash
kubectl apply -f manifests/namespace.yaml
kubectl apply -n service-unreachable-benchmark -f manifests/deployment.yaml -f manifests/service.yaml
```

The Service is faulty immediately: there is no healthy-first installation and no subsequent injection command. Once the image is pulled, both Deployments become available, the `web-demo` Service has no endpoints, and the `web-client` logs show failed requests. Depending on the cluster's Service implementation, failures appear as refused connections or timeouts.

No automatic fault check is included. Sandbox startup may wait for the Deployments to become available, but must not wait for the Service to serve traffic: its broken state is intentional. A registry, scheduling, DNS, or authorization error is a setup issue rather than the intended configuration failure.

### Using another namespace

Skip `namespace.yaml`, create a fresh namespace, and apply only the workload manifests:

```bash
kubectl create namespace service-unreachable-run-002
kubectl apply -n service-unreachable-run-002 -f manifests/deployment.yaml -f manifests/service.yaml
```

Replace `service-unreachable-benchmark` in the task prompt and the commands below with that namespace. The Deployments and Service intentionally omit `metadata.namespace` so the `-n` argument selects their destination.

## Run with your agent

Give the agent the contents of [prompt.md](prompt.md) in a fresh conversation. Use its existing execution platform to execute tools; no separate runner is needed.

For Crafting, configure your sandbox's startup to apply the manifests to its intended Kubernetes target, then start your agent in that environment. Keep the agent's LLM and tools configurable through your agent definition. This folder does not yet include Crafting definitions. See [Crafting agent definitions](https://docs.sandboxes.cloud/references/ai-agent-definition.html).

Keep this operator README and any reference solution outside the agent's supplied context. The prompt requests live diagnosis; for controlled comparisons, also restrict filesystem access to setup files when your platform permits it.

## Manual evaluation

Use a 10-minute attempt budget, measured from task submission. Recovery includes a 60-second observation window. Record setup delays or changes to these defaults separately.

| Criterion | Passing evidence |
| --- | --- |
| Diagnosis | Identifies that the Service selector does not match the application Pod's labels, using live Service, Pod, or endpoint evidence. |
| Minimal correction | Fixes the existing Service in place (same UID) while preserving its name, type, and port 80. Neither Deployment is modified. |
| Endpoints | The `web-demo` Service has exactly one ready endpoint: the `web-demo` Pod on port 8080. The `web-client` Pod is not selected. |
| Stability | The `web-client` logs show only `OK` results for 60 seconds after the change. |
| HTTP behavior | A request to `http://web-demo/` from inside the namespace returns HTTP 200 with body `healthy`. |
| Scope | No changes outside the assigned scenario resources; no extra Services or workloads; temporary diagnostic Pods removed. |

Record pass/fail for each criterion, elapsed recovery time, and tool-call/token counts when exposed by the agent platform. If a measurement is unavailable, mark it unavailable. Retain the agent definition, LLM identifier/settings, repository revision, and cluster version with your private notes. Stop at the time budget and record incomplete attempts as such. No automated score or results upload is implemented.

Before starting the agent, record the Service UID so you can confirm an in-place repair:

```bash
kubectl get service web-demo -n service-unreachable-benchmark -o jsonpath='{.metadata.uid}{"\n"}'
```

The following are operator checks after the agent has finished, not a pre-run validation step:

```bash
kubectl get service web-demo -n service-unreachable-benchmark -o jsonpath='{.metadata.uid}{"\n"}{.spec.selector}{"\n"}{.spec.ports}{"\n"}'
kubectl get endpointslices -n service-unreachable-benchmark -l kubernetes.io/service-name=web-demo -o wide
kubectl get deployments -n service-unreachable-benchmark -o custom-columns=NAME:.metadata.name,GENERATION:.metadata.generation,READY:.status.readyReplicas
kubectl get pods -n service-unreachable-benchmark
```

The UID should match the recorded value. Both Deployments should still be at generation 1; a higher generation means the Deployment spec was changed. No Pods other than the `web-demo` and `web-client` Pods should remain.

Check the client's recent results:

```bash
kubectl logs -n service-unreachable-benchmark deployment/web-client --since=60s
```

For a single HTTP check through Service networking, request the Service from the client Pod:

```bash
kubectl exec -n service-unreachable-benchmark deployment/web-client -- \
  python -c "import urllib.request as u; r = u.urlopen('http://web-demo/', timeout=5); print(r.status, r.read().decode())"
```

Expect `200 healthy`. Unlike `kubectl port-forward service/...`, which connects directly to a selected Pod, this request uses cluster DNS and the Service's virtual IP, which is the path this scenario tests.

## Reset and cleanup

To remove only this scenario's workload and retain the namespace:

```bash
kubectl delete -n service-unreachable-benchmark -f manifests/deployment.yaml -f manifests/service.yaml
kubectl wait -n service-unreachable-benchmark --for=delete pod -l 'app in (web-demo,web-client)' --timeout=120s
```

After deletion finishes, reapply the workload manifests to start again with the fault configured. Reapplying `service.yaml` over a repaired Service also restores the faulty selector, but it does not remove diagnostic Pods or other resources the agent created. Use a fresh namespace and conversation for independent comparisons.

If the namespace was created exclusively for this attempt and contains nothing you need to retain, remove it too:

```bash
kubectl delete namespace service-unreachable-benchmark
```

Do not run namespace deletion against a shared namespace. When a Crafting sandbox targets an external cluster, explicitly clean up its resources there; deleting the sandbox alone may leave them behind.

## Operator reference solution

Do not include this section in the agent's task context.

The application Pods carry the label `app=web-demo`, while the initial Service selects `app=web`. No Pod matches, so the Service has no endpoints and the client's requests fail. The application, its readiness probe, and the port mapping (`port: 80` to the named container port `http`, 8080) are all correct.

The reference repair is:

```bash
kubectl patch service web-demo -n service-unreachable-benchmark --type merge -p '{"spec":{"selector":{"app":"web-demo"}}}'
```

The endpoint controller then adds the Ready `web-demo` Pod to the Service, and the client logs switch to `OK` within a few seconds. Relabeling the Pods or editing the Deployment's Pod template to match the Service is not the intended repair, because it changes the healthy workload rather than the misconfigured Service.
