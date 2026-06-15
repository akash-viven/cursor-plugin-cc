#!/usr/bin/env bash
# status.sh — list cursor handoff jobs (newest first) or show one job live.
# Usage: status.sh [id]
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

ensure_store
prune_jobs

# Short id for display: trailing entropy trimmed, enough to stay unique-ish.
short_id() { printf '%s' "${1:0:18}"; }

# A single dense line for the list view.
print_row() {
  local id="$1" st icon prompt model el
  st="$(job_status "$id")"
  icon="$(status_icon "$st")"
  prompt="$(job_field "$id" prompt | tr '\n' ' ')"
  model="$(job_model "$id")"
  el="$(fmt_elapsed "$(job_elapsed "$id")")"
  [ "${#prompt}" -gt 48 ] && prompt="${prompt:0:47}…"
  printf '  %s %-9s %-7s %-18s %s\n' \
    "$icon" "$(status_color "$st")" "$el" "$(dim "$(short_id "$id")")" "$prompt"
}

# A detailed, live card for one job.
print_card() {
  local id="$1" st icon el model session tools
  st="$(job_status "$id")"
  icon="$(status_icon "$st")"
  el="$(fmt_elapsed "$(job_elapsed "$id")")"
  model="$(job_model "$id")"
  session="$(job_session "$id")"
  tools="$(job_tool_count "$id")"

  local spin=''
  [ "$st" = "running" ] && spin="$(spinner_frame "$(job_elapsed "$id")")  "

  printf '\n'
  printf '  %s %s   %s%s\n' "$icon" "$(status_color "$st")" "$spin" "$(dim "$el")"
  printf '  %s\n' "$(job_field "$id" prompt | tr '\n' ' ')"
  printf '\n'
  printf '  %s  %s\n' "$(dim 'id     ')" "$id"
  printf '  %s  %s\n' "$(dim 'model  ')" "$model"
  [ -n "$session" ] && printf '  %s  %s\n' "$(dim 'session')" "$session"
  printf '  %s  %s\n' "$(dim 'tools  ')" "$tools calls"

  local act; act="$(job_activity "$id" 6)"
  if [ -n "$act" ]; then
    printf '\n  %s\n' "$(bold 'recent activity')"
    printf '%s\n' "$act" | while IFS= read -r line; do printf '  %s\n' "$(dim "$line")"; done
  fi

  local files; files="$(job_changed_files "$id")"
  if [ -n "$files" ]; then
    printf '\n  %s\n' "$(bold 'changed files')"
    printf '%s\n' "$files" | while IFS= read -r f; do printf '  %s %s\n' "$(c 32 '+')" "$f"; done
  fi

  if [ "$st" = "running" ]; then
    printf '\n  %s\n' "$(dim "live — re-run /cursor:status ${id:0:8} to refresh")"
  else
    printf '\n  %s\n' "$(dim "done — /cursor:result ${id:0:8} for full output")"
  fi
  printf '\n'
}

if [ $# -ge 1 ]; then
  id="$(resolve_job_id "$1")"
  print_card "$id"
  exit 0
fi

shopt -s nullglob
jobs=("$JOBS_DIR"/*/)
if [ "${#jobs[@]}" -eq 0 ]; then
  printf '\n  %s\n\n' "$(dim 'no jobs yet — start one with /cursor:delegate <task>')"
  exit 0
fi

printf '\n  %s\n\n' "$(bold 'cursor jobs')"
# Sort by id descending => newest first (ids are epoch-prefixed).
for d in $(printf '%s\n' "${jobs[@]}" | xargs -n1 basename | sort -r); do
  print_row "$d"
done
printf '\n  %s\n\n' "$(dim 'detail: /cursor:status <id>   ·   result: /cursor:result <id>')"
