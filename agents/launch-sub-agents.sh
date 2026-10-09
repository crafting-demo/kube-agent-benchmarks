#!/usr/bin/env bash
# Creates the run sandboxes for one benchmark case and starts benchmark-sub-agent
# in each, one session per model. Step 4 of orchestrator-runbook.md runs it once
# per case, from the orchestrator sandbox.
#
# Usage: launch-sub-agents.sh RUN_DIR CASE
#
# Reads from RUN_DIR:
#   run.env                    RUN_ID and CONTEXT
#   kubeconfig                 kubeconfig containing only CONTEXT
#   models.tsv                 <model-slug> TAB <model selector>
#   runs.tsv                   <case> TAB <model-slug> TAB <namespace> TAB <sandbox>
#   <case>/<model-slug>/prompt.md
#
# Appends one line per started session to RUN_DIR/launches.tsv:
#   <case> TAB <model-slug> TAB <session> TAB <sandbox> TAB <launch time, epoch seconds>
#
# Every session is started as a task with --parent set to the session running
# this script ($SANDBOX_LLM_SESSION_ID, set by Crafting in the workspace agent's
# shell), so it is listed under the orchestrator session and shares its
# lifecycle. Run by hand outside a session, the sessions start without a parent.
set -euo pipefail

usage="usage: launch-sub-agents.sh RUN_DIR CASE"
RUN_DIR=${1:?$usage}
CASE=${2:?$usage}

SANDBOX_TEMPLATE=benchmark-k8s-run
WORKSPACE=app
WORKSPACE_UID=1000
SUB_AGENT=benchmark-sub-agent

# shellcheck source=/dev/null
. "$RUN_DIR/run.env"
: "${RUN_ID:?run.env must set RUN_ID}"
: "${CONTEXT:?run.env must set CONTEXT}"

pairs=$(awk -F'\t' -v c="$CASE" '$1 == c' "$RUN_DIR/runs.tsv")
if [ -z "$pairs" ]; then
  echo "No runs for case $CASE in $RUN_DIR/runs.tsv" >&2
  exit 1
fi

model_for() {
  awk -F'\t' -v s="$1" '$1 == s { print $2 }' "$RUN_DIR/models.tsv"
}

# Creates the sandbox, copies the kubeconfig in as the workspace user, and
# checks that the run namespace is reachable from inside the sandbox.
prepare_sandbox() {
  local sandbox=$1 namespace=$2
  cs sandbox create "$sandbox" -t "$SANDBOX_TEMPLATE" </dev/null &&
    cs wait sandbox "$sandbox" --expect ready --timeout 10m </dev/null &&
    cs exec -T -u "$WORKSPACE_UID" -W "$sandbox/$WORKSPACE" -- \
      sh -c 'umask 077 && mkdir -p ~/.kube && cat > ~/.kube/config' <"$RUN_DIR/kubeconfig" &&
    cs exec -T -u "$WORKSPACE_UID" -W "$sandbox/$WORKSPACE" -- \
      kubectl --context "$CONTEXT" -n "$namespace" get all </dev/null
}

# Check every run of the case before creating anything.
while IFS=$'\t' read -r -u 3 _ slug namespace sandbox; do
  if [ -z "$(model_for "$slug")" ]; then
    echo "No model for $slug in $RUN_DIR/models.tsv" >&2
    exit 1
  fi
  if [ ! -f "$RUN_DIR/$CASE/$slug/prompt.md" ]; then
    echo "Missing $RUN_DIR/$CASE/$slug/prompt.md" >&2
    exit 1
  fi
  if cs sandbox show "$sandbox" >/dev/null 2>&1 </dev/null; then
    echo "Sandbox $sandbox already exists; it is not reused" >&2
    exit 1
  fi
done 3<<<"$pairs"

# Create all of the case's sandboxes first, so the sessions start back to back.
while IFS=$'\t' read -r -u 3 _ slug namespace sandbox; do
  echo "Creating sandbox $sandbox for $CASE / $slug"
  if ! prepare_sandbox "$sandbox" "$namespace"; then
    echo "Sandbox $sandbox failed; creating it once more" >&2
    cs sandbox remove "$sandbox" -f --skip-non-exist </dev/null
    if ! prepare_sandbox "$sandbox" "$namespace"; then
      echo "Sandbox $sandbox failed twice" >&2
      exit 1
    fi
  fi
done 3<<<"$pairs"

parent_args=()
if [ -n "${SANDBOX_LLM_SESSION_ID:-}" ]; then
  parent_args=(--parent "$SANDBOX_LLM_SESSION_ID")
fi

while IFS=$'\t' read -r -u 3 _ slug namespace sandbox; do
  model=$(model_for "$slug")
  session="bench-$RUN_ID-$CASE-$slug"
  launched=$(date +%s)
  cs llm session run @"$RUN_DIR/$CASE/$slug/prompt.md" \
    ${parent_args[@]+"${parent_args[@]}"} \
    --agent "$SUB_AGENT" \
    --task \
    --name "$session" \
    --model-map CODING="$model" --model-map GENERIC="$model" --model-map FAST="$model" \
    --approval auto \
    -W "$sandbox/$WORKSPACE" \
    --wait=false </dev/null
  printf '%s\t%s\t%s\t%s\t%s\n' "$CASE" "$slug" "$session" "$sandbox" "$launched" >>"$RUN_DIR/launches.tsv"
  echo "Started $session on $model in $sandbox"
done 3<<<"$pairs"
