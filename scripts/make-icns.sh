#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
#
# make-icns.sh OUT.icns [light] -- the app icon at every size macOS asks for.

set -euo pipefail
out=$1
light=${2:-}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
xcrun swiftc -O "$root/icons/make-icon.swift" -o "$work/make-icon"
mkdir "$work/icon.iconset"
for size in 16 32 128 256 512; do
    "$work/make-icon" "$root/icons/melody.svg" "$work/icon.iconset/icon_${size}x${size}.png" "$size" "$light"
    "$work/make-icon" "$root/icons/melody.svg" "$work/icon.iconset/icon_${size}x${size}@2x.png" \
        $((size * 2)) "$light"
done
iconutil --convert icns --output "$out" "$work/icon.iconset"
