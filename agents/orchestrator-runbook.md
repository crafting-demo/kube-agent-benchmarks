# Benchmark orchestrator runbook

Procedure for running one or more benchmark cases against several LLMs and reporting the results by case. The `benchmark-orchestrator` agent transfers to a sandbox workspace and follows this runbook there. An operator can follow it by hand the same way.

The agent under test in each run is `benchmark-test-llm`, started once per model with the model remapped for that session. Every (case, model) pair runs in its own namespace, so runs cannot affect each other or existing workloads in the cluster.

## Inputs

| Input | Example | Notes |
| --- | --- | --- |
| Cases | `pending-pod`, `broken-rollout` | Folder names under `benchmark_cases/`. |
| kubectl context | `bench-cluster` | The target cluster. Must exist in this workspace's kubeconfig. |
| Models | `claude-sonnet-5-5`, `openai-gpt-5-4-pro`, `claude-opus-4-8` | Two or more. Resolved to exact selectors in step 1. |
| Sandbox and workspace | `akansha-benchmark-2/app` | Where the agents under test run their commands. Normally the sandbox running this runbook. |
| Keep resources | `no` | `yes` skips cleanup so the namespaces can be inspected. |

If an input is missing or ambiguous, ask the user. Never guess the cluster.

## Isolation rules

These apply to every step, for the orchestrator and for every agent under test.

