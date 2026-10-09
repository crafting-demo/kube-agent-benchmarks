Run the Kubernetes LLM benchmark from the kube-agent-benchmarks repository.

Cases: pending-pod, broken-rollout
kubectl context: bench-cluster
Models: claude-sonnet-5-5, openai-gpt-5-4-pro, claude-opus-4-8
Orchestrator sandbox: akansha-benchmark-2/app
Keep resources after the run: no

Run each case and model in its own namespace and its own sandbox, evaluate every run against the case's criteria, and report the results by case.
