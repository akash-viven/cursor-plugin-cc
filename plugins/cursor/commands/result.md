---
description: Show the final result of a Cursor handoff job
argument-hint: <id> [--json]
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/result.sh:*)
---

Print the final output of a finished Cursor job, plus its session id for resuming.

```
${CLAUDE_PLUGIN_ROOT}/scripts/result.sh $ARGUMENTS
```

If the job is still running, tell the user to wait and re-check with `/cursor:status`.
