#!/usr/bin/env bash
# Install automated repo sync on THIS Mac (no manual push/pull habit required).
#
#   ./install-multi-mac-nightly.sh           # on login: pull all + push if ahead + audit
#   ./install-multi-mac-nightly.sh login     # same
#   ./install-multi-mac-nightly.sh 10        # also run full sync daily at 10:00
#
# Plus: every 20 minutes while you are logged in, push any repo that is committed-but-not-pushed.

set -euo pipefail

MODE="${1:-login}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HEALTH="${ROOT}/scripts/multi-mac-repo-health.sh"
PUSH="${ROOT}/scripts/auto-push-if-ahead.sh"
LOG_DIR="${HOME}/Library/Logs/multi-mac-repo-health"
PUSH_LOG="${LOG_DIR}/auto-push.log"

chmod +x "$HEALTH" "$PUSH" "${ROOT}/scripts/sync-all-repos.sh" 2>/dev/null || true
mkdir -p "$LOG_DIR" "${HOME}/.config/adam-multi-mac"

if [[ ! -f "${HOME}/.config/adam-multi-mac/machines.conf" ]]; then
  cp "${ROOT}/scripts/machines.conf.example" "${HOME}/.config/adam-multi-mac/machines.conf"
fi

# --- Login (and optional calendar) health agent ---
HEALTH_ID="com.adamblair.multi-mac-repo-health"
HEALTH_PLIST="${HOME}/Library/LaunchAgents/${HEALTH_ID}.plist"

SESSION_KEYS=""
CALENDAR_BLOCK=""
SCHEDULE_MSG="when you log in / open this Mac"

if [[ "$MODE" == "login" ]]; then
  SESSION_KEYS=$'  <key>RunAtLoad</key>\n  <true/>\n'
elif [[ "$MODE" =~ ^[0-9]+$ ]]; then
  HOUR="$MODE"
  MIN="${2:-0}"
  SESSION_KEYS=$'  <key>RunAtLoad</key>\n  <true/>\n'
  CALENDAR_BLOCK=$'  <key>StartCalendarInterval</key>\n  <dict>\n    <key>Hour</key>\n    <integer>'"${HOUR}"$'</integer>\n    <key>Minute</key>\n    <integer>'"${MIN}"$'</integer>\n  </dict>\n'
  SCHEDULE_MSG="on login and daily at ${HOUR}:$(printf '%02d' "${MIN}")"
else
  echo "Usage: $0 [login | HOUR [MINUTE]]"
  exit 1
fi

cat >"$HEALTH_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${HEALTH_ID}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>${HEALTH}</string>
  </array>
${SESSION_KEYS}${CALENDAR_BLOCK}  <key>StandardOutPath</key>
  <string>${LOG_DIR}/launchd-stdout.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/launchd-stderr.log</string>
</dict>
</plist>
EOF

# --- Periodic auto-push (committed work only) ---
PUSH_ID="com.adamblair.auto-push-repos"
PUSH_PLIST="${HOME}/Library/LaunchAgents/${PUSH_ID}.plist"

cat >"$PUSH_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${PUSH_ID}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>${PUSH}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>1200</integer>
  <key>StandardOutPath</key>
  <string>${PUSH_LOG}</string>
  <key>StandardErrorPath</key>
  <string>${PUSH_LOG}</string>
</dict>
</plist>
EOF

MY_UID="$(id -u)"
for plist in "$HEALTH_PLIST" "$PUSH_PLIST"; do
  launchctl bootout "gui/${MY_UID}" "$plist" 2>/dev/null || true
  launchctl bootstrap "gui/${MY_UID}" "$plist"
done
launchctl enable "gui/${MY_UID}/${HEALTH_ID}"
launchctl enable "gui/${MY_UID}/${PUSH_ID}"

echo "Installed automation on this Mac:"
echo "  1) ${SCHEDULE_MSG}: clone missing repos, pull all, push if already committed, audit"
echo "  2) Every 20 min while logged in: push repos that are ahead of GitHub (clean tree only)"
echo "Logs: ${LOG_DIR}/"
echo "Uncommitted work is never auto-committed — you still commit when you mean to; push happens without you remembering."