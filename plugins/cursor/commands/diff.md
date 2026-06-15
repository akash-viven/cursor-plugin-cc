---
description: Show the git diff of what a Cursor handoff job changed
argument-hint: <id> [--stat]
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/diff.sh:*)
---

Show what a Cursor job actually changed, as a git diff in the job's repo. Jobs
run with the sandbox disabled and edit files in place, so this is the review
surface before you keep or revert the work.

```
${CLAUDE_PLUGIN_ROOT}/scripts/diff.sh $ARGUMENTS
```

Scopes the diff to the files the job touched. Pass `--stat` for a summary only.
After reviewing, the user can keep the changes, revert with `git`, or continue
the thread with `/cursor:resume <id> <follow-up>`.
