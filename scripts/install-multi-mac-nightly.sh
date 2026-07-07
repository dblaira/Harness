#!/usr/bin/env bash
# Install LaunchAgent for multi-mac-repo-health.sh on THIS Mac.
#
# Default (what Adam wants): run when you log in / open the Mac — not at night.
# Optional: morning calendar time instead.
#
#   ./install-multi-mac-nightly.sh              # login / session start (default)
#   ./install-multi-mac-nightly.sh login        # same
#   ./install-multi-mac-nightly.sh 10           # daily 10:00 instead
#   ./install-multi-mac-nightly.sh 9 15         # daily 09:15

set -euo pipefail

MODE="${1:-login}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${ROOT}/scripts/multi-mac-repo-health.sh"
PLIST_ID="com.adamblair.multi-mac-repo-health"
PLIST="${HOME}/Library/LaunchAgents/${PLIST_ID}.plist"
LOG_DIR="${HOME}/Library/Logs/multi-mac-repo-health"

chmod +x "$SCRIPT" "${ROOT}/scripts/sync-all-repos.sh" 2>/dev/null || chmod +x "$SCRIPT"
mkdir -p "$LOG_DIR" "${HOME}/.config/adam-multi-mac"

if [[ ! -f "${HOME}/.config/adam-multi-mac/machines.conf" ]]; then
  cp "${ROOT}/scripts/machines.conf.example" "${HOME}/.config/adam-multi-mac/machines.conf"
fi

CALENDAR_BLOCK=""
SCHEDULE_MSG=""

if [[ "$MODE" == "login" ]]; then
  SESSION_KEYS=$'  <key>RunAtLoad</key>\n  <true/>\n'
  SCHEDULE_MSG="when you log in / open this Mac (and once right after install)"
elif [[ "$MODE" =~ ^[0-9]+$ ]]; then
  HOUR="$MODE"
  MIN="${2:-0}"
  CALENDAR_BLOCK=$'  <key>StartCalendarInterval</key>\n  <dict>\n    <key>Hour</key>\n    <integer>'"${HOUR}"$'</integer>\n    <key>Minute</key>\n    <integer>'"${MIN}"$'</integer>\n  </dict>\n'
  SCHEDULE_MSG="daily at ${HOUR}:$(printf '%02d' "${MIN}") local time"
else
  echo "Usage: $0 [login | HOUR [MINUTE]]"
  exit 1
fi

cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${PLIST_ID}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>${SCRIPT}</string>
  </array>
${SESSION_KEYS}${CALENDAR_BLOCK}  <key>StandardOutPath</key>
  <string>${LOG_DIR}/launchd-stdout.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/launchd-stderr.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl enable "gui/$(id -u)/${PLIST_ID}"

echo "Installed ${PLIST}"
echo "Runs: ${SCHEDULE_MSG}"
echo "Does: clone missing repos + pull, then health report"
echo "Log: ${LOG_DIR}/latest.txt"