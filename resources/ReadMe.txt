Melody @VERSION@ (build @BUILD@)
melody-music @COMMIT@
macOS @MINIMUM@ or later, Apple silicon

Two apps -- drag the ones this Mac needs to Applications:

  Melody         The music window. It starts its own engine when no other is
                 running, and plays through engines elsewhere too.

  Melody Engine  The engine in the menu bar: shows whether melodyd answers,
                 rescans the library, and keeps both apps up to date.
                 On a music server, choose "Run Engine at Login" in its menu:
                 melodyd then runs from this app at every login, and the menu
                 bar app with it. "Install Command-Line Tool..." links
                 melody-cli into /usr/local/bin.

Updates: Melody Engine checks GitHub every six hours and, unless "Install
Updates Automatically" is off, replaces itself and Melody.app (where it is
installed) with the new build and restarts the engine.

First opening: these apps are signed with a development certificate, not
notarised. If macOS says it cannot check them, Control-click the app, choose
Open, then Open again. Once is enough; updates do not ask again.

The first time melodyd reads the music folder, macOS asks for permission.
It is kept across updates.

Source: https://github.com/carnager/melody-music (GPL-3.0-only); the licences
of everything inside are in each app's Contents/Resources/licenses.
