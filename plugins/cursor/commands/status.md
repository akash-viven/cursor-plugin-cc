---
description: List Cursor handoff jobs and their status
argument-hint: "[id] [--all]"
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/status.sh:*)
---

Show running and recent Cursor jobs (also prunes finished jobs older than 7 days).
With no argument, prints the job list **scoped to the current repo/folder** (the
job store is global across repos). Add `--all` to list jobs from every folder.
With an `id`, prints a live card: status, elapsed time, model, recent activity,
tool calls, and changed files.

```
${CLAUDE_PLUGIN_ROOT}/scripts/status.sh $ARGUMENTS
```

Relay the output to the user. Status values: running, done, failed, cancelled, crashed.
For a running job, the user can re-run `/cursor:status <id>` to refresh live progress.
