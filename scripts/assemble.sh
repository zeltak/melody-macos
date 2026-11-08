#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
#
# Makes work/apps/Melody.app and work/apps/Melody Engine.app from what
# build-upstream.sh built: each with melodyd, melody-agent and melody-cli
# beside its own program and every library it needs inside, Qt's for the
# window. Unsigned: sign.sh signs them where the certificate is.
#
#   scripts/assemble.sh [--update-repository OWNER/NAME]

set -euo pipefail

update_repository=${MELODY_UPDATE_REPOSITORY:-zeltak/melody-macos}
while (($# > 0)); do
    case $1 in
    --update-repository) update_repository=$2; shift 2 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work="$root/work"
build="$work/build"
source="$work/src"
apps="$work/apps"
# shellcheck source=/dev/null
source "$work/version.env"

if [[ -z ${DEVELOPER_DIR:-} && -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

rm -rf "$apps"
mkdir -p "$apps"

info_plist() {
    sed -e "s|@VERSION@|$VERSION|" -e "s|@BUILD@|$BUILD|" -e "s|@COMMIT@|$COMMIT|" \
        -e "s|@REPO@|$REPO|" -e "s|@UPDATE_REPOSITORY@|$update_repository|" "$1" >"$2"
    plutil -lint "$2" >/dev/null
}

helpers() {
    local macos=$1
    cp "$build/src/daemon/melodyd" "$build/src/agent/melody-agent" "$build/src/cli/melody-cli" "$macos/"
}

licenses() {
    local resources=$1
    mkdir -p "$resources/licenses"
    cp "$source/LICENSE" "$source/THIRD_PARTY.md" "$resources/licenses/"
    if [[ -d $source/packaging/licenses ]]; then
        cp -R "$source/packaging/licenses/." "$resources/licenses/"
    fi
}

# --- Melody.app: the window ---------------------------------------------------
melody="$apps/Melody.app"
mkdir -p "$melody/Contents/MacOS" "$melody/Contents/Resources"
cp "$build/src/bench/melody" "$melody/Contents/MacOS/melody"
helpers "$melody/Contents/MacOS"
info_plist "$root/resources/melody-Info.plist" "$melody/Contents/Info.plist"
"$root/scripts/make-icns.sh" "$melody/Contents/Resources/AppIcon.icns"
licenses "$melody/Contents/Resources"
macdeployqt "$melody" \
    -executable="$melody/Contents/MacOS/melodyd" \
    -executable="$melody/Contents/MacOS/melody-agent" \
    -executable="$melody/Contents/MacOS/melody-cli" \
    -always-overwrite -verbose=1 || true
# Plugins Melody never loads, whose frameworks Homebrew's Qt does not carry:
# PDF images and the on-screen keyboard.
rm -rf "$melody/Contents/PlugIns/platforminputcontexts" \
    "$melody/Contents/PlugIns/imageformats/libqpdf.dylib"
# What macdeployqt left pointing outside: copied in as well.
python3 -I "$root/scripts/bundle-libs.py" "$melody"

# --- Melody Engine.app: the menu-bar app and the engine ----------------------
(cd "$root/engine" && swift build -c release --product MelodyEngine)
engine_binary="$(cd "$root/engine" && swift build -c release --show-bin-path)/MelodyEngine"
engine="$apps/Melody Engine.app"
mkdir -p "$engine/Contents/MacOS" "$engine/Contents/Resources"
cp "$engine_binary" "$engine/Contents/MacOS/melody-engine"
helpers "$engine/Contents/MacOS"
info_plist "$root/resources/engine-Info.plist" "$engine/Contents/Info.plist"
cp "$root/icons/melody-symbolic.svg" "$engine/Contents/Resources/"
"$root/scripts/make-icns.sh" "$engine/Contents/Resources/AppIcon.icns" light
licenses "$engine/Contents/Resources"
python3 -I "$root/scripts/bundle-libs.py" "$engine"

# --- Checks --------------------------------------------------------------------
newest=0
for app in "$melody" "$engine"; do
    python3 -I "$root/scripts/bundle-libs.py" "$app" --check
    # Rewritten libraries no longer match their signatures, and Apple
    # silicon runs nothing unsigned: ad hoc until sign.sh signs for real.
    "$root/scripts/sign-app.sh" "$app" -
    while IFS= read -r -d '' file; do
        if file -b "$file" | grep -q Mach-O; then
            minos=$(vtool -show-build "$file" 2>/dev/null | awk '/minos/ { print $2; exit }')
            if [[ -n $minos ]] && awk -v a="$minos" -v b="$newest" 'BEGIN { exit !(a > b) }'; then
                newest=$minos
            fi
        fi
    done < <(find "$app/Contents" -type f -print0)
done
"$engine/Contents/MacOS/melodyd" --help >/dev/null
"$engine/Contents/MacOS/melody-cli" --help >/dev/null 2>&1 || true

printf '%s\n' "$newest" >"$apps/minimum-macos"
printf 'Assembled Melody %s (build %s) in %s; needs macOS %s\n' "$VERSION" "$BUILD" "$apps" "$newest"
du -sh "$melody" "$engine"
