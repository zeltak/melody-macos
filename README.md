# melody-macos

Mac apps for [Melody](https://github.com/carnager/melody-next), built from
melody-next unchanged and delivered as one DMG:

| | **Melody.app** | **Melody Engine.app** |
|---|---|---|
| What it is | The music window | A menu-bar app carrying the engine |
| Inside | `melody`, `melodyd`, `melody-agent`, `melody-cli`, Qt and the media libraries | `melody-engine`, `melodyd`, `melody-agent`, `melody-cli`, the media libraries |
| For | Every Mac you listen on | The music server — and any Mac, for updates |

Both apps are self-contained: nothing from Homebrew is needed where they are
installed.

## Melody Engine

Its menu shows whether the engine answers, and offers:

- **Rescan Library** — the engine's own `catalogue.scan`, with progress.
- **Restart Engine** — `launchctl kickstart -k` of the engine's LaunchAgent.
- **Run Engine at Login** — writes `~/Library/LaunchAgents/org.melody.melodyd.plist`
  running `melodyd` from inside the app, with no options, so it uses the
  usual state (`~/Library/Application Support/melody/engine`), configuration
  (`~/.config/melody/melodyd.conf`) and socket. It turns on **Open at Login**
  too (`org.melody.engine-app`, restarted whenever it stops; **Quit**
  unloads it until the next login).
- **Install Command-Line Tool…** — links `/usr/local/bin/melody-cli` to the
  app's copy, asking for an administrator password.
- **Check for Updates… / Install Updates Automatically** — every six hours
  it reads the latest release of this repository. A newer build is
  downloaded, every app in its DMG checked to be signed by the same team,
  and the installed copies replaced: Melody Engine always, Melody.app where it
  is installed. Then the engine is restarted and the menu-bar app relaunched.

`melody-engine --enable-engine` does the same as Run Engine at Login from a
shell (over SSH, say); `--check` says whether the engine answers.

melodyd is signed with the fixed identifier `org.melody.melodyd` and the same
certificate every time, so macOS's permission to read the music folder
survives updates.

## Building a release

```sh
scripts/release.sh                 # build on 192.168.1.111, sign here, make dist/Melody-<BUILD>.dmg
scripts/release.sh --publish       # and attach it to a GitHub release build-<BUILD>
scripts/release.sh --build-host local --ref v0.3.0
```

1. **Build on the oldest macOS.** Homebrew's libraries only run on the macOS
   they were built for and later, so the build host is the Mac with the
   oldest macOS the apps must run on (the Mac mini, macOS 26).
   `build-upstream.sh` builds melody-next there (Release, no tests, macOS 26
   deployment target); `assemble.sh` makes both apps, bundles Qt with
   `macdeployqt` and every other library with `bundle-libs.py`, and checks
   that nothing points outside the bundle.
2. **Sign here.** `sign-app.sh` signs each library, framework and helper,
   then the app, with the first "Apple Development" identity in the keychain
   (`MELODY_CODESIGN_IDENTITY` to choose).
3. **Package.** One DMG with both apps, a link to Applications and a Read Me.

The build number is `<melody-next commits>.<melody-macos commits>`; the
version is melody-next's `git describe`.

Build host needs: Xcode, Homebrew with `qt`, `ffmpeg`, `taglib`, `libebur128`,
`libupnp`, `curl`, `openssl@3`, `pkgconf`, `cmake`, `ninja`.

## Releasing automatically

```sh
scripts/install-nightly.sh 04:30   # daily on this Mac; --remove to stop
```

`nightly.sh` publishes a release only when melody-next's `main` moved past
the commit the latest release was built from, or this repository changed. It
runs on the Mac that has the signing certificate and builds on the build
host over SSH. Every Melody Engine then updates within six hours.

## Installing on a new Mac

Open the DMG, drag the apps to Applications. They are signed with a
development certificate, not notarised: the first time, Control-click and
choose **Open**. Updates do not ask again. Apple silicon, macOS 26 or later.

## Tests

```sh
cd engine && swift test
```

## License

GPL-3.0-only, as melody-next. Each app carries the licences of everything
inside it in `Contents/Resources/licenses`.
