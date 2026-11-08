#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
#
# Runs scripts/nightly.sh every day at the given time (default 04:30) on
# this Mac -- the one with the signing certificate -- as the LaunchAgent
# org.melody.macos-nightly, logging to ~/Library/Logs/Melody/nightly.log.
# A Mac asleep at that time runs it when it wakes.
#
#   scripts/install-nightly.sh [HH:MM] | --remove

set -euo pipefail

label=org.melody.macos-nightly
agent="$HOME/Library/LaunchAgents/$label.plist"
uid=$(id -u)

if [[ ${1:-} == --remove ]]; then
    launchctl bootout "gui/$uid/$label" 2>/dev/null || true
    rm -f "$agent"
    printf 'Removed %s\n' "$agent"
    exit 0
fi

time=${1:-04:30}
[[ $time =~ ^([0-9]{1,2}):([0-9]{2})$ ]] || { printf 'time must be HH:MM\n' >&2; exit 2; }
hour=$((10#${BASH_REMATCH[1]}))
minute=$((10#${BASH_REMATCH[2]}))
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
logs="$HOME/Library/Logs/Melody"
mkdir -p "$logs" "$(dirname "$agent")"

cat >"$agent" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$label</string>
	<key>ProgramArguments</key>
	<array>
		<string>$root/scripts/nightly.sh</string>
	</array>
	<key>StartCalendarInterval</key>
	<dict>
		<key>Hour</key>
		<integer>$hour</integer>
		<key>Minute</key>
		<integer>$minute</integer>
	</dict>
	<key>StandardOutPath</key>
	<string>$logs/nightly.log</string>
	<key>StandardErrorPath</key>
	<string>$logs/nightly.log</string>
</dict>
</plist>
EOF
plutil -lint "$agent" >/dev/null
launchctl bootout "gui/$uid/$label" 2>/dev/null || true
launchctl bootstrap "gui/$uid" "$agent"
printf 'Every day at %02d:%02d: %s/scripts/nightly.sh (log %s/nightly.log)\n' "$hour" "$minute" "$root" "$logs"
