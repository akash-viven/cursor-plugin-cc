#!/usr/bin/env bash
# Test harness for the cursor handoff plugin. Pure bash, no bats needed.
# Uses a mock cursor-agent so no quota is consumed. Set CURSOR_LIVE=1 to also
# run a single real smoke test against the installed cursor-agent.
# NOTE: no `pipefail` on purpose — many tests pipe a command that intentionally
# exits non-zero (die) into grep; pipefail would mask the grep match.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="$ROOT/plugins/cursor/scripts"
MOCK="$ROOT/tests/mock-cursor-agent.sh"
chmod +x "$MOCK" "$SCRIPTS"/*.sh 2>/dev/null || true

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
assert_eq()       { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$3] got [$2]"; }
assert_contains() { case "$2" in *"$3"*) ok "$1";; *) bad "$1" "[$2] missing [$3]";; esac; }
assert_file()     { [ -f "$2" ] && ok "$1" || bad "$1" "missing file $2"; }

# Fresh, isolated environment per test run.
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
export CURSOR_PLUGIN_HOME="$SANDBOX/home"
export CURSOR_AGENT_BIN="$MOCK"
export CURSOR_PLUGIN_PRUNE_DAYS=7
WORK="$SANDBOX/repo"; mkdir -p "$WORK"

reset_store() { rm -rf "$CURSOR_PLUGIN_HOME"; mkdir -p "$CURSOR_PLUGIN_HOME/jobs"; }

# Read a job's live status via lib (subshell isolates lib's set -e/pipefail).
jstatus() { ( . "$SCRIPTS/lib.sh"; job_status "$1" ); }

# Wait until a job leaves 'running' or timeout (~10s).
wait_done() {
  local id="$1" i st
  for i in $(seq 1 50); do
    st="$(jstatus "$id")"
    case "$st" in running|"") sleep 0.2;; *) printf '%s' "$st"; return 0;; esac
  done
  printf '%s' "timeout"
}

echo "== lib unit tests =="
reset_store
ID_A="$(. "$SCRIPTS/lib.sh"; new_job_id)"
ID_B="$(. "$SCRIPTS/lib.sh"; new_job_id)"
[ "$ID_A" != "$ID_B" ] && ok "new_job_id unique" || bad "new_job_id unique" "both [$ID_A]"
case "$ID_A" in [0-9]*-[0-9]*-*) ok "new_job_id format";; *) bad "new_job_id format" "[$ID_A]";; esac

echo "== delegate (foreground, success) =="
reset_store
ID="$(cd "$WORK" && MOCK_RESULT="fixed the bug" MOCK_SESSION="sess-1" "$SCRIPTS/delegate.sh" --foreground -- "fix the bug")"
assert_contains "delegate prints id" "$ID" "-"
JD="$CURSOR_PLUGIN_HOME/jobs/$ID"
assert_eq  "status=done"       "$(cat "$JD/status")"     "done"
assert_eq  "result captured"   "$(cat "$JD/result.txt")" "fixed the bug"
assert_eq  "session captured"  "$(cat "$JD/session_id")" "sess-1"
assert_eq  "cwd recorded"      "$(cat "$JD/cwd")"        "$WORK"
assert_file "raw output kept"  "$JD/output.json"

echo "== delegate forwards correct agent flags =="
reset_store
ARGS="$SANDBOX/args.txt"; : > "$ARGS"
ID="$(cd "$WORK" && MOCK_ARGS_FILE="$ARGS" "$SCRIPTS/delegate.sh" --foreground --model gpt-5 -- "do x")"
A="$(cat "$ARGS")"
assert_contains "flag --force"    "$A" "--force"
assert_contains "flag --trust"    "$A" "--trust"
assert_contains "flag --sandbox"  "$A" "disabled"
assert_contains "flag --model"    "$A" "gpt-5"
assert_contains "flag --workspace" "$A" "$WORK"

echo "== delegate (is_error -> failed) =="
reset_store
ID="$(cd "$WORK" && MOCK_IS_ERROR=true "$SCRIPTS/delegate.sh" --foreground -- "boom")"
assert_eq "status=failed on is_error" "$(cat "$CURSOR_PLUGIN_HOME/jobs/$ID/status")" "failed"

echo "== delegate (no output -> failed) =="
reset_store
ID="$(cd "$WORK" && MOCK_NOOUT=1 MOCK_EXIT=1 "$SCRIPTS/delegate.sh" --foreground -- "silent")"
assert_eq "status=failed on no output" "$(cat "$CURSOR_PLUGIN_HOME/jobs/$ID/status")" "failed"

echo "== delegate (stream-json tolerated) =="
reset_store
ID="$(cd "$WORK" && MOCK_STREAM=1 MOCK_RESULT="streamed" "$SCRIPTS/delegate.sh" --foreground -- "stream")"
assert_eq "stream result parsed" "$(cat "$CURSOR_PLUGIN_HOME/jobs/$ID/result.txt")" "streamed"
assert_eq "stream status=done"   "$(cat "$CURSOR_PLUGIN_HOME/jobs/$ID/status")" "done"

echo "== delegate (background) + status + result =="
reset_store
ID="$(cd "$WORK" && MOCK_SLEEP=1 MOCK_RESULT="bg done" "$SCRIPTS/delegate.sh" -- "bg task")"
st_now="$(jstatus "$ID")"
assert_eq "background starts running" "$st_now" "running"
assert_file "started timestamp written" "$CURSOR_PLUGIN_HOME/jobs/$ID/started"
final="$(wait_done "$ID")"
assert_eq "background reaches done" "$final" "done"
RES="$("$SCRIPTS/result.sh" "$ID")"
assert_contains "result shows text"    "$RES" "bg done"
assert_contains "result shows session" "$RES" "session"

echo "== prefix id resolution =="
reset_store
ID="$(cd "$WORK" && "$SCRIPTS/delegate.sh" --foreground -- "p")"
PFX="${ID%%-*}"
assert_contains "resolve by prefix" "$("$SCRIPTS/result.sh" "$PFX")" "done"

echo "== status list + json result =="
assert_contains "status header" "$(cd "$WORK" && "$SCRIPTS/status.sh")" "cursor jobs"
assert_contains "result --json raw" "$("$SCRIPTS/result.sh" "$ID" --json)" '"type":"result"'

echo "== rich stream-json: live progress helpers =="
reset_store
ID="$(cd "$WORK" && MOCK_STREAM=1 MOCK_MODEL="Composer 2.5 Fast" MOCK_FILE="src/auth.ts" \
  MOCK_SESSION="sess-rich" MOCK_RESULT="refactored" "$SCRIPTS/delegate.sh" --foreground -- "refactor")"
assert_eq "stream status=done"     "$(cat "$CURSOR_PLUGIN_HOME/jobs/$ID/status")" "done"
assert_eq "stream result parsed"   "$(cat "$CURSOR_PLUGIN_HOME/jobs/$ID/result.txt")" "refactored"
assert_eq "duration_ms captured"   "$(cat "$CURSOR_PLUGIN_HOME/jobs/$ID/duration_ms")" "1234"
assert_eq "tokens_in captured"     "$(cat "$CURSOR_PLUGIN_HOME/jobs/$ID/tokens_in")"  "1200"
assert_eq "tokens_out captured"    "$(cat "$CURSOR_PLUGIN_HOME/jobs/$ID/tokens_out")" "340"
assert_eq "cost captured"          "$(cat "$CURSOR_PLUGIN_HOME/jobs/$ID/cost_usd")"   "0.0123"
assert_contains "usage line tokens" "$( . "$SCRIPTS/lib.sh"; job_usage_line "$ID")" "1.2k"
assert_contains "usage line cost"   "$( . "$SCRIPTS/lib.sh"; job_usage_line "$ID")" "0.0123"
assert_contains "result shows usage" "$("$SCRIPTS/result.sh" "$ID")" "1.2k"
assert_contains "status card usage"  "$("$SCRIPTS/status.sh" "$ID")" "tok"
assert_eq "model from init event"  "$( . "$SCRIPTS/lib.sh"; job_model "$ID")" "Composer 2.5 Fast"
assert_eq "session from init/file" "$( . "$SCRIPTS/lib.sh"; job_session "$ID")" "sess-rich"
assert_eq "tool count = 2"         "$( . "$SCRIPTS/lib.sh"; job_tool_count "$ID")" "2"
assert_contains "changed files"    "$( . "$SCRIPTS/lib.sh"; job_changed_files "$ID")" "src/auth.ts"
ACT="$( . "$SCRIPTS/lib.sh"; job_activity "$ID")"
assert_contains "activity has assistant text" "$ACT" "Converting to async/await"
assert_contains "activity has tool line"      "$ACT" "auth.ts"
RES="$("$SCRIPTS/result.sh" "$ID")"
assert_contains "result shows changed files" "$RES" "src/auth.ts"
assert_contains "result shows activity"      "$RES" "Converting to async/await"
STAT="$("$SCRIPTS/status.sh" "$ID")"
assert_contains "status card shows model" "$STAT" "Composer 2.5 Fast"

echo "== fmt_elapsed + duration as elapsed =="
assert_eq "fmt 45s"      "$( . "$SCRIPTS/lib.sh"; fmt_elapsed 45)"   "45s"
assert_eq "fmt 1m 23s"   "$( . "$SCRIPTS/lib.sh"; fmt_elapsed 83)"   "1m 23s"
assert_eq "fmt 2h 4m"    "$( . "$SCRIPTS/lib.sh"; fmt_elapsed 7440)" "2h 4m"
assert_eq "elapsed from duration" "$( . "$SCRIPTS/lib.sh"; job_elapsed "$ID")" "1"

echo "== fmt_tokens =="
assert_eq "fmt 940"   "$( . "$SCRIPTS/lib.sh"; fmt_tokens 940)"     "940"
assert_eq "fmt 1234"  "$( . "$SCRIPTS/lib.sh"; fmt_tokens 1234)"    "1.2k"
assert_eq "fmt 2.3M"  "$( . "$SCRIPTS/lib.sh"; fmt_tokens 2300000)" "2.3M"

echo "== retry: fails then resumes to success =="
reset_store
CNT="$SANDBOX/retrycount.txt"; : > "$CNT"
RARGS="$SANDBOX/retryargs.txt"; : > "$RARGS"
ID="$(cd "$WORK" && MOCK_STREAM=1 MOCK_FAIL_TIMES=1 MOCK_COUNT_FILE="$CNT" \
  MOCK_ARGS_FILE="$RARGS" MOCK_SESSION="retry-sess" MOCK_RESULT="ok after retry" \
  "$SCRIPTS/delegate.sh" --foreground --retry 2 -- "flaky task")"
assert_eq "retry reaches done"     "$(cat "$CURSOR_PLUGIN_HOME/jobs/$ID/status")" "done"
assert_eq "retry attempts = 2"     "$(cat "$CURSOR_PLUGIN_HOME/jobs/$ID/attempts")" "2"
assert_eq "retry final result"     "$(cat "$CURSOR_PLUGIN_HOME/jobs/$ID/result.txt")" "ok after retry"
assert_contains "retry resumes session" "$(cat "$RARGS")" "retry-sess"
assert_contains "result shows attempts" "$("$SCRIPTS/result.sh" "$ID")" "2 attempts"

echo "== retry: exhausted stays failed =="
reset_store
CNT="$SANDBOX/retrycount2.txt"; : > "$CNT"
ID="$(cd "$WORK" && MOCK_STREAM=1 MOCK_FAIL_TIMES=5 MOCK_COUNT_FILE="$CNT" \
  "$SCRIPTS/delegate.sh" --foreground --retry 1 -- "always fails")"
assert_eq "exhausted -> failed"    "$(cat "$CURSOR_PLUGIN_HOME/jobs/$ID/status")" "failed"
assert_eq "exhausted attempts = 2" "$(cat "$CURSOR_PLUGIN_HOME/jobs/$ID/attempts")" "2"

echo "== diff: git diff of changed files =="
reset_store
GR="$SANDBOX/gitrepo"; rm -rf "$GR"; mkdir -p "$GR"
( cd "$GR" && git init -q && git config user.email t@t.t && git config user.name t \
  && printf 'export const x = 1\n' > tracked.ts && git add . && git commit -qm init )
ID="$(cd "$GR" && MOCK_STREAM=1 MOCK_FILE="tracked.ts" "$SCRIPTS/delegate.sh" --foreground -- "edit tracked")"
printf 'export const x = 2  // changed\n' > "$GR/tracked.ts"
DOUT="$("$SCRIPTS/diff.sh" "$ID" 2>&1)"
assert_contains "diff names file"   "$DOUT" "tracked.ts"
assert_contains "diff shows change" "$DOUT" "changed"
SOUT="$("$SCRIPTS/diff.sh" "$ID" --stat 2>&1)"
assert_contains "diff --stat works" "$SOUT" "tracked.ts"
echo "== diff: non-git errors =="
reset_store
ID="$(cd "$WORK" && MOCK_STREAM=1 MOCK_FILE="x.ts" "$SCRIPTS/delegate.sh" --foreground -- "edit")"
"$SCRIPTS/diff.sh" "$ID" 2>&1 | grep -q "not a git repository" && ok "diff non-git errors" || bad "diff non-git errors"

echo "== statusline: running vs idle =="
reset_store
ID="$(cd "$WORK" && MOCK_SLEEP=5 "$SCRIPTS/delegate.sh" -- "long one")"
sleep 0.3
SL="$(cd "$WORK" && printf '{}' | "$SCRIPTS/statusline.sh" 2>/dev/null)"
assert_contains "statusline shows running" "$SL" "cursor"
"$SCRIPTS/cancel.sh" "$ID" >/dev/null 2>&1 || true
reset_store
SL_IDLE="$(printf '{}' | "$SCRIPTS/statusline.sh" 2>/dev/null)"
assert_eq "statusline idle is empty" "$SL_IDLE" ""

echo "== scope: jobs filtered by repo/folder (global store) =="
reset_store
OTHER="$(mktemp -d)"
IDH="$(cd "$WORK"  && MOCK_STREAM=1 "$SCRIPTS/delegate.sh" --foreground -- "here job")"
IDO="$(cd "$OTHER" && MOCK_STREAM=1 "$SCRIPTS/delegate.sh" --foreground -- "other job")"
HERE="$(cd "$WORK" && "$SCRIPTS/status.sh")"
assert_contains "scoped list shows here job"   "$HERE" "here job"
case "$HERE" in *"other job"*) bad "scoped list hides other job";; *) ok "scoped list hides other job";; esac
assert_contains "scoped list notes elsewhere"  "$HERE" "other folder"
ALLV="$(cd "$WORK" && "$SCRIPTS/status.sh" --all)"
assert_contains "--all shows other job"        "$ALLV" "other job"
# Statusline in the other folder must not count the here-folder running job.
reset_store
IDR="$(cd "$WORK" && MOCK_SLEEP=5 "$SCRIPTS/delegate.sh" -- "long here")"; sleep 0.3
SLO="$(cd "$OTHER" && printf '{}' | "$SCRIPTS/statusline.sh" 2>/dev/null)"
assert_eq "statusline empty in other folder" "$SLO" ""
"$SCRIPTS/cancel.sh" "$IDR" >/dev/null 2>&1 || true
rm -rf "$OTHER"

echo "== hook: announces newly-finished jobs =="
reset_store
HOOK="$ROOT/plugins/cursor/hooks/notify-done.sh"
ID="$(cd "$WORK" && MOCK_STREAM=1 MOCK_RESULT="hooked" "$SCRIPTS/delegate.sh" --foreground -- "hook task")"
HIN='{"hook_event_name":"Stop","session_id":"s","cwd":"'"$WORK"'"}'
HOUT="$(printf '%s' "$HIN" | CURSOR_PLUGIN_NOTIFY_DESKTOP=0 "$HOOK" 2>/dev/null)"
assert_contains "hook emits additionalContext" "$HOUT" "additionalContext"
assert_contains "hook names the job"            "$HOUT" "${ID:0:8}"
assert_contains "hook echoes event name"        "$HOUT" "Stop"
assert_file "hook writes announced marker" "$CURSOR_PLUGIN_HOME/jobs/$ID/announced"
HOUT2="$(printf '%s' "$HIN" | CURSOR_PLUGIN_NOTIFY_DESKTOP=0 "$HOOK" 2>/dev/null)"
assert_eq "hook silent on second run" "$HOUT2" ""
echo "== hook: ignores stale finished jobs =="
reset_store
ID="$(cd "$WORK" && MOCK_STREAM=1 "$SCRIPTS/delegate.sh" --foreground -- "old task")"
touch -t "$(date -v-2H +%Y%m%d%H%M 2>/dev/null || date -d '2 hours ago' +%Y%m%d%H%M)" \
  "$CURSOR_PLUGIN_HOME/jobs/$ID/status"
HSTALE="$(printf '%s' "$HIN" | CURSOR_PLUGIN_NOTIFY_DESKTOP=0 CURSOR_PLUGIN_NOTIFY_WINDOW_MIN=30 "$HOOK" 2>/dev/null)"
assert_eq "hook ignores stale job" "$HSTALE" ""

echo "== cancel running job =="
reset_store
ID="$(cd "$WORK" && MOCK_SLEEP=5 "$SCRIPTS/delegate.sh" -- "long")"
sleep 0.3
"$SCRIPTS/cancel.sh" "$ID" >/dev/null
assert_eq "cancel sets cancelled" "$(cat "$CURSOR_PLUGIN_HOME/jobs/$ID/status")" "cancelled"
sleep 0.3
"$SCRIPTS/cancel.sh" "$ID" 2>&1 | grep -q "nothing to cancel" && ok "re-cancel is noop" || bad "re-cancel is noop"

echo "== crashed detection =="
reset_store
CID="manual-1-1"; mkdir -p "$CURSOR_PLUGIN_HOME/jobs/$CID"
printf 'running' > "$CURSOR_PLUGIN_HOME/jobs/$CID/status"
printf '999999'  > "$CURSOR_PLUGIN_HOME/jobs/$CID/pid"   # dead pid
# Source lib in a SUBSHELL so its `set -e`/pipefail don't leak into the harness.
CRASH_ST="$( . "$SCRIPTS/lib.sh"; job_status "$CID" )"
assert_eq "dead pid -> crashed" "$CRASH_ST" "crashed"

echo "== resume creates linked job =="
reset_store
ID="$(cd "$WORK" && MOCK_SESSION="orig-sess" "$SCRIPTS/delegate.sh" --foreground -- "first")"
ARGS="$SANDBOX/rargs.txt"; : > "$ARGS"
RID="$(MOCK_ARGS_FILE="$ARGS" "$SCRIPTS/resume.sh" "$ID" --foreground -- "next step")"
assert_eq "resume links source"    "$(cat "$CURSOR_PLUGIN_HOME/jobs/$RID/resumed_from_job")" "$ID"
assert_eq "resume keeps cwd"       "$(cat "$CURSOR_PLUGIN_HOME/jobs/$RID/cwd")" "$WORK"
assert_contains "resume passes --resume session" "$(cat "$ARGS")" "orig-sess"

echo "== prune removes old finished jobs =="
reset_store
ID="$(cd "$WORK" && "$SCRIPTS/delegate.sh" --foreground -- "old")"
# Age the dir past the threshold.
touch -t "$(date -v-10d +%Y%m%d%H%M 2>/dev/null || date -d '10 days ago' +%Y%m%d%H%M)" \
  "$CURSOR_PLUGIN_HOME/jobs/$ID"
"$SCRIPTS/status.sh" >/dev/null
[ ! -d "$CURSOR_PLUGIN_HOME/jobs/$ID" ] && ok "old finished job pruned" || bad "old finished job pruned"

echo "== prune spares running jobs =="
reset_store
ID="$(cd "$WORK" && MOCK_SLEEP=5 "$SCRIPTS/delegate.sh" -- "running-old")"
touch -t "$(date -v-10d +%Y%m%d%H%M 2>/dev/null || date -d '10 days ago' +%Y%m%d%H%M)" \
  "$CURSOR_PLUGIN_HOME/jobs/$ID" 2>/dev/null
"$SCRIPTS/status.sh" >/dev/null
[ -d "$CURSOR_PLUGIN_HOME/jobs/$ID" ] && ok "running job not pruned" || bad "running job not pruned"
"$SCRIPTS/cancel.sh" "$ID" >/dev/null 2>&1 || true

echo "== setup preflight (mock) =="
reset_store
SOUT="$("$SCRIPTS/setup.sh" 2>&1)"; SRC=$?
assert_contains "setup finds agent" "$SOUT" "cursor-agent found"
assert_contains "setup reads version" "$SOUT" "mock 1.2.3"
echo "== setup detects missing auth =="
SOUT="$(MOCK_NOAUTH=1 env -u CURSOR_API_KEY "$SCRIPTS/setup.sh" 2>&1)"
assert_contains "setup warns no auth" "$SOUT" "auth"

echo "== error paths =="
reset_store
"$SCRIPTS/result.sh" "nope" 2>&1 | grep -q "no job matching" && ok "result unknown id errors" || bad "result unknown id errors"
"$SCRIPTS/delegate.sh" --foreground -- 2>&1 | grep -q "no prompt" && ok "delegate empty prompt errors" || bad "delegate empty prompt errors"
# ambiguous prefix
mkdir -p "$CURSOR_PLUGIN_HOME/jobs/100-1-1" "$CURSOR_PLUGIN_HOME/jobs/100-2-2"
"$SCRIPTS/result.sh" "100" 2>&1 | grep -q "ambiguous" && ok "ambiguous prefix errors" || bad "ambiguous prefix errors"

# ---- optional live smoke test ----
if [ "${CURSOR_LIVE:-0}" = "1" ]; then
  echo "== LIVE smoke test (real cursor-agent) =="
  unset CURSOR_AGENT_BIN
  reset_store
  ID="$(cd "$WORK" && "$ROOT/plugins/cursor/scripts/delegate.sh" --foreground -- "reply with exactly: SMOKE_OK")"
  RES="$(CURSOR_AGENT_BIN= "$SCRIPTS/result.sh" "$ID" 2>&1)"
  assert_contains "live result returned" "$RES" "SMOKE_OK"
fi

echo
echo "==================================="
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
