#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
#
# Publishes a release when there is something new: melody-next's main moved
# past the commit the latest release was built from, or melody-macos itself
# changed. Otherwise does nothing. Run daily by the LaunchAgent that
# scripts/install-nightly.sh installs.
#
#   scripts/nightly.sh [--force]

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
repo=${MELODY_REPO:-https://github.com/carnager/melody-next.git}
ref=${MELODY_REF:-main}
update_repository=${MELODY_UPDATE_REPOSITORY:-zeltak/melody-macos}
force=false
[[ ${1:-} == --force ]] && force=true

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
printf '\n== %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"

upstream=$(git ls-remote "$repo" "refs/heads/$ref" | cut -c1-12)
[[ -n $upstream ]] || { printf 'cannot read %s %s\n' "$repo" "$ref" >&2; exit 1; }
packaging=$(git rev-list --count HEAD)

latest=$(gh release view -R "$update_repository" --json tagName,body \
    --jq '.tagName + " " + .body' 2>/dev/null || true)
released_packaging=$(sed -nE 's/^build-[0-9]+\.([0-9]+) .*/\1/p' <<<"$latest")

if [[ $force == false && $latest == *"$upstream"* && $released_packaging == "$packaging" ]]; then
    printf 'Nothing new: melody-next %s, melody-macos %s, already released (%s)\n' \
        "$upstream" "$packaging" "${latest%% *}"
    exit 0
fi

printf 'Releasing melody-next %s with melody-macos %s (latest: %s)\n' \
    "$upstream" "$packaging" "${latest%% *}"
scripts/release.sh --repo "$repo" --ref "$ref" --publish
# Old DMGs: the last five are kept here; GitHub keeps every release.
ls -1t dist/Melody-*.dmg 2>/dev/null | tail -n +6 | while read -r old; do
    rm -f "$old" "$old.sha256"
done
