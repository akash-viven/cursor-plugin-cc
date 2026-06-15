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
- 📋 **Job tracking** — `status` / `result` / `cancel` across every repo.
- 🔁 **Resumable** — continue a Cursor session with new instructions.
- 🤖 **Self-rescue** — a `cursor-rescue` subagent Claude can invoke when stuck.
- 🧪 **Tested** — 38 mocked tests + opt-in live smoke test, CI on every push.

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

# 2. Check progress (run from any repo)
/cursor:status

# 3. Read the result once it's done
/cursor:result <id>

# 4. Iterate on the same Cursor session
/cursor:resume <id> now wire it into the login route
```

Job ids accept a **unique prefix** — `/cursor:result 1718` works if it's unambiguous.

---

## Commands

| Command | What it does |
|---------|--------------|
| `/cursor:delegate <task>` | Hand a task to cursor-agent as a background job. Prints a job id. |
| `/cursor:status [id]` | List jobs and status. Prunes finished jobs older than 7 days. |
| `/cursor:result <id>` | Show a finished job's output + session id. `--json` for raw. |
| `/cursor:cancel <id>` | Stop a running job. |
| `/cursor:resume <id> <new instructions>` | Continue a job's session as a new job. |
| `/cursor:setup` | Verify cursor-agent install, auth, version, jq. |

**Flags** on `delegate` / `resume`: `--model <m>` (override model), `--worktree` (isolate edits in a throwaway git worktree).

A `cursor-rescue` subagent ships alongside, so Claude can self-delegate when it gets stuck.

---

## How it works

`cursor-agent` has no long-lived daemon, so each handoff is a **detached subprocess**. `delegate.sh` runs:

```bash
cursor-agent -p "<task>" --output-format json \
  --force --trust --sandbox disabled --workspace "$PWD"
```

…detached, capturing stdout to `output.json`. When it exits, the wrapper parses the result object (`.result`, `.session_id`, `.is_error`) into per-job files.

Job state lives in `~/.cursor-plugin/jobs/<id>/`:

```
cwd  prompt  model  status  pid  output.json  result.txt  session_id  exit_code  err.log
```

`status` is one of:

| Status | Meaning |
|--------|---------|
| `running` | Job in flight |
| `done` | Finished successfully |
| `failed` | Agent reported an error |
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
| `CURSOR_API_KEY` | — | Non-interactive auth for cursor-agent |

---

## Tests

Pure-bash harness with a mocked `cursor-agent` — no quota used:

```bash
tests/run.sh                 # 38 unit + integration tests
CURSOR_LIVE=1 tests/run.sh   # also runs one real cursor-agent smoke test
```

CI runs manifest validation, shell syntax checks, and the mocked suite on every push and PR.

---

## License

[Apache-2.0](LICENSE) © Akash Solanki. Not affiliated with Anysphere (Cursor) or OpenAI.
