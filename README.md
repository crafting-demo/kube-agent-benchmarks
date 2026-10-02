# kube-agent-benchmarks
A reproducible benchmark for evaluating LLMs on Kubernetes troubleshooting and recovery using controlled failure scenarios.
# Agent Benchmark for Kubernetes

A reproducible benchmark for evaluating LLMs on Kubernetes troubleshooting and recovery using common kubernetes issues as benchmark cases. Bring your own agent, launch a scenario with its fault already configured, and evaluate how the agent diagnoses and repairs it.

The initial setup uses [Crafting Sandboxes](https://docs.sandboxes.cloud/) for the execution environment and agent configuration. Kubernetes manifests define the scenario workload, allowing users to adapt it to another environment with Kubernetes access.

## Purpose

This README describes the intended initial layout and workflow to reproduce the benchmark.
Evaluation criteria are documented below.

| Component | Purpose |
| --- | --- |
| Sandbox definition | Configures the Crafting execution environment, tooling, and scenario startup. It must provide access to the intended Kubernetes environment. |
| Agent definition | Configures the agent's instructions, LLM, tools, and connection to its execution environment. Users can substitute their own definition. |
| Kubernetes manifests | Define the application Deployment and any supporting resources, with the faulty configuration present from the start. |
| Task prompt | Gives the agent the affected workload, namespace, objective, and boundaries without supplying the repair. |
| Evaluation criteria | Describe what successful diagnosis and recovery mean and which measurements to record. |

Crafting manages the agent session and execution environment; this repository does not require a separate benchmark runner. See Crafting's [agent definition](https://docs.sandboxes.cloud/references/ai-agent-definition.html) and [sandbox definition](https://docs.sandboxes.cloud/references/sandbox-definition.html) references.

A Crafting sandbox and a Kubernetes namespace are different things. A workspace can connect to a Kubernetes cluster, but creating the workspace does not by itself create or isolate that cluster. Each attempt needs its own scenario resources and appropriately scoped access.

## Repo Structure

```text
kube-agent-benchmarks/
├── README.md
├── agents/
│   └── example.yaml
└── scenarios/
    └── crashloop-bad-env/
        ├── sandbox.yaml
        ├── manifests/
        │   ├── deployment.yaml
        │   └── service.yaml
        ├── prompt.md
        └── evaluation.md
```

This is the target layout for the first iteration, not a list of files already available. The root README introduces the project; `evaluation.md` will hold the scenario's detailed criteria as they evolve.


## Intended usage

The included artifacts can be used to set up and run the benchmark using LLMs of choice or to reproduce the published findings:

1. Create a Crafting template from the scenario's sandbox definition, configuring its Kubernetes target and a dedicated namespace for the attempt.
2. Use the example agent definition or supply your own. Configure the LLM and credentials through your execution platform, and give the agent access to the scenario's Kubernetes resources.
3. Launch the environment. Startup applies the manifests with the fault already present.
4. Start a fresh agent conversation using the scenario prompt.
5. Evaluate the agent's actions and the resulting workload against the evaluation criteria.
6. Resources can be cleaned up easily to allow additional test runs and prevent additional cost.

For another execution platform, reuse the Kubernetes manifests, task prompt, and evaluation criteria. Adapt the sandbox and agent integration to that platform; Crafting definitions are not universal agent configuration files.

Example agent task:

> The `crash-demo` Deployment in namespace `<namespace>` is unhealthy. Can you investigate and fix it?

## Kubernetes YAML and Helm

A Kubernetes deployment manifest is sufficient to describe the test application's Pods; a Service manifest provides a stable internal address for the HTTP application.

Helm charts may be introduced in the future, as these benchmark cases currently depend on public images.

## Repeatability and scope

The goal is repeatable test conditions and comparable measurements, not a guarantee of identical LLM responses or timings. Reuse the same scenario revision, prompt, budgets, and workload settings. Use fresh agent conversations and record differences in tools, permissions, or infrastructure.
