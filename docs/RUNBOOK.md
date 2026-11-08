# Runbook: building, releasing and installing Melody on the Macs

Everything here is run from this repository on **itai's Mac Studio**, the Mac
with the signing certificate. Last done 2026-11-08: build 1229.6 (Melody
0.3.0-299-g4de03b71) on all three Macs.

## The Macs

| Mac | SSH | macOS | Role | Installed |
|---|---|---|---|---|
| itai's Mac Studio | (this Mac) | 27.0 | builds, signs, publishes; listens | Melody, Melody Engine (opens at login), Qt at 2x |
| ikloog mini server | `macmini` (192.168.1.111) | 27.2 | **the music server**: engine "melody-mini" | Melody Engine, running melodyd at login |
| ikloog--mbair (MacBook Air) | `air` (192.168.1.85) | 27.0.1 | listens | Melody, Melody Engine (opens at login) |

`macmini` and `air` are in `~/.ssh/config`, with key login.

## What has to be in place

On the Mac Studio, once:

- **The signing identity**: "Apple Development: ikloog@bgu.ac.il (NSK9P259NH)",
  team F6Q8RLQ943, in the login keychain. `security find-identity -v -p codesigning`
  lists it. Its private key cannot be exported, which is why signing happens
  here.
- **Homebrew** with `qt ffmpeg taglib libebur128 libupnp curl openssl@3 pkgconf
  cmake ninja`.
- **Xcode** (for `swift test`: the Command Line Tools have no XCTest) and the
  Command Line Tools.
- **`gh`** logged in to the zeltak account (`gh auth status`).

The Mac that builds sets the oldest macOS the apps run on: Homebrew's
libraries need the macOS they were built for. All three Macs are on macOS 27,
so the Mac Studio builds and the apps need macOS 27. A Mac on an older macOS
would need its own build host on that version
(`scripts/release.sh --build-host HOST`), and the updater refuses a build
that needs a newer macOS than the Mac runs.

## 1. Check what will be built

Melody's source is **https://github.com/carnager/melody-music**, branch
`main` (the repository used to be called melody-next; there is no `master`).

```sh
git ls-remote https://github.com/carnager/melody-music.git refs/heads/main
gh release view -R zeltak/melody-macos      # what was released last
```

## 2. Build and sign the DMG

```sh
cd ~/dev/melody-macos
git status                                  # commit first: the build number counts commits
scripts/release.sh                          # about 10 minutes from clean
```

This:

1. clones or updates melody-music into `work/src`, at `main`;
2. builds `melody`, `melodyd`, `melody-agent`, `melody-cli` (Release, no tests,
   for this Mac's macOS) in `work/build`;
3. builds `melody-engine`, the menu-bar app (`engine/`);
4. assembles `work/apps/Melody.app` and `work/apps/Melody Engine.app`:
   - Qt via `macdeployqt`;
   - every other Homebrew library via `scripts/bundle-libs.py`;
   - the official plugins in `Contents/share/melody/plugins`;
5. checks that nothing points outside the bundles;
6. signs every library, helper and app with the certificate;
7. writes `dist/Melody-<BUILD>.dmg` and its `.sha256`.

The last line says what came out, e.g.
`dist/Melody-1229.6.dmg (63M), Melody 0.3.0-299-g4de03b71, build 1229.6, macOS 27.0 or later`.

`BUILD` is `<melody-music commits>.<melody-macos commits>`; it only grows.
The full log of a run is in `work-build.log` when run as
`scripts/release.sh >work-build.log 2>&1`.

To build another branch or fork: `scripts/release.sh --repo URL --ref BRANCH`.

### Check it before installing

```sh
cd work/apps
codesign --verify --deep --strict Melody.app "Melody Engine.app"
python3 -I ../../scripts/bundle-libs.py --check Melody.app
python3 -I ../../scripts/bundle-libs.py --check "Melody Engine.app"
(cd ../../engine && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test)
```

## 3. Install on the Macs

Server first, as the other two connect to it:

```sh
scripts/install-mac.sh --server  macmini dist/Melody-1229.6.dmg
scripts/install-mac.sh --qt-scale 2 local dist/Melody-1229.6.dmg   # this Mac Studio
scripts/install-mac.sh           air     dist/Melody-1229.6.dmg
```

`install-mac.sh` copies the DMG over, checks the signatures and the macOS
version, quits the Melody apps, installs into `/Applications` and starts
Melody Engine. `scripts/install-mac.sh --help` has the details.

- **`--server`** installs only Melody Engine and runs
  `melody-engine --enable-engine`. That writes the LaunchAgent
  `org.melody.melodyd`, running the app's melodyd with no options, so it
  keeps the same:
  - library (`~/Library/Application Support/melody/engine`);
  - settings (`~/.config/melody/melodyd.conf`: name melody-mini, password
    file, music root, UPnP);
  - socket.

  Also the LaunchAgent `org.melody.engine-app`: the menu-bar app, restarted
  if it stops. Log: `~/Library/Logs/Melody/melodyd.log`.
- **Otherwise** (listening Macs) both apps are installed and Melody Engine
  opens at login (`melody-engine --open-at-login`), only to keep both apps
  up to date. Melody starts its own melodyd when it needs one.
- **`--qt-scale 2`** is for the Mac Studio's 7680x2160 display, used at 1x. It
  is the LaunchAgent `org.melody.environment`, running
  `launchctl setenv QT_SCALE_FACTOR 2` at login.

Nothing is deleted. What the old setup used is moved to
`~/Library/Application Support/melody/install-backups/<time>/`:

- the old launcher `~/Applications/Melody.app`;
- old copies of the official plugins in
  `~/Library/Application Support/melody/plugins`, which would otherwise hide
  the newer ones inside the app;
- on the server, the LaunchAgents `com.zeltak.melodyd` and `org.melody.status`,
  and `/Applications/Melody Engine Status.app`.

Your own plugins there (library-export) are left alone.

### First time on a Mac

- **Local Network.** The first time Melody opens, macOS asks whether it may
  use the local network. Allow it. If the Library panel then says "the engine
  at 192.168.1.111:6603 is unreachable", quit and reopen Melody: its first
  connection was made before the answer.
- **Music folder.** The server's melodyd reads `/Volumes/media/imusic`. On
  2026-11-08 it could without asking. If macOS asks, it does so on the Mac
  mini's screen (Screen Sharing), and only once: melodyd is always signed
  with the same certificate and the identifier `org.melody.melodyd`.
- **Gatekeeper.** A DMG copied with `install-mac.sh` is not quarantined, so
  nothing asks. A DMG downloaded in a browser is quarantined: Control-click
  each app, then choose **Open** the first time.

### Check each Mac

```sh
ssh macmini '"/Applications/Melody Engine.app/Contents/MacOS/melody-engine" --check'
#   melodyd is running — melody-mini (...)
ssh macmini 'lsof -nP -iTCP -sTCP:LISTEN | grep melodyd'      # 6603 and 6604
ssh macmini 'tail ~/Library/Logs/Melody/melodyd.log'
ssh macmini '"/Applications/Melody Engine.app/Contents/MacOS/melody-cli" --local latest 3'
```

In Melody on a listening Mac, the bottom of the Library panel reads
"Library: melody-mini".

## 4. Publish, so the installed Macs follow

```sh
scripts/release.sh --publish        # build, sign and publish in one go
# or, for a DMG already built and installed:
gh release create build-1229.6 dist/Melody-1229.6.dmg dist/Melody-1229.6.dmg.sha256 \
    -R zeltak/melody-macos --title "Melody <VERSION> (build 1229.6)" --notes "..."
```

Each Mac's Melody Engine:

- checks `https://api.github.com/repos/zeltak/melody-macos/releases/latest`
  30 seconds after it starts, then every six hours;
- skips the check while a scan runs;
- for a newer build, downloads its DMG, checks that both apps are signed by
  team F6Q8RLQ943 and that the Mac's macOS is new enough, then:
  - replaces `/Applications/Melody Engine.app`, and `Melody.app` where it is
    installed;
  - restarts the engine's LaunchAgent and the menu-bar app.

An open Melody window keeps running the old version until it is reopened.

To make a Mac update now:

```sh
ssh air '"/Applications/Melody Engine.app/Contents/MacOS/melody-engine" --update'
#   Build 1229.6 is the latest
```

## 5. Releasing automatically

```sh
scripts/install-nightly.sh 04:30     # installed on the Mac Studio; --remove to stop
tail ~/Library/Logs/Melody/nightly.log
scripts/nightly.sh                   # the same check by hand; --force to release anyway
```

Every day at 04:30, or when the Mac Studio wakes after that time,
`nightly.sh` releases if:

- melody-music's `main` has moved past the commit of the latest release, or
- this repository has new commits.

Otherwise it does nothing. The release runs `release.sh --publish`. The Macs
update within six hours. `dist/` keeps the last five DMGs; GitHub keeps them
all.

## Going back

- **To an earlier build:** download its DMG from the releases page and run
  `install-mac.sh` with it. Turn off **Install Updates Automatically** in
  Melody Engine's menu first, or it updates again.
- **To the old setup on the server:**
  1. `launchctl bootout gui/$(id -u)/org.melody.melodyd`
  2. `launchctl bootout gui/$(id -u)/org.melody.engine-app`
  3. Move the two plists from `install-backups/<time>/` back to
     `~/Library/LaunchAgents/`.
  4. `launchctl bootstrap gui/$(id -u)` each of them.

  `~/melody/melodyd`, the previous binary, is still there.

## Troubleshooting

| Symptom | Cause, and what to do |
|---|---|
| `swift test`: "unable to resolve module dependency: 'XCTest'" | The Command Line Tools have no XCTest: prefix with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. |
| `release.sh`: "no signing identity" | The certificate is not in this Mac's keychain, or the keychain is locked (over SSH: `security unlock-keychain`). |
| `bundle-libs.py --check` lists a library | A new Homebrew dependency that cannot be found: `brew install` it, then run `release.sh` again. |
| A helper exits with 137 | A binary was changed after signing. `assemble.sh` signs ad hoc and `release.sh` signs for real: run them, do not edit `work/apps` by hand. |
| An updated Mac's menu says "the update needs macOS …" | The build was made on a newer macOS than that Mac runs. Update its macOS, or build on a Mac with the older one. |
| The Library panel says the server is unreachable | See [First time on a Mac](#first-time-on-a-mac). Otherwise check `ssh macmini … --check` and the log. |
