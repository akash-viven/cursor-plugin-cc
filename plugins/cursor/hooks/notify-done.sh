#!/usr/bin/env bash
# notify-done.sh — Stop/SubagentStop hook for the cursor handoff plugin.
#
# When a delegated cursor-agent job finishes in the background, Claude has no
# way to know unless the user polls /cursor:status. This hook closes that gap:
# on every Stop it scans for jobs that became terminal recently and were not yet
# announced, then feeds a one-line-per-job summary back as additionalContext so
# Claude becomes aware mid-turn. It also fires a best-effort desktop notification.
#
# Silent (exit 0, no output) when there is nothing new — never blocks the Stop.
#
# Env knobs:
#   CURSOR_PLUGIN_NOTIFY_WINDOW_MIN  ignore jobs whose status is older than this
#                                    many minutes (default 30). Stops historical
#                                    jobs from being replayed on the first Stop.
#   CURSOR_PLUGIN_NOTIFY_DESKTOP=0   disable the desktop notification.
set -u

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HOOKS_DIR/../scripts/lib.sh"
[ -f "$LIB" ] || exit 0

# Hook input arrives as JSON on stdin. We only need the event name (to echo it
# back correctly in hookSpecificOutput) — best effort, default to "Stop".
INPUT="$(cat 2>/dev/null || true)"
EVENT="Stop"
HOOK_CWD="$PWD"
if command -v jq >/dev/null 2>&1 && [ -n "$INPUT" ]; then
  e="$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null || true)"
  [ -n "$e" ] && EVENT="$e"
  cw="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
  [ -n "$cw" ] && HOOK_CWD="$cw"
fi
# Announce only jobs belonging to this session's repo/folder — the store is
# global, so without this a job finishing in another repo would surface here.
SCOPE_ROOT="$(git -C "$HOOK_CWD" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$HOOK_CWD")"

WINDOW_MIN="${CURSOR_PLUGIN_NOTIFY_WINDOW_MIN:-30}"
case "$WINDOW_MIN" in ''|*[!0-9]*) WINDOW_MIN=30;; esac

# Scan for newly-finished jobs. Defined as a function (NOT inline in $(...)):
# bash 3.2's command-substitution parser is not syntax-aware, so a `)` in a
# `case` pattern inside $(...) prematurely closes the substitution. As a
# top-level function it parses fine; calling it via $(_scan) is paren-free.
# Sourcing lib here is safe — _scan only ever runs inside $(...) (a subshell),
# so lib's `set -e`/pipefail stay contained.
_scan() {
  . "$LIB" 2>/dev/null || return 0
  ensure_store
  shopt -s nullglob
  local out="" d id st prompt el files usage line
  for d in "$JOBS_DIR"/*/; do
    id="$(basename "$d")"
    st="$(job_status "$id")"
    case "$st" in
      done|failed|crashed|cancelled) ;;
      *) continue;;
    esac
    job_in_scope "$id" "$SCOPE_ROOT" || continue
    [ -f "$d/announced" ] && continue
    # Only announce jobs that finished recently (status file freshly written).
    if [ -z "$(find "$d/status" -mmin "-$WINDOW_MIN" 2>/dev/null)" ]; then
      continue
    fi
    printf 'done' > "$d/announced"   # mark first => never double-announce
    prompt="$(job_field "$id" prompt | tr '\n' ' ')"
    [ "${#prompt}" -gt 60 ] && prompt="${prompt:0:59}…"
    el="$(fmt_elapsed "$(job_elapsed "$id")")"
    files="$(job_changed_files "$id" | awk 'NF' | wc -l | tr -d ' ')"
    usage="$(job_usage_line "$id")"
    line="- [$st] ${id:0:8} · ${el} · ${files} files"
    [ -n "$usage" ] && line="$line · $usage"
    line="$line: $prompt"
    out="${out}${line}"$'\n'
  done
  printf '%s' "$out"
}

SUMMARY="$(_scan)"
[ -n "$SUMMARY" ] || exit 0   # nothing new — stay silent

COUNT="$(printf '%s\n' "$SUMMARY" | grep -c '^- ' 2>/dev/null || true)"
[ -n "$COUNT" ] || COUNT=0

# Best-effort desktop notification (non-fatal).
if [ "${CURSOR_PLUGIN_NOTIFY_DESKTOP:-1}" = "1" ]; then
  title="Cursor handoff"
  body="$COUNT job(s) finished"
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"$body\" with title \"$title\"" >/dev/null 2>&1 || true
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send "$title" "$body" >/dev/null 2>&1 || true
  fi
fi

CONTEXT="$(printf 'Background cursor-agent job(s) finished since the last turn:\n%s\nUse /cursor:result <id> for output or /cursor:diff <id> to review changes.' "$SUMMARY")"

if command -v jq >/dev/null 2>&1; then
  jq -cn --arg e "$EVENT" --arg c "$CONTEXT" \
    '{hookSpecificOutput:{hookEventName:$e,additionalContext:$c}}'
fi
exit 0
