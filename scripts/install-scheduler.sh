#!/usr/bin/env bash
# usage: install-scheduler.sh install|uninstall
# Copies the plugin to a stable path (the marketplace cache path changes on every plugin update)
# and runs its poll.sh every 60s: launchd on macOS, a systemd user timer on Linux, cron otherwise.
set -euo pipefail
SRC=$(cd "$(dirname "$0")/.." && pwd)
DEST=$HOME/.local/share/pr-autopilot/plugin
LABEL=ai.pr-autopilot.poll
PLIST=$HOME/Library/LaunchAgents/$LABEL.plist
UNIT_DIR=$HOME/.config/systemd/user
STATE=${PR_AUTOPILOT_STATE:-$HOME/.local/state/pr-autopilot}

install() {
  for c in gh jq git claude; do command -v "$c" >/dev/null || { echo "missing: $c" >&2; exit 1; }; done
  mkdir -p "$(dirname "$DEST")" "$STATE"
  [ "$SRC" = "$DEST" ] || { rm -rf "$DEST"; mkdir -p "$DEST"; cp -R "$SRC/." "$DEST/"; }
  if [ "$(uname)" = Darwin ]; then
    mkdir -p "$(dirname "$PLIST")"
    cat >"$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$DEST/scripts/poll.sh</string></array>
  <key>StartInterval</key><integer>60</integer>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>$PATH</string></dict>
  <key>StandardErrorPath</key><string>$STATE/launchd.err</string>
  <key>StandardOutPath</key><string>$STATE/launchd.out</string>
</dict></plist>
PL
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo "Installed launchd job $LABEL (every 60s)."
  elif command -v systemctl >/dev/null && systemctl --user show-environment >/dev/null 2>&1; then
    mkdir -p "$UNIT_DIR"
    cat >"$UNIT_DIR/pr-autopilot.service" <<UN
[Unit]
Description=pr-autopilot poll
[Service]
Type=oneshot
Environment=PATH=$PATH
ExecStart=/bin/bash $DEST/scripts/poll.sh
UN
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
  rm -rf "$DEST"
  echo "Scheduler and installed copy removed. Config and state are kept in ~/.config/pr-autopilot and $STATE."
}

case ${1:-} in
  install) install ;;
  uninstall) uninstall ;;
  *) echo "usage: install-scheduler.sh install|uninstall" >&2; exit 2 ;;
esac