- Create only namespaces named for this run, and label each one `kube-agent-benchmarks/run=<RUN_ID>`. Before creating a namespace, confirm it does not exist.
- Do not create, modify, or delete anything outside this run's namespaces. The only exception is cleanup of PersistentVolumes provisioned for this run's claims, as described in step 7.
- Pass the cluster explicitly on every command (`KUBECONFIG` set to the run's kubeconfig, or `--context`). Do not change the current context in the user's kubeconfig.

## 1. Prepare the run

Work from the repository checkout and record its revision:

```bash
cd ~/kube-agent-benchmarks
git rev-parse --short HEAD
```

Confirm every requested case exists as `benchmark_cases/<case>/` with a `prompt.md` and `README.md`.

Resolve each requested model to an exact selector from the org's model list:

```bash
cs llm config models list
```

Match the user's names to the `NAME` column. For example, `claude-sonnet-5-5` is `anthropic:claude-sonnet-5-5` and `openai-gpt-5-4-pro` is `openai:gpt-5.4-pro`. If a name matches no model, or more than one, ask the user. For each model, derive a slug from the part after the colon, with dots replaced by dashes (`gpt-5-4-pro`).

Create the run directory and a kubeconfig that contains only the target context:

```bash
RUN_ID=$(date +%y%m%d%H%M)
RUN_DIR=~/benchmark-runs/$RUN_ID
mkdir -p "$RUN_DIR"
kubectl config get-contexts "<CONTEXT>"
kubectl config view --raw --minify --flatten --context "<CONTEXT>" > "$RUN_DIR/kubeconfig"
export KUBECONFIG="$RUN_DIR/kubeconfig"
kubectl version
kubectl auth can-i create namespaces
```

Stop and report if the context does not exist, the cluster is unreachable, or namespace creation is not allowed. Record the server version for the report.

Check each case's README `## Prerequisites` section against the cluster. For example, `persistent-storage-failure` needs exactly one default StorageClass and none named `fast-ssd`. Stop and report any prerequisite the cluster does not meet.

## 2. Set up one namespace per case and model

Name each namespace `<case>-<model-slug>-<RUN_ID>`, for example `pending-pod-gpt-5-4-pro-2610091530`. Names must be at most 63 characters; shorten the model slug if needed, keeping it unique within the run.

For each case, set up a namespace for every model, one after another, from the case folder, with `KUBECONFIG` exported as above:

- If the case README has a `### Scripted setup` section, save that script to `$RUN_DIR/<case>-setup.sh` and run it with the namespace as its argument: `sh "$RUN_DIR/<case>-setup.sh" <NAMESPACE>`.
- Otherwise, follow the README's `### Using another namespace` commands with the namespace substituted.

Label each namespace right after it is created:

```bash
kubectl label namespace <NAMESPACE> kube-agent-benchmarks/run=$RUN_ID
```

Then run the README's starting-state checks against the namespace. If a check fails, delete that namespace and set it up once more. If it fails again, stop and report the setup issue; do not run the case with a mismatched starting state.

## 3. Build each agent's prompt

For each namespace, take the case's `prompt.md` and replace the case's default namespace with the run namespace. The default namespace is the `metadata.name` in the case's `manifests/namespace.yaml`. Then put this header before the task, filled in:

```text
Environment for this task:
- Run every command in sandbox <SANDBOX>, workspace <WORKSPACE>.
- Target cluster: pass `--context <CONTEXT>` to every kubectl command. Do not change the kubeconfig's current context.
- Your namespace is <NAMESPACE>. Other namespaces on this cluster belong to other work; do not read or change them.
- Do not read files from the kube-agent-benchmarks repository or any copy of it.
```

Save it as `$RUN_DIR/<case>/<model-slug>/prompt.md`. Do not add any other hints.

## 4. Launch the agents under test

Run one case at a time. For that case, start every model's session back to back, so they begin under the same conditions:

```bash
cs llm session run @"$RUN_DIR/<case>/<model-slug>/prompt.md" \
  --agent benchmark-test-llm \
  --name bench-$RUN_ID-<case>-<model-slug> \
  --model-map CODING=<MODEL> --model-map GENERIC=<MODEL> --model-map FAST=<MODEL> \
  --approval auto \
  -W <SANDBOX>/<WORKSPACE> \
  --wait=false
```

Mapping every purpose to the model under test keeps the whole session on that model. Record each session's launch time. If `cs` rejects a flag, check `cs llm session run --help` and adjust without changing what the command does.

## 5. Enforce the time budget

Each case's `prompt.md` states its attempt budget (10 minutes for every current case). Wait for each session until its budget, measured from its own launch, runs out:

```bash
cs llm session wait bench-$RUN_ID-<case>-<model-slug> --timeout <REMAINING>
cs llm session list --name bench-$RUN_ID-<case>-<model-slug> -o json
```

When a session is still running at the end of its budget, cancel it and record the attempt as incomplete:

```bash
cs llm session cancel bench-$RUN_ID-<case>-<model-slug>
```

If a session stops waiting for input or approval, do not answer it: answering would help one model and not the others. Record the stop reason and treat the attempt as finished at that point.

## 6. Evaluate each run

Evaluate each run as soon as its session stops, so the 60-second stability observation starts while the agent's changes are fresh. Use the case README's `## Manual evaluation` section: its criteria table and its operator checks, with the case's default namespace replaced by the run namespace.

- Run the checks non-interactively. Instead of `--watch`, record Pod readiness and restart counts, wait 60 seconds, and record them again.
- For HTTP checks, run `kubectl port-forward` in the background on a local port unique to the run, make the request, then stop the port-forward.
- Judge criteria about diagnosis, approach, and reporting from the session transcript:

  ```bash
  cs llm session print bench-$RUN_ID-<case>-<model-slug>
  ```

- Check integrity in the transcript. Flag the run if the agent read files from the kube-agent-benchmarks repository, or read or changed another run's namespace. Score flagged runs normally, but mark them as flagged in the report.
- Confirm the model and collect token usage. Find the session ID, then export its usage grouped by model:

  ```bash
  cs llm session list --name bench-$RUN_ID-<case>-<model-slug> -o json
  cs llm metrics export --filter session_id=<SESSION_ID> --since=-24h --group-by=model_name \
    --resolution=24h --aggregation=SUM --named-value=input_tokens --named-value=output_tokens
  ```

  If any model other than the one under test appears, mark the run invalid.
- Record elapsed time from launch to the session's stop, or to the cancellation.

Score each criterion PASS or FAIL. If a criterion cannot be determined, mark it N/A and say why. A run's score is the percentage of its determined criteria that passed, rounded to the nearest whole number.

## 7. Clean up

Skip this step if the user asked to keep resources; list the namespaces left in place instead.

```bash
kubectl delete namespace -l kube-agent-benchmarks/run=$RUN_ID
```

For `persistent-storage-failure`, then check for PersistentVolumes left behind by a `Retain` reclaim policy, and delete only those whose claim was in one of this run's namespaces:

```bash
kubectl get pv -o jsonpath='{range .items[?(@.spec.claimRef.name=="store-demo-data")]}{.metadata.name}{"\t"}{.spec.claimRef.namespace}{"\t"}{.status.phase}{"\n"}{end}'
```

Leave the agent sessions in place; their transcripts are part of the record.

## 8. Report

Organize results by case, not by model. Save the report to `$RUN_DIR/report.md` and also give it to the user in the conversation.

Start with the run details: run ID, repository revision, kubectl context, Kubernetes server version, sandbox and workspace, and the resolved model selectors. Then, for each case:

```markdown
## <case>

| Criterion | <model A> | <model B> | <model C> |
| --- | --- | --- | --- |
| <criterion from the README> | PASS | FAIL | PASS |
| ... | | | |
| **Score** | **100%** | **71%** | **86%** |
| Elapsed time | 4m 10s | 10m 00s (incomplete) | 6m 45s |
| Input / output tokens | ... | ... | ... |
| Flags | | read repository files | |

**Best on this case:** <model>, <one-sentence reason>.

- **<model A>:** two or three sentences on its diagnosis, the change it made, and any mistakes.
- ...
```

Rank models within a case by score, then by elapsed time. If runs tie on both, say so rather than picking one. Explain each FAIL and N/A in the notes, and point out runs that were flagged, invalid, or incomplete. End with a short summary across cases only if more than one case ran.
