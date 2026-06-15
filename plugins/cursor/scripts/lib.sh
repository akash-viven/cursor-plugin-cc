#!/usr/bin/env bash
# lib.sh — shared helpers for the cursor handoff plugin.
# Sourced by every command script. No side effects on source.

set -euo pipefail

# Root of the job store. Overridable for tests via CURSOR_PLUGIN_HOME.
CURSOR_PLUGIN_HOME="${CURSOR_PLUGIN_HOME:-$HOME/.cursor-plugin}"
JOBS_DIR="$CURSOR_PLUGIN_HOME/jobs"

# Binary to drive. Overridable for tests via CURSOR_AGENT_BIN.
CURSOR_AGENT_BIN="${CURSOR_AGENT_BIN:-cursor-agent}"

# Prune finished jobs older than this many days. 0 disables pruning.
CURSOR_PLUGIN_PRUNE_DAYS="${CURSOR_PLUGIN_PRUNE_DAYS:-7}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*" >&2; }

# Confirm cursor-agent is reachable. Used by preflight paths.
require_agent() {
  command -v "$CURSOR_AGENT_BIN" >/dev/null 2>&1 \
    || die "cursor-agent not found on PATH. Run /cursor:setup or install: curl https://cursor.com/install -fsS | bash"
}

ensure_store() { mkdir -p "$JOBS_DIR"; }

# Generate a sortable, collision-resistant job id.
# Format: <epoch>-<pid>-<rand>. Epoch first => lexical sort == chronological.
new_job_id() {
  local epoch pid rand
  epoch="$(date +%s)"
  pid="$$"
  rand="$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d ' ' || echo "")"
  [ -n "$rand" ] || rand="${RANDOM}${RANDOM}"
  printf '%s-%s-%s%s' "$epoch" "$pid" "$rand" "$RANDOM"
}

job_dir() { printf '%s/%s' "$JOBS_DIR" "$1"; }

# Read a single-line job field; empty string if absent.
job_field() {
  local id="$1" field="$2" f
  f="$(job_dir "$id")/$field"
  [ -f "$f" ] && cat "$f" || printf ''
}

job_exists() { [ -d "$(job_dir "$1")" ]; }

# Resolve a possibly-partial id to a full id. Exact match wins; otherwise
# match by prefix, erroring on ambiguity. Enables short ids in commands.
resolve_job_id() {
  local want="$1" d base matches=()
  ensure_store
  if job_exists "$want"; then printf '%s' "$want"; return 0; fi
  for d in "$JOBS_DIR"/*/; do
    [ -d "$d" ] || continue
    base="$(basename "$d")"
    case "$base" in "$want"*) matches+=("$base");; esac
  done
  case "${#matches[@]}" in
    0) die "no job matching '$want'";;
    1) printf '%s' "${matches[0]}";;
    *) die "ambiguous id '$want' matches: ${matches[*]}";;
  esac
}

# Is the recorded PID still alive?
job_running() {
  local pid; pid="$(job_field "$1" pid)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# Compute the live status: a job marked 'running' whose pid died without
# writing a terminal status is reported 'crashed'.
job_status() {
  local id="$1" s; s="$(job_field "$id" status)"
  if [ "$s" = "running" ] && ! job_running "$id"; then
    printf 'crashed'
  else
    printf '%s' "${s:-unknown}"
  fi
}

# Parse the captured cursor-agent JSON output into terminal job files.
# cursor-agent --output-format json emits one object:
#   {"type":"result","is_error":bool,"result":"...","session_id":"..."}
finalize_job() {
  local id="$1" dir out
  dir="$(job_dir "$id")"
  out="$dir/output.json"
  if [ ! -s "$out" ]; then
    printf 'failed' > "$dir/status"
    printf 'no output captured from cursor-agent\n' > "$dir/result.txt"
    return 0
  fi
  # Tolerate either a single json object or stream-json (take last result line).
  local obj
  obj="$(jq -c 'select(.type=="result")' "$out" 2>/dev/null | tail -n1 || true)"
  if [ -z "$obj" ]; then
    # Not parseable as a result object; treat raw text as the result.
    printf 'failed' > "$dir/status"
    cp "$out" "$dir/result.txt"
    return 0
  fi
  local is_err result session
  is_err="$(printf '%s' "$obj" | jq -r '.is_error // false')"
  result="$(printf '%s' "$obj" | jq -r '.result // ""')"
  session="$(printf '%s' "$obj" | jq -r '.session_id // ""')"
  printf '%s' "$result" > "$dir/result.txt"
  [ -n "$session" ] && printf '%s' "$session" > "$dir/session_id"
  if [ "$is_err" = "true" ]; then
    printf 'failed' > "$dir/status"
  else
    printf 'done' > "$dir/status"
  fi
}

# Recursively TERM a pid and all its descendants (depth-first, children first).
kill_tree() {
  local pid="$1" child
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do
    kill_tree "$child"
  done
  kill -TERM "$pid" 2>/dev/null || true
}

# Remove finished job dirs older than CURSOR_PLUGIN_PRUNE_DAYS.
prune_jobs() {
  ensure_store
  [ "$CURSOR_PLUGIN_PRUNE_DAYS" -gt 0 ] || return 0
  local d base st
  for d in "$JOBS_DIR"/*/; do
    [ -d "$d" ] || continue
    base="$(basename "$d")"
    st="$(job_status "$base")"
    case "$st" in running) continue;; esac
    # -mtime +N: strictly older than N*24h.
    if [ -n "$(find "$d" -maxdepth 0 -mtime "+$CURSOR_PLUGIN_PRUNE_DAYS" 2>/dev/null)" ]; then
      rm -rf "$d"
    fi
  done
}
