#!/usr/bin/env bash
# resume.sh — continue a finished job's session with new instructions.
# Spawns a NEW job that resumes the prior session_id. Usage:
#   resume.sh <id> [--model M] [--foreground] -- <new prompt...>
#   resume.sh <id> <new prompt...>
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

[ $# -ge 2 ] || die "usage: resume.sh <id> <new instructions>"
SRC_ID="$(resolve_job_id "$1")"; shift

MODEL=""
FOREGROUND=0
PROMPT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --model) MODEL="${2:-}"; shift 2;;
    --foreground) FOREGROUND=1; shift;;
    --) shift; PROMPT="$*"; break;;
    *) PROMPT="$*"; break;;
  esac
done
[ -n "$PROMPT" ] || die "no new instructions given"

session="$(job_field "$SRC_ID" session_id)"
[ -n "$session" ] || die "job $SRC_ID has no session_id to resume"
require_agent
ensure_store

# Resume runs in the original job's cwd so edits land in the same repo.
src_cwd="$(job_field "$SRC_ID" cwd)"
[ -d "$src_cwd" ] || src_cwd="$PWD"

ID="$(new_job_id)"
JD="$(job_dir "$ID")"
mkdir -p "$JD"
printf '%s' "$src_cwd" > "$JD/cwd"
printf '%s' "$PROMPT"  > "$JD/prompt"
printf '%s' "$MODEL"   > "$JD/model"
printf '%s' "$session" > "$JD/resumed_from_session"
printf '%s' "$SRC_ID"  > "$JD/resumed_from_job"
printf '%s' "$(date +%s)" > "$JD/started"
printf 'running'       > "$JD/status"

AGENT_ARGS=(--resume "$session" -p "$PROMPT" --output-format stream-json --force --trust --sandbox disabled --workspace "$src_cwd")
[ -n "$MODEL" ] && AGENT_ARGS+=(--model "$MODEL")

run_job() {
  set +e
  ( cd "$src_cwd" && "$CURSOR_AGENT_BIN" "${AGENT_ARGS[@]}" ) > "$JD/output.json" 2> "$JD/err.log"
  local rc=$?
  printf '%s' "$rc" > "$JD/exit_code"
  CURSOR_PLUGIN_HOME="$CURSOR_PLUGIN_HOME" finalize_job "$ID"
  if [ "$rc" -ne 0 ] && [ "$(job_field "$ID" status)" = "running" ]; then
    printf 'failed' > "$JD/status"
  fi
}

if [ "$FOREGROUND" -eq 1 ]; then
  run_job
else
  ( run_job ) >/dev/null 2>&1 &
  printf '%s' "$!" > "$JD/pid"
  disown 2>/dev/null || true
fi
printf '%s\n' "$ID"
