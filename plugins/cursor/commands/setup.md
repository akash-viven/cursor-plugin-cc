---
description: Verify Cursor CLI install, auth, and dependencies
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh:*)
---

Run the preflight check for the Cursor handoff plugin (cursor-agent on PATH,
version, jq, auth, job store).

```
${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh
```

Relay results. If anything fails, walk the user through the suggested fix.
