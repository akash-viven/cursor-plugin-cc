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

# Parse the captured cursor-agent output into terminal job files.
# We drive cursor-agent with --output-format stream-json: an NDJSON stream of
# events ending in a single {"type":"result",...} object. Plain single-object
# json is still tolerated for forward/backward compatibility.
finalize_job() {
  local id="$1" dir out
  dir="$(job_dir "$id")"
  out="$dir/output.json"
  if [ ! -s "$out" ]; then
    printf 'failed' > "$dir/status"
    printf 'no output captured from cursor-agent\n' > "$dir/result.txt"
    return 0
  fi
  local obj
  obj="$(jq -c 'select(.type=="result")' "$out" 2>/dev/null | tail -n1 || true)"
  if [ -z "$obj" ]; then
    # Not parseable as a result object; treat raw text as the result.
    printf 'failed' > "$dir/status"
    cp "$out" "$dir/result.txt"
    return 0
  fi
  local is_err result session duration
  is_err="$(printf '%s' "$obj" | jq -r '.is_error // false')"
  result="$(printf '%s' "$obj" | jq -r '.result // ""')"
  session="$(printf '%s' "$obj" | jq -r '.session_id // ""')"
  duration="$(printf '%s' "$obj" | jq -r '.duration_ms // empty')"
  printf '%s' "$result" > "$dir/result.txt"
  [ -n "$session" ] && printf '%s' "$session" > "$dir/session_id"
  [ -n "$duration" ] && printf '%s' "$duration" > "$dir/duration_ms"
  # Token/cost accounting. cursor-agent's field naming has drifted across
  # versions, so accept snake_case, camelCase, and prompt/completion aliases.
  local tin tout cost
  tin="$(printf  '%s' "$obj" | jq -r '(.usage.input_tokens  // .usage.inputTokens  // .usage.prompt_tokens)     // empty')"
  tout="$(printf '%s' "$obj" | jq -r '(.usage.output_tokens // .usage.outputTokens // .usage.completion_tokens) // empty')"
  cost="$(printf '%s' "$obj" | jq -r '(.usage.total_cost_usd // .usage.cost_usd // .total_cost_usd // .cost_usd) // empty')"
  [ -n "$tin" ]  && printf '%s' "$tin"  > "$dir/tokens_in"
  [ -n "$tout" ] && printf '%s' "$tout" > "$dir/tokens_out"
  [ -n "$cost" ] && printf '%s' "$cost" > "$dir/cost_usd"
  if [ "$is_err" = "true" ]; then
    printf 'failed' > "$dir/status"
  else
    printf 'done' > "$dir/status"
  fi
}

# ── live-progress helpers ─────────────────────────────────────────────────
# These read the streaming output.json on demand (no daemon). Safe to call
# while a job is running — they tolerate partial/truncated trailing lines.

# Session id: prefer the finalized file, else the init event from the stream.
job_session() {
  local id="$1" s; s="$(job_field "$id" session_id)"
  if [ -z "$s" ]; then
    s="$(jq -r 'select(.type=="system" and .subtype=="init").session_id' \
      "$(job_dir "$id")/output.json" 2>/dev/null | head -n1)"
  fi
  printf '%s' "$s"
}

# Model name reported by the init event (else the stored --model, else default).
job_model() {
  local id="$1" m
  m="$(jq -r 'select(.type=="system" and .subtype=="init").model // empty' \
    "$(job_dir "$id")/output.json" 2>/dev/null | head -n1)"
  [ -n "$m" ] || m="$(job_field "$id" model)"
  [ -n "$m" ] || m="(default)"
  printf '%s' "$m"
}

# Elapsed seconds: now-started while running; stored duration when finished.
job_elapsed() {
  local id="$1" started dur now
  if [ "$(job_status "$id")" = "running" ]; then
    started="$(job_field "$id" started)"
    [ -n "$started" ] || { printf '0'; return; }
    now="$(date +%s)"
    printf '%s' "$((now - started))"
  else
    dur="$(job_field "$id" duration_ms)"
    if [ -n "$dur" ]; then printf '%s' "$((dur / 1000))"; else printf '0'; fi
  fi
}

# Number of tool calls started so far.
job_tool_count() {
  local n
  # grep -c prints 0 and exits 1 on no match; swallow that so we don't double up.
  n="$(jq -rc 'select(.type=="tool_call" and .subtype=="started")' \
    "$(job_dir "$1")/output.json" 2>/dev/null | grep -c . || true)"
  printf '%s' "${n:-0}"
}

# Humanize a token count: 940 -> "940", 1234 -> "1.2k", 2300000 -> "2.3M".
fmt_tokens() {
  local n="${1:-0}"
  case "$n" in ''|*[!0-9]*) printf '%s' "$n"; return;; esac
  if [ "$n" -lt 1000 ]; then printf '%s' "$n"; return; fi
  awk -v n="$n" 'BEGIN{ if (n<1000000) printf "%.1fk", n/1000; else printf "%.1fM", n/1000000 }'
}

