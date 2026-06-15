#!/usr/bin/env bash
# Mock cursor-agent for tests. Behaviour driven by env vars:
#   MOCK_RESULT    result text (default "done it")
#   MOCK_SESSION   session_id  (default "sess-xyz")
#   MOCK_IS_ERROR  "true"/"false" in the json result (default false)
#   MOCK_SLEEP     seconds to sleep before emitting (default 0)
#   MOCK_EXIT      process exit code (default 0)
#   MOCK_NOOUT     if "1", print nothing (simulate no output)
#   MOCK_STREAM    if "1", emit stream-json (multiple lines)
#   MOCK_VERSION   version string for --version (default "mock 1.2.3")
#   MOCK_NOAUTH    if "1", --list-models fails (simulate logged out)
#   MOCK_ARGS_FILE if set, append the raw argv (one per line, NUL-free) here
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

if [ "${MOCK_STREAM:-0}" = "1" ]; then
  printf '%s\n' '{"type":"assistant","text":"working..."}'
  printf '{"type":"result","subtype":"success","is_error":%s,"result":%s,"session_id":%s}\n' \
    "$is_error" "$(printf '%s' "$result" | jq -R .)" "$(printf '%s' "$session" | jq -R .)"
else
  printf '{"type":"result","subtype":"success","is_error":%s,"result":%s,"session_id":%s,"usage":{"inputTokens":1}}\n' \
    "$is_error" "$(printf '%s' "$result" | jq -R .)" "$(printf '%s' "$session" | jq -R .)"
fi

exit "${MOCK_EXIT:-0}"
