#!/usr/bin/env bash
# delegate.sh — hand a task to cursor-agent as a detached background job.
# Usage: delegate.sh [--model M] [--worktree] [--foreground] -- <prompt...>
#        delegate.sh <prompt...>
# Prints the job id on stdout. Job state lands in $JOBS_DIR/<id>/.

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

MODEL=""
WORKTREE=0
FOREGROUND=0
PROMPT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --model) MODEL="${2:-}"; shift 2;;
    --worktree) WORKTREE=1; shift;;
    --foreground) FOREGROUND=1; shift;;
    --) shift; PROMPT="$*"; break;;
    *) PROMPT="$*"; break;;
  esac
done

[ -n "$PROMPT" ] || die "no prompt given. Usage: delegate.sh <task description>"
require_agent
ensure_store

ID="$(new_job_id)"
JD="$(job_dir "$ID")"
mkdir -p "$JD"

# Persist metadata up front so status/result work even before completion.
printf '%s' "$PWD"    > "$JD/cwd"
printf '%s' "$PROMPT" > "$JD/prompt"
printf '%s' "$MODEL"  > "$JD/model"
printf '%s' "$(date +%s)" > "$JD/started"
printf 'running'      > "$JD/status"

# Build the cursor-agent argv. Headless + unattended posture (see README).
# stream-json => NDJSON events land in output.json live, enabling progress view.
AGENT_ARGS=(-p "$PROMPT" --output-format stream-json --force --trust --sandbox disabled --workspace "$PWD")
[ -n "$MODEL" ] && AGENT_ARGS+=(--model "$MODEL")
[ "$WORKTREE" -eq 1 ] && AGENT_ARGS+=(--worktree)

run_job() {
  # Runs the agent, captures output, then finalizes. Designed to be detached.
  set +e
  "$CURSOR_AGENT_BIN" "${AGENT_ARGS[@]}" > "$JD/output.json" 2> "$JD/err.log"
  local rc=$?
  printf '%s' "$rc" > "$JD/exit_code"
  CURSOR_PLUGIN_HOME="$CURSOR_PLUGIN_HOME" finalize_job "$ID"
  # If the agent itself exited non-zero but wrote no error object, mark failed.
  if [ "$rc" -ne 0 ] && [ "$(job_field "$ID" status)" = "running" ]; then
    printf 'failed' > "$JD/status"
  fi
}

if [ "$FOREGROUND" -eq 1 ]; then
  run_job
else
  # Detach fully: own session, no controlling terminal, survive parent exit.
  ( run_job ) >/dev/null 2>&1 &
  printf '%s' "$!" > "$JD/pid"
  disown 2>/dev/null || true
fi

printf '%s\n' "$ID"
