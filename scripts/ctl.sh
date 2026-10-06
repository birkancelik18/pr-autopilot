#!/usr/bin/env bash
# usage: ctl.sh pause|resume|status
set -uo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
. "$DIR/lib.sh"

case ${1:-} in
  pause)
    touch "$STATE_DIR/paused"
    # Kill switch: also stop jobs that are mid-run (they have posted nothing yet unless at their last step).
    for f in "$STATE_DIR"/running/*; do
      [ -e "$f" ] || continue
      pkill -TERM -P "$(basename "$f")" 2>/dev/null
      kill -TERM "$(basename "$f")" 2>/dev/null
    done
    log "PAUSED by user"
    echo "pr-autopilot paused: the poller does nothing and running jobs were stopped."
    ;;
  resume)
    rm -f "$STATE_DIR/paused"
    log "RESUMED by user"
    echo "pr-autopilot resumed."
    ;;
  status)
    [ -f "$STATE_DIR/paused" ] && echo "State: PAUSED" || echo "State: active"
    if [ -f "$CONFIG" ]; then
      echo "dry_run: $(cfgd dry_run true)   repos: $(cfg '.repos | keys | join(", ")')"
    else
      echo "No config at $CONFIG (run /pr-autopilot:setup)"
    fi
    echo; echo "Last polls:"
    grep -E 'poll done|paused|poll failed|ERROR' "$STATE_DIR/polls.log" 2>/dev/null | tail -5
    echo; echo "Running jobs:"
    for f in "$STATE_DIR"/running/*; do
      [ -e "$f" ] && kill -0 "$(basename "$f")" 2>/dev/null && echo "  pid $(basename "$f"): $(cat "$f")"
    done
    echo; echo "Recent jobs (newest first, logs in $STATE_DIR/logs):"
    ls -t "$STATE_DIR/logs"/*.log 2>/dev/null | head -8 | while read -r l; do
      echo "  $(basename "$l")$(grep -q '^FAILED' "$l" && echo '   <-- FAILED')"
    done
    echo; echo "Recent reports and failures:"
    grep 'REPORT' "$STATE_DIR/polls.log" 2>/dev/null | tail -8
    ;;
  *) echo "usage: ctl.sh pause|resume|status" >&2; exit 2 ;;
esac
