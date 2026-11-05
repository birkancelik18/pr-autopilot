#!/usr/bin/env bash
# usage: install-scheduler.sh install|uninstall|version|print-plist|print-unit
# Copies the plugin to a versioned directory under ~/.local/share/pr-autopilot and points a stable
# `plugin` symlink at it (the marketplace cache path changes on every plugin update, and a running
# job must keep its own files). Then runs plugin/scripts/poll.sh every 60s: launchd on macOS, a
# systemd user timer on Linux, cron otherwise.
set -euo pipefail
SRC=$(cd "$(dirname "$0")/.." && pwd -P)
BASE=$HOME/.local/share/pr-autopilot
DEST=$BASE/plugin
LABEL=ai.pr-autopilot.poll
PLIST=$HOME/Library/LaunchAgents/$LABEL.plist
UNIT_DIR=$HOME/.config/systemd/user
STATE=${PR_AUTOPILOT_STATE:-$HOME/.local/state/pr-autopilot}

# Jobs are children of the poller. Without AbandonProcessGroup (launchd) / KillMode=process
# (systemd) the scheduler kills them the moment poll.sh exits.
xml_escape() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }
render_plist() {
  local xpath; xpath=$(printf '%s' "$PATH" | xml_escape)
  cat <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$DEST/scripts/poll.sh</string></array>
  <key>StartInterval</key><integer>60</integer>
  <key>AbandonProcessGroup</key><true/>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>$xpath</string></dict>
  <key>StandardErrorPath</key><string>$STATE/launchd.err</string>
  <key>StandardOutPath</key><string>$STATE/launchd.out</string>
</dict></plist>
PL
}
render_unit() {
  cat <<UN
[Unit]
Description=pr-autopilot poll
[Service]
Type=oneshot
KillMode=process
Environment=PATH=$PATH
ExecStart=/bin/bash $DEST/scripts/poll.sh
UN
}

