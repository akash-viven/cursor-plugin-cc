---
description: List Cursor handoff jobs and their status
argument-hint: "[id]"
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/status.sh:*)
---

Show running and recent Cursor jobs (also prunes finished jobs older than 7 days).

```
${CLAUDE_PLUGIN_ROOT}/scripts/status.sh $ARGUMENTS
```

Relay the table to the user. Status values: running, done, failed, cancelled, crashed.
