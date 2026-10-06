# Shared helpers, sourced by poll.sh, job.sh and ctl.sh. Needs bash, gh, jq, git, claude.
STATE_DIR=${PR_AUTOPILOT_STATE:-$HOME/.local/state/pr-autopilot}
CONFIG=${PR_AUTOPILOT_CONFIG:-$HOME/.config/pr-autopilot/config.json}
PLUGIN_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$STATE_DIR"/{logs,running,events,worktrees,bodies}

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >>"$STATE_DIR/polls.log"; }
cfg() { jq -r "$1" "$CONFIG"; } # usage: cfg '.slack_webhook // ""'
# cfgd <key> <default-json>: like cfg but keeps an explicit false (jq's // would replace it).
cfgd() { jq -r --argjson d "$2" ".$1 as \$v | if \$v == null then \$d else \$v end" "$CONFIG"; }

# report <message>: macOS notification (notify-send on Linux) plus Slack if configured.
report() {
  local msg=$1 hook
  log "REPORT $msg"
  if [ "$(uname)" = Darwin ]; then
    osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title "pr-autopilot"' \
      -e 'end run' -- "$msg" >/dev/null 2>&1 || log "osascript failed"
  elif command -v notify-send >/dev/null; then
    notify-send pr-autopilot "$msg" || log "notify-send failed"
  fi
  hook=$(cfg '.slack_webhook // ""' 2>/dev/null || true)
  if [ -n "$hook" ]; then
    curl -sS -m 20 -X POST -H 'Content-type: application/json' \
      -d "$(jq -nc --arg text "$msg" '{text:$text}')" "$hook" >/dev/null 2>>"$STATE_DIR/polls.log" ||
      log "slack post failed"
  fi
}

# report_throttled <message>: for poller-level failures that repeat every minute (max 1 per hour).
report_throttled() {
  local f=$STATE_DIR/last_error_report
  if [ ! -f "$f" ] || [ -n "$(find "$f" -mmin +60 2>/dev/null)" ]; then
    touch "$f"
    report "$1"
  else
    log "ERROR (report throttled) $1"
  fi
}
