# Patches

Fixes for the Mac that melody-music does not have (yet), applied in order by
`scripts/build-upstream.sh` after checking out the ref. A patch that no
longer applies stops the build: drop it if upstream took it, otherwise redo
it against the new source (`git -C work/src diff > patches/NNNN-name.patch`).

| Patch | Why |
|---|---|
| `0001-macos-keep-the-bundle-icon-in-the-dock.patch` | `QApplication::setWindowIcon` sets the Dock icon on macOS, so the running app showed the bare bird instead of the bundle's icon. Upstream: carnager/melody-music#3. |
| `0002-library-panel-reconnects-by-itself.patch` | The library panel tried its engine once at startup and then only "on the next library action": a server not reachable at that moment (network not up yet after login or wake, engine restarting for an update) left "Library unavailable … unreachable" until Refresh, which rescans. Now it tries again after 1, 2, 4, 8, 16 s and every 30 s, reloading without a scan, and the connect failure says why (`could not reach the engine (No route to host)`). An engine that refused (password, or another protocol: ADR-0260) is not retried. Tests: `anEngineThatComesUpLaterIsReachedWithoutRefresh`, `anEngineThatRefusesIsNotAskedAgainAndAgain`. Upstream: carnager/melody-music#4. |
| `0003-interface-size-read-at-start.patch` | Settings › General › Interface size was saved under melody/melody but read at startup, before the app is named, under the old trackknife/trackknife: Melody always started at 100%. Seen on the Mac Studio: 200% saved, window 1100×736 before, 2200×1472 after. |

Upstream's `library_panel_engine_test` has three failures on macOS with or
without these patches (`theEngineReadsCoversWhereTheFilesAre`,
`aChangeSaysWhichAlbumsItTouched`, `theTreeFollowsAChangeInPlace`), and its
Unix-socket tests need a short `TMPDIR` (`TMPDIR=/tmp/t`): macOS socket paths
are limited to 104 bytes.
