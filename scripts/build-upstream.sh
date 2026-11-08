#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
#
# Fetches melody-next at a ref and builds what the Mac apps carry: the Melody
# window, melodyd, melody-agent and melody-cli -- optimised, without tests,
# for macOS 26 and later (Homebrew's libraries need 26 themselves).
#
#   scripts/build-upstream.sh [--repo URL] [--ref REF]
#
# Leaves the source in work/src, the build in work/build and writes
# work/version.env: VERSION, BUILD and COMMIT.

set -euo pipefail

repo=${MELODY_REPO:-https://github.com/carnager/melody-next.git}
ref=${MELODY_REF:-main}
jobs=${MELODY_BUILD_JOBS:-$(sysctl -n hw.ncpu)}

while (($# > 0)); do
    case $1 in
    --repo) repo=$2; shift 2 ;;
    --ref) ref=$2; shift 2 ;;
    -h|--help) sed -n '4,12p' "$0"; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work="$root/work"
source="$work/src"
build="$work/build"
mkdir -p "$work"

if [[ ! -d $source/.git ]]; then
    git clone --quiet "$repo" "$source"
fi
git -C "$source" remote set-url origin "$repo"
git -C "$source" fetch --quiet --tags --force origin "$ref"
git -C "$source" checkout --quiet --detach FETCH_HEAD
git -C "$source" clean -fdxq -e build

commit=$(git -C "$source" rev-parse HEAD)
# Tagged: that version; otherwise the last tag, the commits since and the
# commit (0.3.0-12-gabc1234). The build number only ever grows.
version=$(git -C "$source" describe --tags --always | sed 's/^v//')
count=$(git -C "$source" rev-list --count HEAD)
packaging=${MELODY_PACKAGING_BUILD:-$(git -C "$root" rev-list --count HEAD 2>/dev/null || echo 0)}
build_number="$count.$packaging"

homebrew=$(brew --prefix)
export CMAKE_PREFIX_PATH="$(brew --prefix qt)${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
export PKG_CONFIG_PATH="$homebrew/lib/pkgconfig:$homebrew/share/pkgconfig:$(brew --prefix openssl@3)/lib/pkgconfig:$(brew --prefix curl)/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

cmake --preset macos -S "$source" -B "$build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_TESTING=OFF \
    -DMELODY_WARNINGS_AS_ERRORS=OFF \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
    -DPKG_CONFIG_EXECUTABLE="$homebrew/bin/pkg-config"
cmake --build "$build" --parallel "$jobs" \
    --target trackknife trackknife_engine_daemon melody_agent melody_cli

cat >"$work/version.env" <<EOF
VERSION=$version
BUILD=$build_number
COMMIT=$commit
REPO=$repo
EOF
printf 'Built melody-next %s (%s, build %s)\n' "$version" "$commit" "$build_number"
