---
description: Hand off a coding task to Cursor CLI (cursor-agent) as a background job
argument-hint: <task description>  [--model <m>] [--retry <n>] [--worktree]
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/delegate.sh:*)
---

Delegate the user's task to the Cursor CLI. The agent runs unattended in the
current repo (`--force --trust --sandbox disabled`) and edits files in place.

Run:

```
${CLAUDE_PLUGIN_ROOT}/scripts/delegate.sh $ARGUMENTS
```

Optional flags: `--model <m>`, `--retry <n>` (auto-resume on crash/failure up to n
times), `--worktree` (isolate edits in a throwaway git worktree).

The script prints a job id. Tell the user the id and that they can:
- watch live progress with `/cursor:status <id>` (activity, tool calls, changed files, tokens, cost)
- review the diff with `/cursor:diff <id>`
- read the result with `/cursor:result <id>`
- stop it with `/cursor:cancel <id>`

Do NOT block waiting for the job — it runs in the background. When it finishes, a
Stop hook will surface the result to you automatically.