# One-line usage summary: "1.2k → 340 tok · $0.0123", or "" when nothing recorded.
job_usage_line() {
  local id="$1" ti to co s=""
  ti="$(job_field "$id" tokens_in)"
  to="$(job_field "$id" tokens_out)"
  co="$(job_field "$id" cost_usd)"
  if [ -n "$ti" ] || [ -n "$to" ]; then
    s="$(fmt_tokens "${ti:-0}") → $(fmt_tokens "${to:-0}") tok"
  fi
  if [ -n "$co" ]; then
    [ -n "$s" ] && s="$s · "
    s="${s}\$$co"
  fi
  printf '%s' "$s"
}

# Distinct files a job wrote/edited. Models differ wildly in HOW they mutate
# files: dedicated edit/write/create tools (varied arg keys), or plain shell
# commands with `>`/`>>`/`tee` redirects. We harvest paths from both so the
# changed-files view isn't blank for shell-driven agents.
job_changed_files() {
  jq -r '
    select(.type=="tool_call" and .subtype=="completed")
    | .tool_call as $tc
    | ($tc | keys_unsorted[] | select(endswith("ToolCall"))) as $k
    | $tc[$k] as $call
    | if ($k | test("edit|write|create|delete|move|apply|patch"; "i")) then
        ($call.args.path // $call.args.target_file // $call.args.file
          // $call.args.filePath // $call.args.relativePath // empty)
      elif ($k | test("shell|terminal|bash|exec|command|run"; "i")) then
        (($call.args.command // "")
          | scan("(?:>>?|\\btee)\\s+\"?([^\\s;|&>\"'"'"']+)") | .[0])
      else empty end
  ' "$(job_dir "$1")/output.json" 2>/dev/null \
    | awk 'NF' | awk '!seen[$0]++'
}

# Render the activity timeline as pretty lines, in stream order.
#   💬  assistant text   |   🔧  <tool>  <file>
# Optional arg: tail to the last N events.
job_activity() {
  local id="$1" n="${2:-0}" out
  out="$(job_dir "$id")/output.json"
  [ -s "$out" ] || return 0
  # Render display lines entirely in jq (emoji + tool + basename), so the shell
  # only needs a plain whole-line read — robust across shells and IFS settings.
  local lines
  lines="$(jq -r '
    select(
      (.type=="assistant") or
      (.type=="tool_call" and .subtype=="started")
    )
    | if .type=="assistant" then
        ([.message.content[]? | select(.type=="text") | .text] | join(" ")) as $t
        | select(($t | gsub("\\s";"")) != "")
        | "\ud83d\udcac  " + ($t | gsub("\\s+";" ") | gsub("^ | $";""))
      else
        (.tool_call | keys_unsorted[] | select(endswith("ToolCall"))) as $k
        | ((.tool_call[$k].args.path // "") | split("/") | last) as $f
        | "\ud83d\udd27  " + ($k | sub("ToolCall$";""))
          + (if $f != "" then "  " + $f else "" end)
      end
  ' "$out" 2>/dev/null)" || return 0
  [ -n "$lines" ] || return 0
  if [ "$n" -gt 0 ]; then lines="$(printf '%s\n' "$lines" | tail -n "$n")"; fi
  printf '%s\n' "$lines" | while IFS= read -r line; do _trunc_line "$line"; done
}

# Truncate a display line to ~66 visible chars.
_trunc_line() {
  local s="$1" max=66
  if [ "${#s}" -gt "$max" ]; then printf '%s…\n' "${s:0:max}"; else printf '%s\n' "$s"; fi
}

# Spinner frame chosen from elapsed seconds (deterministic, no timers).
spinner_frame() {
  local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i
  i=$(( ${1:-0} % 10 ))
  printf '%s' "$(printf '%s' "$frames" | cut -c $((i+1)))"
}

# Human elapsed: "45s", "1m 23s", "2h 4m".
fmt_elapsed() {
  local s="${1:-0}" h m
  if [ "$s" -lt 60 ]; then printf '%ds' "$s"; return; fi
  if [ "$s" -lt 3600 ]; then printf '%dm %ds' "$((s/60))" "$((s%60))"; return; fi
  h=$((s/3600)); m=$(((s%3600)/60)); printf '%dh %dm' "$h" "$m"
}

# Color helpers. Honor NO_COLOR; disable when stdout is not a tty.
_supports_color() { [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; }
c() { # c <code> <text>
  if _supports_color; then printf '\033[%sm%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi
}
dim()  { c '2'  "$1"; }
bold() { c '1'  "$1"; }
# Color a status word by its semantics.
status_color() {
  local st="$1" code
  case "$st" in
    running)   code='36';;  # cyan
    done)      code='32';;  # green
    failed)    code='31';;  # red
    crashed)   code='31';;  # red
    cancelled) code='33';;  # yellow
    *)         code='2';;   # dim
  esac
  c "$code" "$st"
}

# Status -> glyph.
status_icon() {
  case "$1" in
    running)   printf '◐';;
    done)      printf '✓';;
    failed)    printf '✗';;
    cancelled) printf '⊘';;
    crashed)   printf '!';;
    *)         printf '·';;
  esac
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
