# Patches

Fixes for the Mac that melody-music does not have (yet), applied in order by
`scripts/build-upstream.sh` after checking out the ref. A patch that no
longer applies stops the build: drop it if upstream took it, otherwise redo
it against the new source (`git -C work/src diff > patches/NNNN-name.patch`).

| Patch | Why |
|---|---|
| `0001-macos-keep-the-bundle-icon-in-the-dock.patch` | `QApplication::setWindowIcon` sets the Dock icon on macOS, so the running app showed the bare bird instead of the bundle's icon. |
| `0002-library-panel-reconnects-by-itself.patch` | The library panel tried its engine once at startup and then only "on the next library action": a server not reachable at that moment (network not up yet after login or wake, engine restarting for an update) left "Library unavailable … unreachable" until Refresh, which rescans. Now it tries again after 1, 2, 4, 8, 16 s and every 30 s, reloading without a scan, and the connect failure says why (`could not reach the engine (No route to host)`). Test: `anEngineThatComesUpLaterIsReachedWithoutRefresh`. |

Upstream's `library_panel_engine_test` has three failures on macOS with or
without these patches (`theEngineReadsCoversWhereTheFilesAre`,
`aChangeSaysWhichAlbumsItTouched`, `theTreeFollowsAChangeInPlace`), and its
Unix-socket tests need a short `TMPDIR` (`TMPDIR=/tmp/t`): macOS socket paths
are limited to 104 bytes.
