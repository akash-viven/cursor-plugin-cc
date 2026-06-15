#!/usr/bin/env bash
# status.sh — list cursor handoff jobs (newest first) and prune stale ones.
# Usage: status.sh [id]
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

ensure_store
prune_jobs

print_row() {
  local id="$1" st prompt model
  st="$(job_status "$id")"
  prompt="$(job_field "$id" prompt | tr '\n' ' ')"
  model="$(job_field "$id" model)"
  [ -n "$model" ] || model="(default)"
  [ "${#prompt}" -gt 60 ] && prompt="${prompt:0:57}..."
  printf '%-26s  %-8s  %-14s  %s\n' "$id" "$st" "$model" "$prompt"
}

if [ $# -ge 1 ]; then
  id="$(resolve_job_id "$1")"
  printf '%-26s  %-8s  %-14s  %s\n' "JOB ID" "STATUS" "MODEL" "PROMPT"
  print_row "$id"
  exit 0
fi

shopt -s nullglob
jobs=("$JOBS_DIR"/*/)
if [ "${#jobs[@]}" -eq 0 ]; then
  log "no jobs. Start one with /cursor:delegate <task>"
  exit 0
fi

printf '%-26s  %-8s  %-14s  %s\n' "JOB ID" "STATUS" "MODEL" "PROMPT"
# Sort by id descending => newest first (ids are epoch-prefixed).
for d in $(printf '%s\n' "${jobs[@]}" | xargs -n1 basename | sort -r); do
  print_row "$d"
done
