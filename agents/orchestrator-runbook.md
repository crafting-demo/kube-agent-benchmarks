# Benchmark orchestrator runbook

Procedure for running one or more benchmark cases against several LLMs and reporting the results by case. The `benchmark-orchestrator-agent` transfers to the orchestrator sandbox's workspace and follows this runbook there. An operator can follow it by hand the same way.

> **You are the workspace agent.** If you are reading this runbook after a transfer into the orchestrator sandbox's workspace, the transfer has already completed: you are now the workspace agent running inside that sandbox (confirm with `echo $SANDBOX_FULL_NAME` and `hostname`). The transfer is a hand-off of control, not a request to a separate agent — there is no further agent to hand off to, and no transfer message is delivered on top of the hand-off. Execute this runbook yourself here. Running benchmark agents under test are launched later in step 4 as child sessions; they are distinct from you.

The agent under test in each run is a per-run copy of `benchmark-sub-agent`, named `benchmark-sub-agent-<RUN_ID>` and created fresh from `agents/benchmark-sub-agent.yaml` in step 1, started once per model with the model remapped for that session. Every (case, model) pair runs in its own namespace and its own sandbox, so runs cannot affect each other or existing workloads in the cluster. Run sandboxes are created from the `benchmark-k8s-run` template, which has no checkout of this repository, so the agent under test has no case READMEs or manifests on disk.

### Run ID

Every run has a **RUN_ID** that identifies it. It is generated once in step 1 and threaded through everything the run creates: the per-run agent name, every namespace and run sandbox name, the run directory and all files under it, and the report. This keeps each run self-identified and avoids name conflicts with objects from other runs or ones created outside the benchmark. Whenever this runbook refers to `$RUN_ID`, it means this same value. Always report results as "results for run ID XXXX".

## Inputs

| Input | Example | Notes |
| --- | --- | --- |
| Cases | `pending-pod`, `broken-rollout` | Folder names under `benchmark_cases/`. |
| kubectl context | `bench-cluster` | The target cluster, as the user gave it. Taken as correct and verified against the cluster in step 1; not re-confirmed with the user beforehand. Must exist in this workspace's kubeconfig. |
| Models | `claude-sonnet-5-5`, `openai-gpt-5-4-pro`, `claude-opus-4-8` | One or more. With a single model the run measures that model rather than comparing; with two or more it also compares them. Resolved to exact selectors in step 1. |
| Orchestrator sandbox and workspace | `akansha-benchmark-2/app` | The sandbox running this runbook, created from the `benchmark-k8s` template. The agents under test run in their own sandboxes, created in step 4. |
| Token prices | `<model>: <input> / <output> USD per million tokens` | Optional. Used for cost; otherwise the provider's published list prices are used. |
| Keep resources | `no` | `yes` skips cleanup so the namespaces can be inspected. |

If an input is missing or ambiguous, ask the user. If the user gave a kubectl
context, take it as correct and verify it against the cluster in step 1 rather
than asking them to re-confirm it first; only ask about the cluster when no
context was given at all.

## Isolation rules

These apply to every step, for the orchestrator and for every agent under test.

