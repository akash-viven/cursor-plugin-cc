---
description: Show the final result of a Cursor handoff job
argument-hint: <id> [--json]
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/result.sh:*)
---

Print the final output of a finished Cursor job, plus its session id for resuming.

```
${CLAUDE_PLUGIN_ROOT}/scripts/result.sh $ARGUMENTS
```

The output includes any changed files, token/cost usage, an activity summary, the
result text, and the session id for resuming. To see exactly what changed, use
`/cursor:diff <id>`. If the job is still running, tell the user to watch live
progress with `/cursor:status <id>`.
