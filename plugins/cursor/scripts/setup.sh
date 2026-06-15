#!/usr/bin/env bash
# setup.sh — preflight: verify cursor-agent install, auth, and version.
# Usage: setup.sh
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

ok=0; warn=0
mark_ok()   { printf '  [ok]   %s\n' "$*"; }
mark_warn() { printf '  [warn] %s\n' "$*"; warn=$((warn+1)); }
mark_err()  { printf '  [err]  %s\n' "$*"; ok=1; }

printf 'cursor handoff plugin — setup check\n\n'

# 1. binary on PATH
if command -v "$CURSOR_AGENT_BIN" >/dev/null 2>&1; then
  mark_ok "cursor-agent found: $(command -v "$CURSOR_AGENT_BIN")"
else
  mark_err "cursor-agent NOT found on PATH"
  printf '         install: curl https://cursor.com/install -fsS | bash\n'
  exit 1
fi

# 2. version
if ver="$("$CURSOR_AGENT_BIN" --version 2>/dev/null)"; then
  mark_ok "version: $ver"
else
  mark_warn "could not read version"
fi

# 3. jq (required for output parsing)
if command -v jq >/dev/null 2>&1; then
  mark_ok "jq found: $(command -v jq)"
else
  mark_err "jq NOT found — required to parse cursor-agent output"
  printf '         install: brew install jq  (or apt-get install jq)\n'
fi

# 4. auth — CURSOR_API_KEY env or interactive login state.
if [ -n "${CURSOR_API_KEY:-}" ]; then
  mark_ok "auth: CURSOR_API_KEY set in environment"
elif "$CURSOR_AGENT_BIN" --list-models >/dev/null 2>&1; then
  mark_ok "auth: logged in (cursor-agent reachable)"
else
  mark_warn "auth: not confirmed. Run 'cursor-agent login' or export CURSOR_API_KEY"
fi

# 5. job store
ensure_store
mark_ok "job store: $JOBS_DIR"

printf '\n'
if [ "$ok" -ne 0 ]; then
  printf 'setup incomplete — fix [err] items above.\n'; exit 1
fi
if [ "$warn" -ne 0 ]; then
  printf 'setup usable with %d warning(s).\n' "$warn"
else
  printf 'all checks passed. Ready: /cursor:delegate <task>\n'
fi
