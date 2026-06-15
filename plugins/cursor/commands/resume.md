---
description: Continue a finished Cursor job's session with new instructions
argument-hint: <id> <new instructions> [--model <m>]
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/resume.sh:*)
---

Resume the session of a previous Cursor job and give it new instructions. This
spawns a NEW background job that continues the prior thread (via its session id),
running in the original job's repo.

```
${CLAUDE_PLUGIN_ROOT}/scripts/resume.sh $ARGUMENTS
```

Prints a new job id. Track it like any other job with `/cursor:status`.
