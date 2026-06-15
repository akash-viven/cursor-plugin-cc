#!/usr/bin/env bash
# live-3.sh — run real cursor-agent delegations across 3 different models and
# verify the new v0.3.0 features end-to-end (usage capture, /cursor:diff,
# completion hook). Uses an isolated job store + throwaway git repos. NOT mocked.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="$ROOT/plugins/cursor/scripts"
HOOK="$ROOT/plugins/cursor/hooks/notify-done.sh"

export CURSOR_PLUGIN_HOME="$(mktemp -d)/home"; mkdir -p "$CURSOR_PLUGIN_HOME/jobs"
unset CURSOR_AGENT_BIN   # use the real installed cursor-agent

MODELS=("composer-2.5-fast" "gpt-5.5-high-fast" "claude-opus-4-8-thinking-high-fast")

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '   ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '   FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }
has() { case "$2" in *"$3"*) ok "$1";; *) bad "$1" "missing [$3] in: ${2:0:120}";; esac; }

n=0
for M in "${MODELS[@]}"; do
  n=$((n+1))
  printf '\n=== run %d/3 · model: %s ===\n' "$n" "$M"
  GR="$(mktemp -d)"
  ( cd "$GR" && git init -q && git config user.email t@t.t && git config user.name t \
    && printf 'seed\n' > note.txt && git add . && git commit -qm init )
  MARK="MARKER_${n}_$RANDOM"
  TASK="Append a line containing exactly ${MARK} to note.txt in the current directory. Then reply with exactly the word DONE and nothing else."

  start=$(date +%s)
  ID="$(cd "$GR" && "$SCRIPTS/delegate.sh" --foreground --model "$M" -- "$TASK")"
  rc=$?
  end=$(date +%s)
  if [ -z "$ID" ] || [ "$rc" -ne 0 ]; then bad "[$M] delegate ran" "rc=$rc id=$ID"; continue; fi

  st="$( . "$SCRIPTS/lib.sh"; job_status "$ID" )"
  ti="$(cat "$CURSOR_PLUGIN_HOME/jobs/$ID/tokens_in" 2>/dev/null || echo -)"
  to="$(cat "$CURSOR_PLUGIN_HOME/jobs/$ID/tokens_out" 2>/dev/null || echo -)"
  co="$(cat "$CURSOR_PLUGIN_HOME/jobs/$ID/cost_usd" 2>/dev/null || echo -)"
  rmodel="$( . "$SCRIPTS/lib.sh"; job_model "$ID" )"
  files="$( . "$SCRIPTS/lib.sh"; job_changed_files "$ID" )"
  diff="$("$SCRIPTS/diff.sh" "$ID" 2>&1)"
  res="$("$SCRIPTS/result.sh" "$ID" 2>&1)"
  HIN='{"hook_event_name":"Stop","cwd":"'"$GR"'"}'
  hook="$(printf '%s' "$HIN" | CURSOR_PLUGIN_NOTIFY_DESKTOP=0 "$HOOK" 2>/dev/null)"

  printf '   job %s · status=%s · wall=%ss · model=%s\n' "${ID:0:8}" "$st" "$((end-start))" "$rmodel"
  printf '   tokens: in=%s out=%s · cost=%s\n' "$ti" "$to" "$co"
  printf '   changed: %s\n' "$(printf '%s' "$files" | tr '\n' ' ')"

  has "[$M] status done"            "$st" "done"
  has "[$M] note.txt in changes"    "$files" "note.txt"
  has "[$M] diff shows marker"      "$diff" "$MARK"
  has "[$M] file on disk has marker" "$(cat "$GR/note.txt")" "$MARK"
  [ -n "$ti$to" ] && [ "$ti$to" != "--" ] && ok "[$M] usage captured" || bad "[$M] usage captured" "in=$ti out=$to"
  has "[$M] result shows session"   "$res" "session"
  has "[$M] hook announced job"     "$hook" "${ID:0:8}"
  rm -rf "$GR"
done

printf '\n=== live summary: PASS=%d FAIL=%d ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
