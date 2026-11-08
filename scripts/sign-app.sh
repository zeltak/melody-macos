#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
#
# sign-app.sh APP.app IDENTITY -- signs an app from the inside out: its
# libraries and plugins, its frameworks, the helper programs (each under a
# fixed identifier, so macOS's privacy permissions for melodyd survive
# updates), then the app. IDENTITY "-" signs ad hoc.

set -euo pipefail
app=$1
identity=$2
contents="$app/Contents"
sign() {
    local output
    if ! output=$(codesign --force --sign "$identity" --timestamp=none "$@" 2>&1); then
        printf '%s\n' "$output" >&2
        return 1
    fi
}

is_macho() { file -b "$1" | grep -q 'Mach-O'; }

# Loose libraries and plugins, and the code inside frameworks.
while IFS= read -r -d '' file; do
    if is_macho "$file"; then
        sign "$file"
    fi
done < <(find "$contents/Frameworks" "$contents/PlugIns" -type f -not -path '*.framework/*' -print0 2>/dev/null)
while IFS= read -r -d '' framework; do
    sign "$framework"
done < <(find "$contents/Frameworks" -maxdepth 1 -name '*.framework' -print0 2>/dev/null)

main=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$contents/Info.plist")
for helper in melodyd melody-agent melody-cli; do
    if [[ -f $contents/MacOS/$helper ]]; then
        sign --identifier "org.melody.$helper" "$contents/MacOS/$helper"
    fi
done
[[ -f $contents/MacOS/$main ]] || { printf 'no %s in %s\n' "$main" "$app" >&2; exit 1; }
sign "$app"
codesign --verify --deep --strict "$app"
