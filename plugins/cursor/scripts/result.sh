#!/usr/bin/env bash
# result.sh — show the final result of a job (and how to resume it).
# Usage: result.sh <id> [--json]
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

[ $# -ge 1 ] || die "usage: result.sh <id> [--json]"
RAW=0
ARG=""
for a in "$@"; do
  case "$a" in --json) RAW=1;; *) ARG="$a";; esac
done
[ -n "$ARG" ] || die "no job id given"

id="$(resolve_job_id "$ARG")"
jd="$(job_dir "$id")"
st="$(job_status "$id")"

if [ "$RAW" -eq 1 ]; then
  [ -s "$jd/output.json" ] && cat "$jd/output.json" || die "no raw output for $id"
  exit 0
fi

if [ "$st" = "running" ]; then
  log "job ${id:0:8} still running — /cursor:status ${id:0:8} for live progress"
  exit 0
fi

icon="$(status_icon "$st")"
el="$(fmt_elapsed "$(job_elapsed "$id")")"
model="$(job_model "$id")"

printf '\n'
printf '  %s %s   %s\n' "$icon" "$(status_color "$st")" "$(dim "$el · $model")"
printf '  %s\n' "$(job_field "$id" prompt | tr '\n' ' ')"

# What it touched, before the prose result.
files="$(job_changed_files "$id")"
if [ -n "$files" ]; then
  printf '\n  %s\n' "$(bold 'changed files')"
  printf '%s\n' "$files" | while IFS= read -r f; do printf '  %s %s\n' "$(c 32 '+')" "$f"; done
fi

act="$(job_activity "$id" 8)"
if [ -n "$act" ]; then
  printf '\n  %s\n' "$(bold 'activity')"
  printf '%s\n' "$act" | while IFS= read -r line; do printf '  %s\n' "$(dim "$line")"; done
fi

printf '\n  %s\n' "$(bold 'result')"
if [ "$st" = "crashed" ]; then
  printf '  %s\n' "$(c 31 'process died before writing a result')"
  [ -s "$jd/err.log" ] && printf '  %s\n' "$(dim "see $jd/err.log")"
elif [ -s "$jd/result.txt" ]; then
  while IFS= read -r line || [ -n "$line" ]; do printf '  %s\n' "$line"; done < "$jd/result.txt"
else
  printf '  %s\n' "$(dim '(no result text captured)')"
fi

session="$(job_session "$id")"
if [ -n "$session" ]; then
  printf '\n  %s\n' "$(bold 'resume this thread')"
  printf '  %s %s\n' "$(dim 'session ')" "$session"
  printf '  %s %s\n' "$(dim 'continue')" "/cursor:resume ${id:0:8} <new instructions>"
fi
printf '\n'
