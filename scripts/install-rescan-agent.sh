#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
#
# Keeps a server's library up to date with its music folder by itself.
# melodyd on macOS does not watch the music folder, and a NAS share would
# not tell it of files written there anyway: new albums appear only when
# something rescans. This installs, on TARGET:
#
#   ~/Library/Application Support/melody/rescan.sh
#   LaunchAgent org.melody.rescan-new   every MINUTES (default 10): the
#       artist and album folders changed since the last run, rescanned
#       (melody-cli update FOLDER...) -- a few seconds over SMB
#   LaunchAgent org.melody.rescan-all   daily at HH:MM (default 05:00): the
#       whole library, which also drops what is gone and re-reads retags
#
# Log: ~/Library/Logs/Melody/rescan.log.
#
#   scripts/install-rescan-agent.sh [--every MINUTES] [--full-at HH:MM] TARGET MUSIC_FOLDER
#   scripts/install-rescan-agent.sh --remove TARGET
#
# TARGET is "local" or an SSH host. MUSIC_FOLDER is the engine's music
# folder, as the engine sees it (/Volumes/media/imusic on the Mac mini).

set -euo pipefail

every=10
full_at=05:00
remove=no
while (($# > 0)); do
    case $1 in
    --every) every=$2; shift 2 ;;
    --full-at) full_at=$2; shift 2 ;;
    --remove) remove=yes; shift ;;
    -h|--help) sed -n '4,22p' "$0"; exit 0 ;;
    -*) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    *) break ;;
    esac
done
if [[ $remove == yes ]]; then
    (($# == 1)) || { sed -n '19,20p' "$0" >&2; exit 2; }
else
    (($# == 2)) || { sed -n '19,20p' "$0" >&2; exit 2; }
    [[ $every =~ ^[0-9]+$ ]] && ((every >= 1)) || { echo "--every is minutes" >&2; exit 2; }
    [[ $full_at =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "--full-at is HH:MM" >&2; exit 2; }
fi
target=$1
music=${2:-}

# The rescan itself, run by the agents: "new" or "all".
read -r -d '' rescan <<'RESCAN' || true
#!/bin/bash
# Installed by melody-macos scripts/install-rescan-agent.sh.
set -u
mode=$1 music=$2
cli="/Applications/Melody Engine.app/Contents/MacOS/melody-cli"
state="$HOME/Library/Application Support/melody"
stamp="$state/rescan-new.stamp"
say() { printf '%s %s: %s\n' "$(date '+%F %T')" "$mode" "$*"; }
# A share not mounted is not a library emptied: nothing is asked.
if [[ ! -d $music ]] || [[ -z $(ls -A "$music" 2>/dev/null | head -1) ]]; then
    say "$music is not there; nothing rescanned"
    exit 0
fi
if [[ $mode == all ]]; then
    if out=$("$cli" --local update 2>&1); then say "${out##*$'\n'}"; else say "failed: ${out##*$'\n'}"; fi
    exit 0
fi
# Stamped before the sweep: what arrives during it is found next time.
next=$(mktemp "$state/rescan-new.XXXXXX")
if [[ -f $stamp ]]; then newer=(-newer "$stamp"); else newer=(-mmin -60); fi
folders=()
while IFS= read -r -d '' folder; do
    folders+=("$folder")
done < <(find "$music" -mindepth 1 -maxdepth 2 -type d ! -name '.*' "${newer[@]}" -print0 2>/dev/null)
if ((${#folders[@]} == 0)); then
    mv "$next" "$stamp"
    exit 0
fi
if out=$("$cli" --local update "${folders[@]}" 2>&1); then
    mv "$next" "$stamp"
    say "${#folders[@]} folder(s): ${out##*$'\n'}"
    printf '  %s\n' "${folders[@]#"$music"/}"
else
    # The stamp stays: the same folders are asked again next time.
    rm -f "$next"
    say "failed, tried again next time: ${out##*$'\n'}"
fi
RESCAN

# What runs on TARGET: $1 remove, $2 music, $3 every, $4 hour, $5 minute;
# the rescan script on stdin after a line "--".
read -r -d '' installer <<'INSTALLER' || true
set -euo pipefail
remove=$1 music=$2 every=$3 hour=$4 minute=$5
uid=$(id -u)
state="$HOME/Library/Application Support/melody"
agents="$HOME/Library/LaunchAgents"
for label in org.melody.rescan-new org.melody.rescan-all; do
    launchctl bootout "gui/$uid/$label" 2>/dev/null || true
    rm -f "$agents/$label.plist"
done
if [[ $remove == yes ]]; then
    rm -f "$state/rescan.sh" "$state/rescan-new.stamp"
    echo "  removed the rescan agents"
    exit 0
fi
mkdir -p "$state" "$agents" "$HOME/Library/Logs/Melody"
cat >"$state/rescan.sh"
chmod 755 "$state/rescan.sh"
log="$HOME/Library/Logs/Melody/rescan.log"
plist() { # label mode schedule-xml
    cat >"$agents/$1.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$1</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$state/rescan.sh</string>
        <string>$2</string>
        <string>$music</string>
    </array>
    $3
    <key>LowPriorityIO</key><true/>
    <key>ProcessType</key><string>Background</string>
    <key>StandardOutPath</key><string>$log</string>
    <key>StandardErrorPath</key><string>$log</string>
</dict>
</plist>
PLIST
    launchctl bootstrap "gui/$uid" "$agents/$1.plist"
}
plist org.melody.rescan-new new "<key>StartInterval</key><integer>$((every * 60))</integer>
    <key>RunAtLoad</key><true/>"
plist org.melody.rescan-all all "<key>StartCalendarInterval</key>
    <dict><key>Hour</key><integer>$hour</integer><key>Minute</key><integer>$minute</integer></dict>"
echo "  new folders in $music rescanned every $every minutes; all of it daily at $(printf '%02d:%02d' "$hour" "$minute")"
echo "  log: $log"
INSTALLER

hour=$((10#${full_at%%:*}))
minute=$((10#${full_at##*:}))
args=("$remove" "$music" "$every" "$hour" "$minute")
printf '==> %s\n' "$target"
if [[ $target == local ]]; then
    bash -c "$installer" installer "${args[@]}" <<<"$rescan"
else
    # The installer as a command, the rescan script as its input.
    ssh "$target" "bash -c $(printf '%q' "$installer") installer $(printf '%q ' "${args[@]}")" <<<"$rescan"
fi
