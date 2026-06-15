#!/usr/bin/env bash
# statusline.sh — compact ambient summary of active cursor handoff jobs, for use
# as a Claude Code statusLine command. Prints one short line, e.g.
#     ◐ 2 cursor · 3m 12s
# (count of running jobs + spinner + elapsed of the longest-running one), or
# nothing at all when no jobs are running. Reads job state directly; the
# statusLine stdin JSON is ignored.
#
# Opt in via your Claude Code settings.json:
#   "statusLine": {
#     "type": "command",
#     "command": "~/.claude/plugins/<…>/cursor/scripts/statusline.sh"
#   }
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh" 2>/dev/null || exit 0

cat >/dev/null 2>&1 || true   # drain the statusLine JSON on stdin, unused

ensure_store
shopt -s nullglob

# Only count jobs that belong to the current repo/folder — the store is global.
ROOT="$(job_scope_root)"

running=0
max_el=0
for d in "$JOBS_DIR"/*/; do
  id="$(basename "$d")"
  [ "$(job_status "$id")" = "running" ] || continue
  job_in_scope "$id" "$ROOT" || continue
  running=$((running + 1))
  el="$(job_elapsed "$id")"
  case "$el" in ''|*[!0-9]*) el=0;; esac
  [ "$el" -gt "$max_el" ] && max_el="$el"
done

[ "$running" -gt 0 ] || exit 0   # idle: empty statusline

printf '%s %s cursor · %s\n' \
  "$(spinner_frame "$max_el")" "$running" "$(fmt_elapsed "$max_el")"