live_jobs() { # any job still running?
  local f
  for f in "$STATE"/running/*; do [ -e "$f" ] && kill -0 "$(basename "$f")" 2>/dev/null && return 0; done
  return 1
}

# With notify_style "notification", send one test banner: it makes macOS ask for (or list)
# terminal-notifier's permission, and shows the user whether a click opens a link.
notify_test() {
  local cfg=${PR_AUTOPILOT_CONFIG:-$HOME/.config/pr-autopilot/config.json}
  [ "$(jq -r '.notify_style // "window"' "$cfg" 2>/dev/null)" = notification ] || return 0
  if ! command -v terminal-notifier >/dev/null; then
    echo "notify_style is notification but terminal-notifier is missing: brew install terminal-notifier"
    return 0
  fi
  if terminal-notifier -title pr-autopilot -message "test" -open https://github.com >/dev/null 2>&1; then
    echo "Sent a test notification: click it, it should open github.com."
  else
    echo "macOS blocked the test notification. Allow it in System Settings > Notifications > terminal-notifier, then re-run setup. Until then notifications still show, but a click opens Script Editor."
  fi
}

version_of() { jq -r '.version // "unknown"' "$1/.claude-plugin/plugin.json" 2>/dev/null || echo unknown; }
# versions: what this script would install, and what the scheduler runs now.
versions() {
  echo "source:    $(version_of "$SRC") ($SRC)"
  echo "installed: $(version_of "$DEST") ($(cd "$DEST" 2>/dev/null && pwd -P || echo "$DEST, not installed"))"
}

install() {
  for c in gh jq git claude; do command -v "$c" >/dev/null || { echo "missing: $c" >&2; exit 1; }; done
  mkdir -p "$BASE" "$STATE"
  rm -f "$STATE/paused" # a leftover pause from an earlier uninstall must not silence a fresh setup
  if [ "$SRC" != "$(cd "$DEST" 2>/dev/null && pwd -P)" ]; then
    local new
    new=$BASE/plugin-$(date +%s)
    mkdir -p "$new" && cp -R "$SRC/." "$new/"
    ln -sfn "$new" "$DEST.tmp"
    mv -fh "$DEST.tmp" "$DEST" 2>/dev/null || mv -fT "$DEST.tmp" "$DEST"
    # Drop older copies, but never under a running job.
    live_jobs || find "$BASE" -mindepth 1 -maxdepth 1 -name 'plugin-*' ! -path "$new" -exec rm -rf {} +
  fi
  echo "Scheduler now runs pr-autopilot $(version_of "$DEST") (copied from $SRC)."
  if [ "$(uname)" = Darwin ]; then
    mkdir -p "$(dirname "$PLIST")"
    render_plist >"$PLIST"
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    # bootout is asynchronous; bootstrap can fail until the old job is gone, so retry.
    local _
    for _ in 1 2 3 4 5 6; do launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null && break; sleep 1; done
    launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || { echo "launchd did not load $LABEL" >&2; exit 1; }
    echo "Installed launchd job $LABEL (every 60s)."
    notify_test
  elif command -v systemctl >/dev/null && systemctl --user show-environment >/dev/null 2>&1; then
    mkdir -p "$UNIT_DIR"
    render_unit >"$UNIT_DIR/pr-autopilot.service"
    cat >"$UNIT_DIR/pr-autopilot.timer" <<UN
[Unit]
Description=pr-autopilot poll every minute
[Timer]
OnBootSec=60
OnUnitActiveSec=60
[Install]
WantedBy=timers.target
UN
    systemctl --user daemon-reload
    systemctl --user enable --now pr-autopilot.timer
    echo "Installed systemd user timer pr-autopilot.timer (every 60s)."
  else
    (crontab -l 2>/dev/null | grep -v '# pr-autopilot' || true
      echo "* * * * * PATH=$PATH /bin/bash $DEST/scripts/poll.sh # pr-autopilot") | crontab -
    echo "Installed cron entry (every minute)."
  fi
}

uninstall() {
  if [ "$(uname)" = Darwin ]; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
  fi
  if command -v systemctl >/dev/null; then
    systemctl --user disable --now pr-autopilot.timer 2>/dev/null || true
    rm -f "$UNIT_DIR/pr-autopilot.service" "$UNIT_DIR/pr-autopilot.timer"
  fi
  if command -v crontab >/dev/null && crontab -l 2>/dev/null | grep -q '# pr-autopilot'; then
    crontab -l | grep -v '# pr-autopilot' | crontab - || true
  fi
  rm -f "$STATE/paused"
  # Leftover worktrees and refs of jobs that were stopped.
  if [ -f "${PR_AUTOPILOT_CONFIG:-$HOME/.config/pr-autopilot/config.json}" ]; then
    local clone ref
    while IFS= read -r clone; do
      [ -d "$clone" ] || continue
      git -C "$clone" for-each-ref --format='%(refname)' refs/pr-autopilot 2>/dev/null |
        while read -r ref; do git -C "$clone" update-ref -d "$ref" 2>/dev/null; done
      git -C "$clone" worktree prune 2>/dev/null
    done < <(jq -r '.repos[]' "${PR_AUTOPILOT_CONFIG:-$HOME/.config/pr-autopilot/config.json}")
  fi
  rm -rf "$STATE/worktrees"
  if live_jobs; then
    echo "Jobs are still running; the installed copy in $BASE is kept (delete it later)."
  else
    rm -rf "$DEST" "$BASE"/plugin-*
  fi
  echo "Scheduler removed. Config and state are kept in ~/.config/pr-autopilot and $STATE."
}

case ${1:-} in
  install) install ;;
  notify-test) notify_test ;;
  version) versions ;;
  uninstall) uninstall ;;
  print-plist) render_plist ;;
  print-unit) render_unit ;;
  *) echo "usage: install-scheduler.sh install|uninstall|version|print-plist|print-unit" >&2; exit 2 ;;
esac
