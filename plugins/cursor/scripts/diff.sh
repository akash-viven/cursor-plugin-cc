#!/usr/bin/env bash
# diff.sh — show what a job actually changed, as a git diff in its repo.
# Jobs run --sandbox disabled and edit in place, so the working-tree diff IS
# the review surface. We diff the whole working tree (vs HEAD) rather than
# scoping to stream-derived files: models mutate files in wildly different
# ways (edit/write tools, or plain shell `>>`/`tee` redirects), so the tree
# is the only reliable source of truth for in-place edits. Usage:
#   diff.sh <id> [--stat]
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

STAT=0
ARG=""
for a in "$@"; do
  case "$a" in --stat) STAT=1;; *) ARG="$a";; esac
done
[ -n "$ARG" ] || die "usage: diff.sh <id> [--stat]"

id="$(resolve_job_id "$ARG")"
cwd="$(job_field "$id" cwd)"
[ -d "$cwd" ] || die "job $id has no recorded working directory"
git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "$cwd is not a git repository — nothing to diff against"

# Header: status + repo, matching the result card.
st="$(job_status "$id")"
printf '\n'
printf '  %s %s   %s\n\n' "$(status_icon "$st")" "$(status_color "$st")" "$(dim "$cwd")"

# Colorize only when writing to a tty (honors NO_COLOR via git config too).
GIT_COLOR=(-c color.ui=never)
_supports_color && GIT_COLOR=(-c color.ui=always)
GIT=(git -C "$cwd" "${GIT_COLOR[@]}" --no-pager)

# Untracked, new files the agent created (not yet in the index).
untracked=()
while IFS= read -r f; do [ -n "$f" ] && untracked+=("$f"); done < <(
  "${GIT[@]}" ls-files --others --exclude-standard 2>/dev/null
)

# Anything changed vs HEAD (staged or unstaged) or any new file?
tracked_changes="$("${GIT[@]}" diff HEAD --name-only 2>/dev/null || true)"
if [ -z "$tracked_changes" ] && [ "${#untracked[@]}" -eq 0 ]; then
  printf '  %s\n\n' "$(dim 'no uncommitted changes in the working tree')"
  exit 0
fi

if [ "$STAT" -eq 1 ]; then
  [ -n "$tracked_changes" ] && "${GIT[@]}" diff HEAD --stat
  for f in "${untracked[@]}"; do
    printf '  %s %s %s\n' "$(c 32 '+')" "$f" "$(dim '(new file)')"
  done
  printf '\n'
  exit 0
fi

# Tracked changes (staged + unstaged) vs the last commit.
[ -n "$tracked_changes" ] && "${GIT[@]}" diff HEAD
# New files shown as additions via the /dev/null trick.
for f in "${untracked[@]}"; do
  "${GIT[@]}" diff --no-index -- /dev/null "$cwd/$f" 2>/dev/null || true
done
printf '\n'
