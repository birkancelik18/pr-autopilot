#!/usr/bin/env bash
# usage: ctl.sh pause|resume|replay|status
set -uo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
. "$DIR/lib.sh"

case ${1:-} in
  pause)
    touch "$STATE_DIR/paused"
    # Kill switch: also stop running jobs. Their notifications stay unread, so after /resume the
    # next poll starts them again.
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
    echo "pr-autopilot resumed. Jobs stopped by pause start again at the next poll."
    ;;
  replay)
    # Include unread notifications that predate going live (normally skipped).
    echo 1970-01-01T00:00:00Z >"$STATE_DIR/live_since"
    : >"$STATE_DIR/seen.tsv"
    log "REPLAY requested by user"
    echo "Next poll will also act on older unread notifications (live mode only)."
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
    echo; echo "Failed attempts (epoch, key):"; tail -5 "$STATE_DIR/failed.tsv" 2>/dev/null
    echo; echo "Recent reports and failures:"
    grep 'REPORT' "$STATE_DIR/polls.log" 2>/dev/null | tail -8
    ;;
  *) echo "usage: ctl.sh pause|resume|replay|status" >&2; exit 2 ;;
esac
