---
description: Hand off a coding task to Cursor CLI (cursor-agent) as a background job
argument-hint: <task description>  [--model <m>] [--worktree]
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/delegate.sh:*)
---

Delegate the user's task to the Cursor CLI. The agent runs unattended in the
current repo (`--force --trust --sandbox disabled`) and edits files in place.

Run:

```
${CLAUDE_PLUGIN_ROOT}/scripts/delegate.sh $ARGUMENTS
```

The script prints a job id. Tell the user the id and that they can:
- check progress with `/cursor:status`
- read the result with `/cursor:result <id>`
- stop it with `/cursor:cancel <id>`

Do NOT block waiting for the job — it runs in the background.