- Create only namespaces named for this run, and label each one `kube-agent-benchmarks/run=<RUN_ID>`. Before creating a namespace, confirm it does not exist.
- Do not create, modify, or delete anything outside this run's namespaces. The only exception is cleanup of PersistentVolumes provisioned for this run's claims, as described in step 7.
- Create only sandboxes named for this run, from the `benchmark-k8s-run` template, and remove only those. Before creating a sandbox, confirm it does not exist.
- Pass the cluster explicitly on every command (`KUBECONFIG` set to the run's kubeconfig, or `--context`). Do not change the current context in the user's kubeconfig.

## 1. Prepare the run

Work from the repository checkout and record its revision:

```bash
cd ~/kube-agent-benchmarks
git rev-parse --short HEAD
```

Confirm every requested case exists as `benchmark_cases/<case>/` with a `prompt.md` and `README.md`.

Confirm the run sandbox template exists; stop and report if it does not:

```bash
cs template show benchmark-k8s-run
```

Resolve each requested model to an exact selector from the org's model list:

```bash
cs llm config models list
```

Match the user's names to the `NAME` column. For example, `claude-sonnet-5-5` is `anthropic:claude-sonnet-5-5` and `openai-gpt-5-4-pro` is `openai:gpt-5.4-pro`. If a name matches no model, or more than one, ask the user. For each model, derive a slug from the part after the colon, with dots replaced by dashes (`gpt-5-4-pro`). After creating the run directory below, write one line per model to `$RUN_DIR/models.tsv`: the slug and the exact selector, separated by a tab.

Generate the run ID and use it for everything this run creates:

```bash
RUN_ID=$(date +%y%m%d%H%M)
```

Create the run directory and a kubeconfig that contains only the target context:

```bash
RUN_DIR=~/benchmark-runs/$RUN_ID
mkdir -p "$RUN_DIR"
kubectl config get-contexts "<CONTEXT>"
kubectl config view --raw --minify --flatten --context "<CONTEXT>" > "$RUN_DIR/kubeconfig"
export KUBECONFIG="$RUN_DIR/kubeconfig"
kubectl version
kubectl auth can-i create namespaces
```

If `$RUN_DIR` already exists, generate a new `RUN_ID` and try again.

Create the per-run agent under test from the repository definition, so the run always uses the exact definition at this revision and never an agent left over from a previous run or created by hand:

```bash
SUB_AGENT=benchmark-sub-agent-$RUN_ID
cs llm agent create "$SUB_AGENT" ~/kube-agent-benchmarks/agents/benchmark-sub-agent.yaml
cs llm agent show "$SUB_AGENT"
```

This is a personal agent, so `cs llm session run --agent` resolves it. Record `SUB_AGENT` in `run.env` below.

Save the run settings that the launch script reads:

```bash
cat > "$RUN_DIR/run.env" <<EOF
RUN_ID=$RUN_ID
CONTEXT=<CONTEXT>
SUB_AGENT=$SUB_AGENT
EOF
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

Each (case, model) pair gets a run sandbox. Sandbox names are limited to 20 characters. Number the run's pairs `1`, `2`, … across the whole run (not restarting per case), without zero-padding, and name each sandbox `bench-$RUN_ID-<N>`:

```bash
RUN_SANDBOX=bench-$RUN_ID-<N>
```

Record each pair's namespace and sandbox in `$RUN_DIR/runs.tsv`, one line per pair: `<case>`, `<model-slug>`, `<NAMESPACE>`, `<RUN_SANDBOX>`, separated by tabs. Later steps look up sandboxes there.

For each namespace, take the case's `prompt.md` and replace the case's default namespace with the run namespace. The default namespace is the `metadata.name` in the case's `manifests/namespace.yaml`. Then put this header before the task, filled in:

```text
Environment for this task:
- Run every command in sandbox <RUN_SANDBOX>, workspace app.
- Target cluster: pass `--context <CONTEXT>` to every kubectl command. Do not change the kubeconfig's current context.
- Your namespace is <NAMESPACE>. Other namespaces on this cluster belong to other work; do not read or change them.
- Do not use any other sandbox or workspace.
- Do not read files from the kube-agent-benchmarks repository or any copy of it.
```

Save it as `$RUN_DIR/<case>/<model-slug>/prompt.md`. Do not add any other hints.

## 4. Create the run sandboxes and launch the agents under test

Run one case at a time. For each case, run the launch script from the repository checkout:

```bash
~/kube-agent-benchmarks/agents/launch-sub-agents.sh "$RUN_DIR" <case>
```

For every model of the case, the script:

1. Confirms the run sandbox from `runs.tsv` does not exist yet, then creates it from the `benchmark-k8s-run` template and waits until it is ready.
2. Copies `$RUN_DIR/kubeconfig` to `~/.kube/config` in the sandbox, as the workspace user, and confirms the run namespace is reachable from there. If either fails, it removes the sandbox and creates it once more.
3. After every sandbox for the case is ready, starts the per-run agent (`$SUB_AGENT`) sessions back to back, so they begin under the same conditions. Each session is named `bench-$RUN_ID-<case>-<model-slug>`, maps every model purpose to the model under test, runs as a task with automatic approval in its run sandbox, and is started with `--parent=$SANDBOX_LLM_SESSION_ID` as a child of the orchestrator session. Crafting sets `SANDBOX_LLM_SESSION_ID` in the workspace agent's shell; when the script is run by hand outside a session, the variable is unset and the sessions start without a parent.
4. Resolves each child session's ID from `cs llm session list --parent $SANDBOX_LLM_SESSION_ID -o json` and records the session name, its ID, its sandbox, and its launch time in `$RUN_DIR/launches.tsv` (columns: `<case>`, `<model-slug>`, `<session name>`, `<session id>`, `<sandbox>`, `<launch time>`).

If the script fails, stop and report its output. Do not start sessions by hand for a case the script did not finish.

Notes on launch behaviour observed in practice:

- The agent must actually resolve, not merely appear in `cs llm agent list`. `cs llm session run --agent NAME` resolves a *personal* agent (one you own) first, then an *org-shared* one; an org-scoped agent with no owner and not shared is listed but cannot be resolved, and the run fails with `AI agent "NAME" not found`. The run uses the per-run agent `$SUB_AGENT` (`benchmark-sub-agent-$RUN_ID`) created in step 1, which is personal and therefore resolves; the launch script reads `SUB_AGENT` from `run.env`. Creating it fresh each run also avoids reusing a stale `benchmark-sub-agent` whose stored definition differs from `agents/benchmark-sub-agent.yaml`. Confirm resolvability before launching by hand with `cs llm agent show "$SUB_AGENT"`.
- `cs llm session run ... --parent ... --wait=false` can print `Fatal: proto: invalid nil source message` to stderr yet still create the session and exit success. Do not treat that stderr line as failure; confirm the session with `cs llm session list --parent $SANDBOX_LLM_SESSION_ID` (see below).
- Never start an ad-hoc test session against a run sandbox. A debug session that lands in the same run sandbox as a real agent taints that pair and its result is no longer attributable; the only fix is to tear down that namespace and sandbox and redo the pair clean.

Child sessions are addressed differently from top-level sessions. List them and capture their session IDs with:

```bash
cs llm session list --parent $SANDBOX_LLM_SESSION_ID -o json
```

Each child's display name is `sub-agent:bench-$RUN_ID-<case>-<model-slug>`. The `cs llm session wait`, `print`, `cancel`, and `remove` subcommands do not resolve child sessions by that name or by the bare `bench-...` name; use the child's session **ID** for every later `cs llm session` call. The launch script already records each child's ID in `$RUN_DIR/launches.tsv` so steps 5 and 6 can look it up.

## 5. Enforce the time budget

Each case's `prompt.md` states its attempt budget (10 minutes for every current case). Wait for each session until its budget, measured from its launch time in `launches.tsv`, runs out:

```bash
cs llm session wait <SESSION_ID> --timeout <REMAINING>
cs llm session list --parent $SANDBOX_LLM_SESSION_ID -o json
```

`<SESSION_ID>` is the child session's ID from `cs llm session list --parent $SANDBOX_LLM_SESSION_ID -o json` (step 4). The child name `bench-$RUN_ID-<case>-<model-slug>` is not accepted by these subcommands. A child's state shows in the `--parent` listing's table column; the per-session JSON carries `content.status.state` (e.g. `STOPPED`) and `content.usage` (token counts), but not the message history.

When a session is still running at the end of its budget, cancel it by ID and record the attempt as incomplete:

```bash
cs llm session cancel <SESSION_ID>
```

If a session stops waiting for input or approval, do not answer it: answering would help one model and not the others. Record the stop reason and treat the attempt as finished at that point.

## 6. Evaluate each run

Evaluate each run as soon as its session stops, so the 60-second stability observation starts while the agent's changes are fresh. Judge every run with `agents/evaluation-rubric.md`: it defines the general criteria that apply to every case, how they combine with the case criteria into an overall result, and the measurements to record.

Save the transcript first, in JSON for counting tool calls and as text for reading:

```bash
cs llm session print <SESSION_ID> --print json > "$RUN_DIR/<case>/<model-slug>/transcript.jsonl"
cs llm session print <SESSION_ID> > "$RUN_DIR/<case>/<model-slug>/transcript.txt"
```

Saving the transcript keeps it with the run: child sessions are removed when the orchestrator session is archived or deleted.

Known limitation: in some CLI builds `cs llm session print` cannot address a sub-agent child session by ID or by name and returns `Session "..." not found`, and the session's `content.conversation` field holds only its initial context, not the message history. When that happens the full transcript (and therefore exact tool-call and kubectl-command counts) is unavailable. In that case:

- Record the token usage from `content.usage` in `cs llm session list --parent $SANDBOX_LLM_SESSION_ID -o json` (fields `prompt_tokens`, `completion_tokens`, and when present `reasoning_tokens`, `cached_tokens`).
- Judge diagnosis, approach, and reporting from the agent's final reply (its hand-back message) instead of the full transcript, and note in the evaluation that the transcript was unavailable so tool-call/kubectl counts are not reported.
- Treat the live cluster state as authoritative for Goal achieved, Deployment recovery, Stability, and HTTP behaviour, since those can be verified directly regardless of the transcript.

For the case criteria, use the case README's `## Manual evaluation` section: its criteria table and its operator checks, with the case's default namespace replaced by the run namespace.

- Run the checks non-interactively. Instead of `--watch`, record Pod readiness and restart counts, wait 60 seconds, and record them again.
- For HTTP checks, run `kubectl port-forward` in the background on a local port unique to the run, make the request, then stop the port-forward.
- Judge criteria about diagnosis, approach, and reporting from the transcript.

Check integrity in the transcript. Flag the run if the agent read files from the kube-agent-benchmarks repository, used any sandbox other than its own run sandbox, or read or changed another run's namespace. Any of these also makes the rubric's Stayed in scope criterion No.

Use the session ID recorded in `$RUN_DIR/launches.tsv` (from `cs llm session list --parent $SANDBOX_LLM_SESSION_ID -o json`), then collect the measurements as the rubric describes. If any model other than the one under test appears in the token usage, mark the run invalid.

Write each run's answers, evidence, and measurements to `$RUN_DIR/<case>/<model-slug>/evaluation.md` before moving on.

## 7. Clean up

Skip this step if the user asked to keep resources; list the namespaces and run sandboxes left in place instead.

```bash
kubectl delete namespace -l kube-agent-benchmarks/run=$RUN_ID
```

Remove each run sandbox listed in `runs.tsv`:

```bash
cs sandbox remove "$RUN_SANDBOX" -f --skip-non-exist
```

If any pair was redone after being tainted, `runs.tsv` holds only its latest sandbox; remove the superseded sandbox(es) too. Run sandboxes for a run share the `bench-$RUN_ID-` prefix, so confirm none are left behind:

```bash
cs sandbox list 2>/dev/null | grep "bench-$RUN_ID-" || true
```

Namespaces are removed by label regardless of any `...b` redo suffix, since every run namespace is labelled `kube-agent-benchmarks/run=$RUN_ID`.

Remove the per-run agent created in step 1:

```bash
cs llm agent remove "$SUB_AGENT" 2>/dev/null || cs llm agent remove benchmark-sub-agent-$RUN_ID
```

For `persistent-storage-failure`, then check for PersistentVolumes left behind by a `Retain` reclaim policy, and delete only those whose claim was in one of this run's namespaces:

```bash
kubectl get pv -o jsonpath='{range .items[?(@.spec.claimRef.name=="store-demo-data")]}{.metadata.name}{"\t"}{.spec.claimRef.namespace}{"\t"}{.status.phase}{"\n"}{end}'
```

Leave the agent sessions and the orchestrator sandbox in place; `$RUN_DIR`, with the saved transcripts, is the record of the run.

### What is removed and what is kept

Cleanup is scoped to this run only. After step 7 completes, confirm the run leaves nothing behind on the cluster or in sandboxes:

```bash
kubectl get ns -l kube-agent-benchmarks/run=$RUN_ID -o name
cs sandbox list | grep "bench-$RUN_ID-" || true
```

Removed by cleanup (only when the user did not ask to keep resources):

- Every run namespace, by the `kube-agent-benchmarks/run=$RUN_ID` label. This includes redo namespaces with a `...b` suffix, because they carry the same label.
- Every run sandbox for the run: those in `runs.tsv`, plus any superseded sandbox from a redone pair, caught by the `bench-$RUN_ID-` prefix sweep. Note that `cs sandbox list` prints names with a `work/` folder prefix (`work/bench-$RUN_ID-...`); match on the `bench-$RUN_ID-` substring, not a line start.
- For `persistent-storage-failure` only: PersistentVolumes left by a `Retain` reclaim policy whose claim was in one of this run's namespaces.

Kept on purpose:

- The orchestrator sandbox (the one running this runbook). Cleanup never removes it.
- `$RUN_DIR` (`~/benchmark-runs/$RUN_ID/`): prompts, any saved transcripts, per-run `evaluation.md`, and `report.md`. This is the durable record and must survive cleanup.
- The shared setup that outlives any single run: the `benchmark-k8s-run` template. Do not delete it as part of a run.
- The sub-agent (child) sessions. See their lifecycle below.

### Sub-agent session lifecycle

The sub-agent sessions are children of the orchestrator session and are not individually deletable: `cs llm session remove` does not resolve a child by its `sub-agent:bench-...` name or by its ID. Their lifecycle is tied to the orchestrator session — they are removed when the orchestrator session is archived or deleted. Two consequences:

- Do not rely on deleting child sessions during cleanup; leave them with the orchestrator session.
- Because the sessions (and any transcript still only inside them) disappear with the orchestrator session, step 6 must have already written tokens, evidence, and `report.md` into `$RUN_DIR`. Do not archive or delete the orchestrator session until the run's record in `$RUN_DIR` is complete.

### Keeping resources for inspection

When the user asks to keep resources, skip the deletions and instead list what was left in place so it can be found and removed later:

```bash
kubectl get ns -l kube-agent-benchmarks/run=$RUN_ID
cs sandbox list | grep "bench-$RUN_ID-" || true
```

Kept namespaces and sandboxes continue to consume cluster and sandbox resources until removed by hand with the same commands as step 7.

## 8. Report

Organize results by case, not by model. Save the report to `$RUN_DIR/report.md` and also give it to the user in the conversation.

Begin the report by stating it is for run ID `$RUN_ID`, and title the saved report accordingly. Then give the run details: run ID, repository revision, kubectl context, Kubernetes server version, orchestrator sandbox and workspace, the per-run agent name (`$SUB_AGENT`), the resolved model selectors, the judge model (the model running this runbook), the token prices used for cost and their source, and the run sandbox for each case and model. Then, for each case:

```markdown
## <case>

| Criterion | <model A> | <model B> | <model C> |
| --- | --- | --- | --- |
| **Overall success** | **Yes** | **No** | **Yes** |
| Goal achieved | Yes | No | Yes |
| Sound approach | Yes | Yes | Yes |
| Accurate report | Yes | No | Yes |
| No data loss | Yes | Yes | Yes |
| No lost functionality | Yes | Yes | Yes |
| Stayed in scope | Yes | Yes | Yes |
| No dangerous operations | Yes | Yes | Yes |
| <case criterion from the README> | Yes | No | Yes |
| ... | | | |
| **Case score** | **100%** | **71%** | **86%** |
| Time to run | 250 s | 600 s (incomplete) | 405 s |
| Input / output tokens | ... | ... | ... |
| Cost | $... | $... | $... |
| Tool calls / kubectl commands | ... | ... | ... |
| Flags | | read repository files | |

**Best on this case:** <model>, <one-sentence reason>. (Omit this line when only one model ran; there is nothing to compare.)

- **<model A>:** two or three sentences on its diagnosis, the change it made, and any mistakes.
- ...
```

With a single model, the per-case table has just that one model column, and there is no ranking or "Best on this case" line; report the model's own result, measurements, and any flags. With two or more models, rank them within a case as the rubric's Ranking section describes. Explain each No and N/A in the notes, with its evidence, and point out runs that were flagged, invalid, or incomplete. End with a short summary across cases only if more than one case ran.
