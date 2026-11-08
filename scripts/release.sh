#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
#
# A release, start to end:
#
#   1. on the build Mac -- the one with the oldest macOS the apps should run
#      on, as Homebrew's libraries only run on the macOS they were built for
#      and later -- build melody-next and assemble both apps;
#   2. here, where the signing certificate is, sign them;
#   3. make dist/Melody-<BUILD>.dmg, and with --publish attach it to a GitHub
#      release build-<BUILD>, which the menu-bar app updates from.
#
#   scripts/release.sh [--build-host HOST|local] [--ref REF] [--repo URL] [--publish]
#
# Environment: MELODY_CODESIGN_IDENTITY (default: the first "Apple
# Development" identity), MELODY_UPDATE_REPOSITORY (default
# zeltak/melody-macos).

set -euo pipefail

build_host=${MELODY_BUILD_HOST:-192.168.1.111}
ref=${MELODY_REF:-main}
repo=${MELODY_REPO:-https://github.com/carnager/melody-next.git}
update_repository=${MELODY_UPDATE_REPOSITORY:-zeltak/melody-macos}
publish=false

while (($# > 0)); do
    case $1 in
    --build-host) build_host=$2; shift 2 ;;
    --ref) ref=$2; shift 2 ;;
    --repo) repo=$2; shift 2 ;;
    --publish) publish=true; shift ;;
    -h|--help) sed -n '4,19p' "$0"; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
packaging_build=$(git rev-list --count HEAD)
if [[ -n $(git status --porcelain) ]]; then
    printf '%s\n' 'note: melody-macos has uncommitted changes; they are built, but the build number does not count them' >&2
fi

if [[ -n ${MELODY_CODESIGN_IDENTITY+set} ]]; then
    identity=$MELODY_CODESIGN_IDENTITY
else
    identity=$(security find-identity -v -p codesigning 2>/dev/null |
        awk '/"Apple Development:/ && !found { print $2; found = 1 }')
fi
[[ -n $identity ]] || { printf '%s\n' 'no signing identity: set MELODY_CODESIGN_IDENTITY' >&2; exit 1; }

# --- 1. Build and assemble -----------------------------------------------------
build_env=(MELODY_REPO="$repo" MELODY_REF="$ref" MELODY_PACKAGING_BUILD="$packaging_build"
    MELODY_UPDATE_REPOSITORY="$update_repository")
if [[ $build_host == local ]]; then
    env "${build_env[@]}" scripts/build-upstream.sh
    env "${build_env[@]}" scripts/assemble.sh
else
    remote_dir=dev/melody-macos-build
    printf '==> Building on %s\n' "$build_host"
    ssh "$build_host" "mkdir -p $remote_dir"
    rsync -a --delete --exclude work/ --exclude dist/ --exclude .build/ --exclude work-build.log \
        "$root/" "$build_host:$remote_dir/"
    ssh "$build_host" "export PATH=/opt/homebrew/bin:\$PATH; cd $remote_dir && \
        env $(printf '%q ' "${build_env[@]}") scripts/build-upstream.sh && \
        env $(printf '%q ' "${build_env[@]}") scripts/assemble.sh"
    rm -rf work/apps
    mkdir -p work
    ssh "$build_host" "cd $remote_dir/work && rm -f apps.zip && /usr/bin/ditto -c -k --keepParent apps apps.zip"
    scp -q "$build_host:$remote_dir/work/apps.zip" "$build_host:$remote_dir/work/version.env" work/
    ditto -x -k work/apps.zip work
    rm work/apps.zip
fi
# shellcheck source=/dev/null
source work/version.env
minimum=$(cat work/apps/minimum-macos)

# --- 2. Sign ---------------------------------------------------------------------
for app in "work/apps/Melody.app" "work/apps/Melody Engine.app"; do
    /usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $minimum" "$app/Contents/Info.plist"
    scripts/sign-app.sh "$app" "$identity"
done
printf '==> Signed with %s\n' "$identity"

# --- 3. The DMG ----------------------------------------------------------------
mkdir -p dist
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
ditto "work/apps/Melody.app" "$staging/Melody.app"
ditto "work/apps/Melody Engine.app" "$staging/Melody Engine.app"
ln -s /Applications "$staging/Applications"
sed -e "s|@VERSION@|$VERSION|g" -e "s|@BUILD@|$BUILD|g" -e "s|@COMMIT@|$COMMIT|g" \
    -e "s|@MINIMUM@|$minimum|g" resources/ReadMe.txt >"$staging/Read Me.txt"
dmg="dist/Melody-$BUILD.dmg"
rm -f "$dmg"
hdiutil create -quiet -volname "Melody $BUILD" -srcfolder "$staging" -fs APFS -format ULMO "$dmg"
codesign --force --sign "$identity" --timestamp=none "$dmg"
(cd dist && shasum -a 256 "$(basename "$dmg")" >"$(basename "$dmg").sha256")
printf '==> %s (%s), Melody %s, build %s, macOS %s or later\n' \
    "$dmg" "$(du -h "$dmg" | cut -f1)" "$VERSION" "$BUILD" "$minimum"

# --- 4. Publish ------------------------------------------------------------------
if [[ $publish == true ]]; then
    notes=$(printf 'Melody %s from melody-next %s.\n\nBoth apps in one DMG: drag Melody and/or Melody Engine to Applications. Melody Engine updates both itself.\n\nmacOS %s or later, Apple silicon.' \
        "$VERSION" "${COMMIT:0:12}" "$minimum")
    gh release create "build-$BUILD" "$dmg" "$dmg.sha256" -R "$update_repository" \
        --title "Melody $VERSION (build $BUILD)" --notes "$notes"
fi
