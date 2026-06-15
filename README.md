<div align="center">

# cursor-plugin-cc

**Hand off coding tasks from [Claude Code](https://claude.com/claude-code) to the [Cursor CLI](https://cursor.com/cli) (`cursor-agent`) as tracked background jobs.**

The mirror image of [`openai/codex-plugin-cc`](https://github.com/openai/codex-plugin-cc) — but for Cursor.

[![CI](https://github.com/akash-viven/cursor-plugin-cc/actions/workflows/ci.yml/badge.svg)](https://github.com/akash-viven/cursor-plugin-cc/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/akash-viven/cursor-plugin-cc)](https://github.com/akash-viven/cursor-plugin-cc/releases)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)

</div>

---

Claude stays your driver. When a task suits Cursor better — a second opinion, parallel work, a long unattended fix — Claude delegates it to `cursor-agent`, tracks it as a background job, and reports the result back.

```
You ──▶ Claude Code ──/cursor:delegate──▶ cursor-agent (background)
                  ◀── result + session id ──┘
```

- 🚀 **Background handoff** — fire a task, keep working; Claude polls and reports.
- 📊 **Live progress** — watch a running job's activity, tool calls, changed files, tokens, and cost as it works.
- 🔔 **Completion-aware** — a Stop hook tells Claude (and pings your desktop) the moment a background job finishes — no polling.
- 🔍 **Reviewable** — `/cursor:diff <id>` shows the git diff of exactly what a job changed.
- 🔁 **Resumable + self-healing** — continue a session with new instructions, or `--retry N` to auto-resume on crash.
- 📈 **Statusline** — optional one-line ambient summary of active jobs.
- 🤖 **Self-rescue** — a `cursor-rescue` subagent Claude can invoke when stuck.
- 🧪 **Tested** — 84 mocked tests + opt-in live smoke test, CI on every push.

---

## Contents

- [Prerequisites](#prerequisites)
- [Install](#install)
- [Quickstart](#quickstart)
- [Commands](#commands)
- [How it works](#how-it-works)
- [Risks — read this](#-risks--read-this)
- [Configuration](#configuration)
- [Tests](#tests)
- [License](#license)

---

## Prerequisites

| Requirement | Why | Install |
|-------------|-----|---------|
| Claude Code | The host | https://claude.com/claude-code |
| `cursor-agent` | The CLI being driven | `curl https://cursor.com/install -fsS \| bash` |
| `jq` | Parses cursor-agent JSON output | `brew install jq` / `apt-get install jq` |

Authenticate Cursor once: `cursor-agent login` (or export `CURSOR_API_KEY`).

---

## Install

From inside Claude Code, add the marketplace and install the plugin:

```
/plugin marketplace add akash-viven/cursor-plugin-cc
/plugin install cursor@akash-viven
```

Verify everything is wired up:

```
/cursor:setup
```

**Updating** — pull the latest version anytime:

```
/plugin marketplace update akash-viven
```

> [!TIP]
> If commands don't appear after install or update, refresh the runtime with `/reload-plugins`. Still stuck? Remove and re-add: `/plugin marketplace remove akash-viven` then `/plugin marketplace add akash-viven/cursor-plugin-cc`.

---

## Quickstart

```
# 1. Hand a task to Cursor (returns a job id, runs in the background)
/cursor:delegate refactor src/auth.ts to use async/await and add tests

# 2. Check progress — bare for the list, or pass an id for a live card
/cursor:status
/cursor:status <id>      # activity timeline, tool calls, changed files, elapsed

# 3. Read the result once it's done (shows tokens + cost)
/cursor:result <id>

# 4. Review exactly what changed
/cursor:diff <id>

# 5. Iterate on the same Cursor session
/cursor:resume <id> now wire it into the login route
```

When a background job finishes, a Stop hook surfaces it to Claude automatically and fires a desktop notification — you don't have to keep checking `status`.

Job ids accept a **unique prefix** — `/cursor:result 1718` works if it's unambiguous.

---

## Commands

| Command | What it does |
|---------|--------------|
| `/cursor:delegate <task>` | Hand a task to cursor-agent as a background job. Prints a job id. |
| `/cursor:status [id]` | List jobs, or pass an id for a live card (activity, tool calls, changed files, tokens, cost, elapsed). Prunes finished jobs older than 7 days. |
| `/cursor:result <id>` | Show a finished job's output, token/cost usage, and session id. `--json` for raw. |
| `/cursor:diff <id>` | Show the git diff of what a job changed (`--stat` for a summary). |
| `/cursor:cancel <id>` | Stop a running job. |
| `/cursor:resume <id> <new instructions>` | Continue a job's session as a new job. |
| `/cursor:setup` | Verify cursor-agent install, auth, version, jq. |

**Flags** on `delegate` / `resume`: `--model <m>` (override model), `--retry <n>` (auto-resume on crash/failure up to n times), `--worktree` (isolate edits in a throwaway git worktree, `delegate` only).

A `cursor-rescue` subagent ships alongside, so Claude can self-delegate when it gets stuck.

### Completion notifications

A bundled `Stop`/`SubagentStop` hook scans for background jobs that finished since the last turn and feeds a one-line summary back to Claude as context — so Claude reacts to completions on its own. It also fires a best-effort desktop notification (macOS `osascript` / Linux `notify-send`). Tune or disable via env (see [Configuration](#configuration)).

### Statusline (optional)

Show active jobs in your Claude Code statusline — e.g. `◐ 2 cursor · 3m 12s`, empty when idle. Add to your `settings.json`, pointing at the installed plugin path:

```json
"statusLine": {
  "type": "command",
  "command": "~/.claude/plugins/marketplaces/akash-viven/plugins/cursor/scripts/statusline.sh"
}
```

---

## How it works

`cursor-agent` has no long-lived daemon, so each handoff is a **detached subprocess**. `delegate.sh` runs:

```bash
cursor-agent -p "<task>" --output-format stream-json \
  --force --trust --sandbox disabled --workspace "$PWD"
```

…detached, streaming NDJSON events to `output.json` as it works. `/cursor:status <id>` parses that live stream on demand — no daemon, no polling loop — to show the model, elapsed time, recent activity, tool calls, changed files, and running token/cost usage. When the job exits, the wrapper reads the final `result` event (`.result`, `.session_id`, `.is_error`, `.duration_ms`, `.usage`) into per-job files. With `--retry N`, a failed or crashed run is re-attempted — resuming the captured session so the agent continues rather than restarting cold.

Job state lives in `~/.cursor-plugin/jobs/<id>/`:

```
cwd  prompt  model  started  status  pid  output.json  exit_code  err.log
result.txt  session_id  duration_ms  tokens_in  tokens_out  cost_usd
retry_max  attempts  announced
```

`status` is one of:

| Status | Meaning |
|--------|---------|
| `running` | Job in flight |
| `done` | Finished successfully |
| `failed` | Agent reported an error (after exhausting `--retry`, if set) |
| `cancelled` | Stopped via `/cursor:cancel` |
| `crashed` | PID died before writing a terminal status |

---

## ⚠️ Risks — read this

> [!WARNING]
> Delegated jobs run **unattended with write access**. Treat this like handing your repo to an autonomous agent.

- **Unattended file edits.** Jobs run with `--force --trust --sandbox disabled`. cursor-agent can write files and run shell commands in your repo without prompting. Only delegate in repos you trust, and keep a clean git tree so you can diff/revert.
- **Concurrent edits.** Multiple background jobs (or a job + you) editing the same files can clobber each other. Use `--worktree` to isolate a risky job in `~/.cursor/worktrees/`.
- **Quota / loops.** Two AI agents can burn usage fast. Don't wire this into automatic loops.

---

## Configuration

Environment variables (all optional):

| Var | Default | Purpose |
|-----|---------|---------|
| `CURSOR_PLUGIN_HOME` | `~/.cursor-plugin` | Job store root |
| `CURSOR_AGENT_BIN` | `cursor-agent` | Binary to drive |
| `CURSOR_PLUGIN_PRUNE_DAYS` | `7` | Auto-prune finished jobs older than N days (`0` = off) |
| `CURSOR_PLUGIN_NOTIFY_WINDOW_MIN` | `30` | Completion hook ignores jobs that finished more than N minutes ago (prevents replaying old jobs) |
| `CURSOR_PLUGIN_NOTIFY_DESKTOP` | `1` | Set `0` to suppress the desktop notification |
| `CURSOR_API_KEY` | — | Non-interactive auth for cursor-agent |

---

## Tests

Pure-bash harness with a mocked `cursor-agent` — no quota used:

```bash
tests/run.sh                 # 84 unit + integration tests
CURSOR_LIVE=1 tests/run.sh   # also runs one real cursor-agent smoke test
```

CI runs manifest validation, shell syntax checks, and the mocked suite on every push and PR.

---

## License

[Apache-2.0](LICENSE) © Akash Solanki. Not affiliated with Anysphere (Cursor) or OpenAI.
