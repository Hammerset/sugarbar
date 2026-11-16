#!/bin/bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
support="$HOME/Library/Application Support/sugarbar-server"
agent="$HOME/Library/LaunchAgents/com.sugarbar.server-backup.plist"

mkdir -p "$support"
install -m 755 "$here/backup.sh" "$support/backup.sh"
sed -e "s|__SCRIPT__|$support/backup.sh|" -e "s|__HOME__|$HOME|g" \
    "$here/com.sugarbar.server-backup.plist" > "$agent"
plutil -lint "$agent" >/dev/null

launchctl bootout "gui/$(id -u)/com.sugarbar.server-backup" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$agent"
echo "Installed $agent; run now with: launchctl kickstart gui/$(id -u)/com.sugarbar.server-backup"
