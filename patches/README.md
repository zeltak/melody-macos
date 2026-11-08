# Patches

Fixes for the Mac that melody-music does not have (yet), applied in order by
`scripts/build-upstream.sh` after checking out the ref. A patch that no
longer applies stops the build: drop it if upstream took it, otherwise redo
it against the new source (`git -C work/src diff > patches/NNNN-name.patch`).

| Patch | Why |
|---|---|
| `0001-macos-keep-the-bundle-icon-in-the-dock.patch` | `QApplication::setWindowIcon` sets the Dock icon on macOS, so the running app showed the bare bird instead of the bundle's icon. |
