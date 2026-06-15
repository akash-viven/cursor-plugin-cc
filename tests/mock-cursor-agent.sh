#!/usr/bin/env bash
# Mock cursor-agent for tests. Behaviour driven by env vars:
#   MOCK_RESULT    result text (default "done it")
#   MOCK_SESSION   session_id  (default "sess-xyz")
#   MOCK_IS_ERROR  "true"/"false" in the json result (default false)
#   MOCK_SLEEP     seconds to sleep before emitting (default 0)
#   MOCK_EXIT      process exit code (default 0)
#   MOCK_NOOUT     if "1", print nothing (simulate no output)
#   MOCK_STREAM    if "1", emit rich stream-json (init/assistant/tool_call/result)
#   MOCK_MODEL     model name in the init event (default "Composer 2.5 Fast")
#   MOCK_FILE      path used by the mocked edit tool_call (default "src/auth.ts")
#   MOCK_VERSION   version string for --version (default "mock 1.2.3")
#   MOCK_NOAUTH    if "1", --list-models fails (simulate logged out)
#   MOCK_ARGS_FILE if set, append the raw argv (one per line, NUL-free) here
#   MOCK_TOKENS_IN  input tokens in the stream result usage (default 1200)
#   MOCK_TOKENS_OUT output tokens in the stream result usage (default 340)
#   MOCK_COST       total_cost_usd in the stream result usage (default 0.0123)
#   MOCK_FAIL_TIMES with MOCK_COUNT_FILE: fail the first N invocations
#                   (is_error=true), succeed after — exercises --retry.
#   MOCK_COUNT_FILE counter file backing MOCK_FAIL_TIMES across invocations
set -u

# Record argv for assertions if requested.
if [ -n "${MOCK_ARGS_FILE:-}" ]; then
  printf '%s\n' "$@" >> "$MOCK_ARGS_FILE"
fi

case "${1:-}" in
  --version|-v) printf '%s\n' "${MOCK_VERSION:-mock 1.2.3}"; exit 0;;
  --list-models)
    if [ "${MOCK_NOAUTH:-0}" = "1" ]; then exit 1; fi
    printf 'gpt-5\nsonnet-4\n'; exit 0;;
esac

[ "${MOCK_SLEEP:-0}" != "0" ] && sleep "${MOCK_SLEEP}"

if [ "${MOCK_NOOUT:-0}" = "1" ]; then
  exit "${MOCK_EXIT:-0}"
fi

result="${MOCK_RESULT:-done it}"
session="${MOCK_SESSION:-sess-xyz}"
is_error="${MOCK_IS_ERROR:-false}"

# Retry simulation: fail the first MOCK_FAIL_TIMES invocations, then succeed.
if [ -n "${MOCK_FAIL_TIMES:-}" ] && [ -n "${MOCK_COUNT_FILE:-}" ]; then
  n="$(cat "$MOCK_COUNT_FILE" 2>/dev/null || echo 0)"; n=$((n + 1))
  printf '%s' "$n" > "$MOCK_COUNT_FILE"
  if [ "$n" -le "$MOCK_FAIL_TIMES" ]; then
    is_error=true
    result="attempt $n failed"
  fi
fi

if [ "${MOCK_STREAM:-0}" = "1" ]; then
  model="${MOCK_MODEL:-Composer 2.5 Fast}"
  file="${MOCK_FILE:-src/auth.ts}"
  jq -cn --arg s "$session" --arg m "$model" \
    '{type:"system",subtype:"init",session_id:$s,model:$m}'
  jq -cn '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:"Reading the file now."}]}}'
  jq -cn --arg p "$file" '{type:"tool_call",subtype:"started",tool_call:{readToolCall:{args:{path:$p}}}}'
  jq -cn --arg p "$file" '{type:"tool_call",subtype:"completed",tool_call:{readToolCall:{args:{path:$p},result:{success:{}}}}}'
  jq -cn '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:"Converting to async/await."}]}}'
  jq -cn --arg p "$file" '{type:"tool_call",subtype:"started",tool_call:{editToolCall:{args:{path:$p}}}}'
  jq -cn --arg p "$file" '{type:"tool_call",subtype:"completed",tool_call:{editToolCall:{args:{path:$p},result:{success:{linesAdded:4}}}}}'
  jq -cn --arg r "$result" --arg s "$session" --argjson e "$is_error" \
    --argjson ti "${MOCK_TOKENS_IN:-1200}" --argjson to "${MOCK_TOKENS_OUT:-340}" \
    --argjson co "${MOCK_COST:-0.0123}" \
    '{type:"result",subtype:"success",is_error:$e,result:$r,session_id:$s,duration_ms:1234,
      usage:{input_tokens:$ti,output_tokens:$to,total_cost_usd:$co}}'
else
  printf '{"type":"result","subtype":"success","is_error":%s,"result":%s,"session_id":%s,"usage":{"inputTokens":1}}\n' \
    "$is_error" "$(printf '%s' "$result" | jq -R .)" "$(printf '%s' "$session" | jq -R .)"
fi

exit "${MOCK_EXIT:-0}"
