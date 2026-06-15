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

# Wait until a job leaves 'running' or timeout (~10s).
wait_done() {
  local id="$1" i st
  for i in $(seq 1 50); do
    st="$("$SCRIPTS/status.sh" "$id" 2>/dev/null | tail -n1 | awk '{print $2}')"
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
st_now="$("$SCRIPTS/status.sh" "$ID" | tail -n1 | awk '{print $2}')"
assert_eq "background starts running" "$st_now" "running"
final="$(wait_done "$ID")"
assert_eq "background reaches done" "$final" "done"
RES="$("$SCRIPTS/result.sh" "$ID")"
assert_contains "result shows text"    "$RES" "bg done"
assert_contains "result shows session" "$RES" "session:"

echo "== prefix id resolution =="
reset_store
ID="$(cd "$WORK" && "$SCRIPTS/delegate.sh" --foreground -- "p")"
PFX="${ID%%-*}"
assert_contains "resolve by prefix" "$("$SCRIPTS/result.sh" "$PFX")" "done"

echo "== status list + json result =="
assert_contains "status header" "$("$SCRIPTS/status.sh")" "JOB ID"
assert_contains "result --json raw" "$("$SCRIPTS/result.sh" "$ID" --json)" '"type":"result"'

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
