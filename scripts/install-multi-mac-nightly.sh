#!/usr/bin/env bash
# Install nightly LaunchAgent for multi-mac-repo-health.sh on THIS Mac.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${ROOT}/scripts/multi-mac-repo-health.sh"
PLIST_ID="com.adamblair.multi-mac-repo-health"
PLIST="${HOME}/Library/LaunchAgents/${PLIST_ID}.plist"
LOG_DIR="${HOME}/Library/Logs/multi-mac-repo-health"

chmod +x "$SCRIPT"
mkdir -p "$LOG_DIR" "${HOME}/.config/adam-multi-mac"

if [[ ! -f "${HOME}/.config/adam-multi-mac/machines.conf" ]]; then
  cp "${ROOT}/scripts/machines.conf.example" "${HOME}/.config/adam-multi-mac/machines.conf"
  echo "Created ~/.config/adam-multi-mac/machines.conf — add your SSH host aliases."
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
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>23</integer>
    <key>Minute</key>
    <integer>30</integer>
  </dict>
  <key>StandardOutPath</key>
  <string>${LOG_DIR}/launchd-stdout.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/launchd-stderr.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl enable "gui/$(id -u)/${PLIST_ID}"

echo "Installed ${PLIST} (runs daily 23:30 local time)."
echo "Test now: ${SCRIPT}"
echo "Latest report: ${LOG_DIR}/latest.txt"