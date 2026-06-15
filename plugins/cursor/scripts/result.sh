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

case "$st" in
  running) log "job $id still running. Check /cursor:status or try again."; exit 0;;
  crashed) log "job $id crashed (process died, no result). See $jd/err.log"; exit 1;;
esac

printf '=== job %s [%s] ===\n' "$id" "$st"
if [ -s "$jd/result.txt" ]; then
  cat "$jd/result.txt"; printf '\n'
else
  log "(no result text captured)"
fi

session="$(job_field "$id" session_id)"
if [ -n "$session" ]; then
  printf '\n--- resume this thread ---\n'
  printf 'session: %s\n' "$session"
  printf 'continue with: /cursor:resume %s <new instructions>\n' "$id"
fi
