# Shared helpers, sourced by poll.sh, job.sh and ctl.sh. Needs bash, gh, jq, git, claude.
STATE_DIR=${PR_AUTOPILOT_STATE:-$HOME/.local/state/pr-autopilot}
CONFIG=${PR_AUTOPILOT_CONFIG:-$HOME/.config/pr-autopilot/config.json}
PLUGIN_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
mkdir -p "$STATE_DIR"/{logs,running,events,worktrees,jobs}
touch "$STATE_DIR/polls.log"

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >>"$STATE_DIR/polls.log"; }
cfg() { jq -r "$1" "$CONFIG"; } # usage: cfg '.slack_webhook // ""'
# cfgd <key> <default-json>: like cfg but keeps an explicit false (jq's // would replace it).
cfgd() { jq -r --argjson d "$2" ".$1 as \$v | if \$v == null then \$d else \$v end" "$CONFIG"; }
is_paused() { [ -f "$STATE_DIR/paused" ]; }

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
      -d "$(jq -nc --arg text "$(printf '%s' "$msg" | slack_escape)" '{text:$text}')" "$hook" >/dev/null 2>>"$STATE_DIR/polls.log" ||
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

# repo_chunks <max-len>: one line per group of "repo:a repo:b" qualifiers short enough for GitHub's
# 256-char search query limit.
repo_chunks() {
  jq -r --argjson max "$1" '.repos | keys | map("repo:" + .)
    | reduce .[] as $r ([""]; if (.[-1] | length) + ($r | length) + 1 > $max then . + [$r]
      else (.[-1] |= (if . == "" then $r else . + " " + $r end)) end) | .[]' "$CONFIG"
}

# slack_escape: Slack treats <, > and & specially (<!channel> pings everyone).
slack_escape() { jq -Rrs 'gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;")'; }

# defang: model-written text must not ping people; wrap @mentions in backticks.
defang() { jq -Rrs 'gsub("@(?<n>[A-Za-z0-9_][A-Za-z0-9_/-]*)"; "`@\(.n)`")'; }

# gc: drop leftovers of dead jobs (worktrees, refs) and rotate logs. Called by poll.sh.
# Directory and ref names end in the owning job's pid.
gc() {
  local d pid clone ref
  for d in "$STATE_DIR"/worktrees/*; do
    [ -d "$d" ] || continue
    pid=${d##*-}
    kill -0 "$pid" 2>/dev/null || rm -rf "$d"
  done
  if [ -f "$CONFIG" ]; then
    while IFS= read -r clone; do
      [ -d "$clone" ] || continue
      git -C "$clone" worktree prune 2>/dev/null
      git -C "$clone" for-each-ref --format='%(refname)' refs/pr-autopilot 2>/dev/null |
        while read -r ref; do
          pid=${ref##*-}
          kill -0 "$pid" 2>/dev/null || git -C "$clone" update-ref -d "$ref" 2>/dev/null
        done
    done < <(jq -r '.repos[]' "$CONFIG")
  fi
  find "$STATE_DIR/logs" "$STATE_DIR/jobs" "$STATE_DIR/events" -mindepth 1 -maxdepth 1 -mtime +14 \
    -exec rm -rf {} + 2>/dev/null
  if [ "$(wc -c <"$STATE_DIR/polls.log" 2>/dev/null || echo 0)" -gt 1000000 ]; then
    tail -n 2000 "$STATE_DIR/polls.log" >"$STATE_DIR/polls.log.tmp" &&
      mv "$STATE_DIR/polls.log.tmp" "$STATE_DIR/polls.log"
  fi
  return 0
}
