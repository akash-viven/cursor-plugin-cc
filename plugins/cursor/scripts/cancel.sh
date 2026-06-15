#!/usr/bin/env bash
# cancel.sh — stop a running job and mark it cancelled.
# Usage: cancel.sh <id>
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

[ $# -ge 1 ] || die "usage: cancel.sh <id>"
id="$(resolve_job_id "$1")"
jd="$(job_dir "$id")"
st="$(job_status "$id")"

case "$st" in
  running) ;;
  *) log "job $id is '$st', nothing to cancel."; exit 0;;
esac

pid="$(job_field "$id" pid)"
if [ -n "$pid" ]; then
  kill_tree "$pid"
fi
printf 'cancelled' > "$jd/status"
log "cancelled job $id"
