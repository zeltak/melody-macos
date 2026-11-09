# Patches

Fixes for the Mac that melody-music does not have (yet), applied in order by
`scripts/build-upstream.sh` after checking out the ref. A patch that no
longer applies stops the build: drop it if upstream took it, otherwise redo
it against the new source (`git -C work/src diff > patches/NNNN-name.patch`).

| Patch | Why |
|---|---|
| `0001-macos-keep-the-bundle-icon-in-the-dock.patch` | `QApplication::setWindowIcon` sets the Dock icon on macOS, so the running app showed the bare bird instead of the bundle's icon. Upstream declined it as is (carnager/melody-music#3): the repository has no app bundle, and unbundled Melody would lose its Dock icon. They would take one that skips the call only when running from a bundle with its own icon, in `pick_main.cpp` too. |
| `0002-locate-the-file-plugin.patch` | A new official plugin, **Locate the file**: the playing track's file (Workspace › Run › Locate the playing file, also in the command palette) or the tracks chosen (context menu) in Finder, Tandem or a command of your own, with a mapping for an engine's music folder mounted elsewhere. Melody told hand-run plugin commands nothing about what plays, so the patch adds `playing` to their input (ADR-0295 amendment). Tests: `triggersAreReadAndTold`, `theLocatePluginShowsTheFile`, `pluginTriggersRunOnTheLibrarysNews`. |
| `0003-rescan-beside-a-writer.patch` | A full rescan on the server failed every time with "database is locked" and stored nothing while music played: the scan left two read statements on their rows, so its next write came from an old snapshot, and once playback had saved its position meanwhile SQLite refused at once, without waiting. Reproduced on a copy of the server's library with a second writer; the test `aRescanIsNotRefusedByAnotherWriter` fails without the fix every time. Upstream: (PR to come). |
| `0004-side-panel-tab-order.patch` | The side panels' tabs (Lyrics, About, Library export…) could be dragged into another order, but went back to the order they were made in at every start, and whichever was tabbed last came to the front. The order dragged to and the tab in front are now kept, and Settings › General › Panel in front can name one to always be in front. Tested by `sidePanelTabsKeepTheirOrderAndFront`; the rest of `bench-main-window` fails the same tests with and without it on macOS. Upstream: (PR to come). |
| `0005-pause-on-close.patch` | Settings › Playback › **Pause the music when Melody closes** (off by default): closing or quitting Melody pauses what plays on every engine it is connected to, the server's included (ADR-0349). The engine otherwise plays on with every window closed, by design. Tested by `closingPausesWhatPlaysWhenAsked`, which fails without it. Upstream: (PR to come). |

Upstream took the others, as of fa12872d (2026-11-08): the library panel
reconnecting (#4, done their own way), Interface size (#5), the KEF resume
(#6) and the restart position (#7).

Upstream's `library_panel_engine_test` has three failures on macOS with or
without these patches (`theEngineReadsCoversWhereTheFilesAre`,
`aChangeSaysWhichAlbumsItTouched`, `theTreeFollowsAChangeInPlace`), and its
Unix-socket tests need a short `TMPDIR` (`TMPDIR=/tmp/t`): macOS socket paths
are limited to 104 bytes.

Also failing on macOS 27 with or without these patches:
`plugins`' `theExamplePluginReads`, `bench-main-window`'s
`aPluginPanelIsToldTheLibrary`, and 22 of `local-library`'s tests.
