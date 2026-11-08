#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
#
# Installs a Melody DMG on a Mac -- this one, or another over SSH -- and
# moves it off whatever ran Melody there before. After this, Melody Engine
# keeps the Mac up to date by itself.
#
#   scripts/install-mac.sh [--server] TARGET DMG
#
# TARGET is "local" or an SSH host (as in ~/.ssh/config).
#
# A listening Mac (the default): Melody and Melody Engine go to
# /Applications; Melody Engine opens at login, to install updates, and
# Melody starts its own melodyd when it needs one.
#
# --server: only Melody Engine, which runs melodyd at login from inside the
# app (melody-engine --enable-engine), with the engine's usual state,
# ~/.config/melody/melodyd.conf and socket.
#
# Moved aside, never deleted, into ~/Library/Application Support/melody/
# install-backups/<time>: the old launcher ~/Applications/Melody.app, copies
# of the official plugins in ~/Library/Application Support/melody/plugins
# (which would hide the app's own, newer ones), and on a server the
# LaunchAgents com.zeltak.melodyd and org.melody.status and
# /Applications/Melody Engine Status.app; and the LaunchAgent
# org.melody.environment, which set QT_SCALE_FACTOR before Melody's own
# Settings › General › Interface size worked. A melodyd running from a
# build folder is stopped, as are the Melody apps themselves.

set -euo pipefail

server=no
while (($# > 0)); do
    case $1 in
    --server) server=yes; shift ;;
    -h|--help) sed -n '4,27p' "$0"; exit 0 ;;
    -*) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    *) break ;;
    esac
done
(($# == 2)) || { sed -n '8,10p' "$0" >&2; exit 2; }
target=$1
dmg=$2
[[ -f $dmg ]] || { printf 'no such DMG: %s\n' "$dmg" >&2; exit 1; }

# What runs on the Mac being installed: $1 the DMG there, $2 server.
read -r -d '' installer <<'INSTALLER' || true
set -euo pipefail
dmg=$1 server=$2
uid=$(id -u)
support="$HOME/Library/Application Support/melody"
backup="$support/install-backups/$(date +%Y%m%d-%H%M%S)"
engine_app="/Applications/Melody Engine.app"
say() { printf '  %s\n' "$*"; }
keep() { mkdir -p "$backup"; mv "$1" "$backup/"; say "moved aside: $1"; }

mount=$(mktemp -d /tmp/melody-dmg.XXXXXX)
hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$mount" "$dmg"
trap 'hdiutil detach -quiet -force "$mount" 2>/dev/null; rmdir "$mount" 2>/dev/null; rm -f "$dmg"' EXIT
apps=("Melody Engine")
[[ $server == yes ]] || apps+=(Melody)
for app in "${apps[@]}"; do
    codesign --verify --deep --strict "$mount/$app.app" ||
        { printf '%s.app in the DMG is not intact\n' "$app" >&2; exit 1; }
done
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$mount/Melody Engine.app/Contents/Info.plist")
minimum=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$mount/Melody Engine.app/Contents/Info.plist")
running=$(sw_vers -productVersion)
if [[ $(printf '%s\n%s\n' "$minimum" "$running" | sort -V | head -1) != "$minimum" ]]; then
    printf 'build %s needs macOS %s; this Mac runs %s\n' "$build" "$minimum" "$running" >&2
    exit 1
fi
say "build $build on $(scutil --get ComputerName), macOS $running"

# --- Stop what runs from the old copies -----------------------------------
launchctl bootout "gui/$uid/org.melody.engine-app" 2>/dev/null || true
pkill -x melody-engine 2>/dev/null || true
# The Melody window, from here or from the old launcher.
melody_was_open=no
if pkill -TERM -f '/Melody\.app/Contents/MacOS/(melody|Melody)$' 2>/dev/null; then
    melody_was_open=yes
    say "quit Melody"
fi
# A melodyd started from a build folder (by the old launcher); one under a
# LaunchAgent is left to the agent's own handling below.
if pkill -TERM -f "^$HOME/dev/.*/melodyd( |$)" 2>/dev/null; then
    say "stopped the melodyd running from a build folder"
fi
sleep 2

# --- Move the old setup aside -------------------------------------------------
launcher="$HOME/Applications/Melody.app"
if [[ -d $launcher ]] &&
    [[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$launcher/Contents/Info.plist" 2>/dev/null) != org.melody.Melody ]]; then
    keep "$launcher"
fi
if [[ $server == no && -d "$mount/Melody.app/Contents/share/melody/plugins" ]]; then
    for official in "$mount/Melody.app/Contents/share/melody/plugins"/*/; do
        copy="$support/plugins/$(basename "$official")"
        if [[ -d $copy ]]; then
            mkdir -p "$backup/plugins"
            mv "$copy" "$backup/plugins/"
            say "moved aside the old copy of the $(basename "$official") plugin"
        fi
    done
fi
if [[ $server == yes ]]; then
    for label in com.zeltak.melodyd org.melody.status; do
        plist="$HOME/Library/LaunchAgents/$label.plist"
        launchctl bootout "gui/$uid/$label" 2>/dev/null || true
        [[ -f $plist ]] && keep "$plist"
    done
    [[ -d "/Applications/Melody Engine Status.app" ]] && keep "/Applications/Melody Engine Status.app"
    pkill -TERM -x melodyd 2>/dev/null || true
    sleep 2
fi

# --- Install ------------------------------------------------------------------
for app in "${apps[@]}"; do
    installed="/Applications/$app.app"
    staged="/Applications/.$app-new.app"
    rm -rf "$staged"
    ditto "$mount/$app.app" "$staged"
    if [[ -d $installed ]]; then
        old="/Applications/.$app-old.app"
        rm -rf "$old"
        mv "$installed" "$old"
        mv "$staged" "$installed"
        rm -rf "$old"
    else
        mv "$staged" "$installed"
    fi
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$installed"
    say "installed $installed"
done

# Superseded by Settings › General › Interface size.
environment="$HOME/Library/LaunchAgents/org.melody.environment.plist"
if [[ -f $environment ]]; then
    launchctl bootout "gui/$uid/org.melody.environment" 2>/dev/null || true
    launchctl unsetenv QT_SCALE_FACTOR
    keep "$environment"
    say "Melody's size is now Settings › General › Interface size"
fi

if [[ $server == yes ]]; then
    "$engine_app/Contents/MacOS/melody-engine" --enable-engine | sed 's/^/  /'
    for _ in $(seq 30); do
        "$engine_app/Contents/MacOS/melody-engine" --check >/dev/null 2>&1 && break
        sleep 1
    done
    "$engine_app/Contents/MacOS/melody-engine" --check 2>&1 | sed 's/^/  /'
else
    "$engine_app/Contents/MacOS/melody-engine" --open-at-login | sed 's/^/  /'
    if [[ $melody_was_open == yes ]]; then
        open -a /Applications/Melody.app
        say "reopened Melody"
    fi
fi
sleep 2
pgrep -fl 'Melody Engine.app|Melody.app' | sed 's/^/  running: /' || true
INSTALLER

printf '==> %s: %s\n' "$target" "$(basename "$dmg")"
if [[ $target == local ]]; then
    copy="$(mktemp -d /tmp/melody-install.XXXXXX)/Melody.dmg"
    cp "$dmg" "$copy"
    bash -s -- "$copy" "$server" <<<"$installer"
else
    copy=/tmp/melody-install-$$.dmg
    scp -q "$dmg" "$target:$copy"
    ssh "$target" "bash -s -- $(printf '%q ' "$copy" "$server")" <<<"$installer"
fi
