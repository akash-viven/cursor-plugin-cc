# cursor-plugin-cc

Hand off coding tasks from **Claude Code** to the **Cursor CLI** (`cursor-agent`)
as tracked background jobs — the mirror image of
[`openai/codex-plugin-cc`](https://github.com/openai/codex-plugin-cc), but for Cursor.

Claude stays your driver. When a task is better suited to Cursor (second opinion,
parallel work, a long unattended fix), Claude delegates it to `cursor-agent`,
tracks it as a background job, and reports the result back.

## Commands

| Command | What it does |
|---------|--------------|
| `/cursor:delegate <task>` | Hand a task to cursor-agent as a background job. Prints a job id. |
| `/cursor:status [id]` | List jobs and status. Prunes finished jobs older than 7 days. |
| `/cursor:result <id>` | Show a finished job's output + session id. `--json` for raw. |
| `/cursor:cancel <id>` | Stop a running job. |
| `/cursor:resume <id> <new instructions>` | Continue a job's session as a new job. |
| `/cursor:setup` | Verify cursor-agent install, auth, version, jq. |

A `cursor-rescue` subagent is also included so Claude can self-delegate when stuck.

Job ids accept a unique prefix, e.g. `/cursor:result 1718...` → short form works.

## How it works

`cursor-agent` has no long-lived daemon, so each handoff is a detached
subprocess. `delegate.sh` runs:

```
cursor-agent -p "<task>" --output-format json \
  --force --trust --sandbox disabled --workspace "$PWD"
```

…detached, capturing stdout to `output.json`. When it exits, the wrapper parses
the result object (`.result`, `.session_id`, `.is_error`) into per-job files.

Job state lives in `~/.cursor-plugin/jobs/<id>/`:

```
cwd  prompt  model  status  pid  output.json  result.txt  session_id  exit_code  err.log
```

`status` is one of: `running`, `done`, `failed`, `cancelled`, `crashed`
(crashed = pid died before writing a terminal status).

## ⚠️ Risks — read this

- **Unattended file edits.** Delegated jobs run with `--force --trust
  --sandbox disabled`. cursor-agent can write files and run shell commands in
  your repo without prompting. Only delegate in repos you trust, and prefer a
  clean git tree so you can diff/revert.
- **Concurrent edits.** Multiple background jobs (or a job + you) editing the
  same files can clobber each other. Use `--worktree` on `delegate` to isolate a
  risky job in `~/.cursor/worktrees/`.
- **Quota / loops.** Two AI agents can burn through usage fast. Avoid wiring this
  into automatic loops.

## Install

From Claude Code, add the marketplace then install the plugin:

```
/plugin marketplace add akash-viven/cursor-plugin-cc
/plugin install cursor@akash-viven
```

Update later with `/plugin marketplace update akash-viven`.

Then run `/cursor:setup`. Requires `cursor-agent` (https://cursor.com/cli) and `jq`.

## Configuration (env)

| Var | Default | Purpose |
|-----|---------|---------|
| `CURSOR_PLUGIN_HOME` | `~/.cursor-plugin` | Job store root |
| `CURSOR_AGENT_BIN` | `cursor-agent` | Binary to drive |
| `CURSOR_PLUGIN_PRUNE_DAYS` | `7` | Auto-prune finished jobs older than N days (0 = off) |
| `CURSOR_API_KEY` | — | Non-interactive auth for cursor-agent |

## Tests

```
tests/run.sh           # unit + integration (mocked cursor-agent), no quota used
CURSOR_LIVE=1 tests/run.sh   # also runs one real cursor-agent smoke test
```
