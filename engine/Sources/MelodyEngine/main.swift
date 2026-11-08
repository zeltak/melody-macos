// SPDX-License-Identifier: GPL-3.0-only
//
// Melody Engine: the menu-bar app that carries melodyd. It shows whether the
// engine answers, runs it at login from inside this bundle, rescans its
// library, restarts it, installs melody-cli and keeps itself and Melody.app
// up to date from GitHub. melodyd knows nothing of it: it is a client like
// any other, and quitting it leaves the engine running.

import AppKit
import CryptoKit
import MelodyEngineCore

struct Options {
    var socket = Engine.defaultSocketPath()
    var check = false
    var enableEngine = false
    var update = false
}

func usage() -> String {
    """
    Usage: melody-engine [--socket PATH] [--check] [--enable-engine] [--update]

      --socket PATH    melodyd's socket (default \(Engine.defaultSocketPath()))
      --check          say whether melodyd answers, and exit
      --enable-engine  run this bundle's melodyd at login, open this app at
                       login, and exit
      --update         install the latest release if it is newer, and exit
      -h, --help       show this help

    """
}

func parseOptions(_ arguments: [String]) -> Options {
    var options = Options()
    var index = 1
    while index < arguments.count {
        switch arguments[index] {
        case "--socket":
            index += 1
            guard index < arguments.count else {
                FileHandle.standardError.write(Data("melody-engine: --socket needs a value\n".utf8))
                exit(2)
            }
            options.socket = arguments[index]
        case "--check": options.check = true
        case "--enable-engine": options.enableEngine = true
        case "--update": options.update = true
        case "-h", "--help":
            print(usage(), terminator: "")
            exit(0)
        case let argument where argument.hasPrefix("-psn_"): break
        // What Xcode and the Finder may pass; not ours.
        case let argument where argument.hasPrefix("-NS") || argument.hasPrefix("-Apple"):
            index += 1
        case let argument:
            FileHandle.standardError.write(Data("melody-engine: unknown option \(argument)\n\(usage())".utf8))
            exit(2)
        }
        index += 1
    }
    return options
}

/// One menu-bar app per engine socket: a second start leaves.
func holdSingleInstanceLock(socket: String) -> Bool {
    let key = SHA256.hash(data: Data(socket.utf8)).map { String(format: "%02x", $0) }.joined()
    let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("melody-engine-\(key).lock")
    let descriptor = open(path, O_CREAT | O_RDWR, 0o600)
    return descriptor >= 0 && flock(descriptor, LOCK_EX | LOCK_NB) == 0
}

enum Paths {
    static let contents = (Bundle.main.bundlePath as NSString).appendingPathComponent("Contents/MacOS")
    static let melodyd = (contents as NSString).appendingPathComponent("melodyd")
    static let cli = (contents as NSString).appendingPathComponent("melody-cli")
    static let app = (contents as NSString).appendingPathComponent("melody-engine")
    static var bundled: Bool { FileManager.default.isExecutableFile(atPath: melodyd) }
}

func enableEngine() throws {
    try System.installAgent(LaunchAgents.engineDefinition(executable: Paths.melodyd, logs: System.logs))
    try System.installAgent(LaunchAgents.appDefinition(executable: Paths.app, logs: System.logs))
}

final class Controller: NSObject, NSMenuDelegate {
    private let options: Options
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let statusLine = NSMenuItem(title: "Checking melodyd…", action: nil, keyEquivalent: "")
    private let scanItem = NSMenuItem(title: "Rescan Library", action: #selector(rescan), keyEquivalent: "")
    private let restartItem = NSMenuItem(title: "Restart Engine", action: #selector(restart), keyEquivalent: "")
    private let detailLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let engineAtLogin = NSMenuItem(title: "Run Engine at Login", action: #selector(toggleEngine), keyEquivalent: "")
    private let appAtLogin = NSMenuItem(title: "Open at Login", action: #selector(toggleApp), keyEquivalent: "")
    private let toolItem = NSMenuItem(title: "Install Command-Line Tool…", action: #selector(installTool), keyEquivalent: "")
    private let updateLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
    private let autoUpdateItem = NSMenuItem(title: "Install Updates Automatically", action: #selector(toggleAutoUpdate), keyEquivalent: "")
    private let queue = DispatchQueue(label: "org.melody.engine-app.engine", attributes: .concurrent)
    private let updater = Updater()
    private var timers: [Timer] = []
    private var probing = false
    private var running = false
    private var scanning = false
    private var restarting = false
    private let stopScan = Atomic(false)

    private var autoUpdate: Bool {
        get { UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoUpdate") }
    }

    init(options: Options) {
        self.options = options
        super.init()
        if let button = item.button {
            let image = Bundle.main.url(forResource: "melody-symbolic", withExtension: "svg")
                .flatMap { NSImage(contentsOf: $0) }
            image?.size = NSSize(width: 18, height: 18)
            image?.isTemplate = true
            button.image = image
            if image == nil { button.title = "♪" }
            button.appearsDisabled = true
        }
        for line in [statusLine, detailLine, updateLine] { line.isEnabled = false }
        detailLine.isHidden = true
        for entry in [scanItem, restartItem, engineAtLogin, appAtLogin, toolItem, updateItem, autoUpdateItem] {
            entry.target = self
        }
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(statusLine)
        menu.addItem(detailLine)
        menu.addItem(.separator())
        menu.addItem(scanItem)
        menu.addItem(restartItem)
        menu.addItem(.separator())
        menu.addItem(engineAtLogin)
        menu.addItem(appAtLogin)
        menu.addItem(toolItem)
        menu.addItem(.separator())
        menu.addItem(updateLine)
        menu.addItem(updateItem)
        menu.addItem(autoUpdateItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Melody Engine", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        quit.toolTip = "Leave melodyd running"
        menu.addItem(quit)
        item.menu = menu

        updater.changed = { [weak self] _ in self?.updateActions() }
        refreshSettings()
        refresh()
        timers.append(Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        })
        if updater.enabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.automaticCheck() }
            timers.append(Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
                self?.automaticCheck()
            })
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
        refreshSettings()
    }

    private func automaticCheck() {
        // Not while the library is being read: an update restarts the engine.
        guard !scanning else { return }
        updater.check(thenInstall: autoUpdate)
    }

    // MARK: State

    private func refresh() {
        guard !probing else { return }
        probing = true
        let socket = options.socket
        queue.async {
            let result = Result { try Engine.probe(socketPath: socket) }
            DispatchQueue.main.async { self.probed(result) }
        }
    }

    private func probed(_ result: Result<String, Error>) {
        probing = false
        switch result {
        case .success(let name):
            running = true
            statusLine.title = "Engine running — \(name)"
            statusLine.toolTip = nil
        case .failure(let error):
            running = false
            statusLine.title = "Engine not responding"
            statusLine.toolTip = String(describing: error)
        }
        item.button?.appearsDisabled = !running
        item.button?.toolTip = statusLine.title
        updateActions()
    }

    private func refreshSettings() {
        engineAtLogin.state = System.agentInstalled(LaunchAgents.engine) ? .on : .off
        appAtLogin.state = System.agentInstalled(LaunchAgents.app) ? .on : .off
        autoUpdateItem.state = autoUpdate ? .on : .off
        let linked = System.toolInstalled(pointingAt: Paths.cli)
        toolItem.title = linked ? "Command-Line Tool Installed" : "Install Command-Line Tool…"
        toolItem.toolTip = linked ? "\(System.toolLink) → this app's melody-cli" : "Link melody-cli into /usr/local/bin"
        updateActions()
    }

    private func updateActions() {
        let ownsEngine = System.agentInstalled(LaunchAgents.engine)
        scanItem.isEnabled = running && !scanning && !restarting
        scanItem.title = scanning ? "Rescanning Library…" : "Rescan Library"
        restartItem.isEnabled = ownsEngine && !scanning && !restarting
        restartItem.toolTip = ownsEngine ? "Restart melodyd; playback may briefly pause"
                                         : "Turn on Run Engine at Login to manage the engine here"
        engineAtLogin.isEnabled = Paths.bundled
        toolItem.isEnabled = Paths.bundled && !System.toolInstalled(pointingAt: Paths.cli)
        updateItem.isEnabled = updater.enabled
        autoUpdateItem.isEnabled = updater.enabled
        switch updater.state {
        case _ where !updater.enabled: updateLine.title = "Development build — no updates"
        case .idle: updateLine.title = "Build \(updater.currentBuild)"
        case .checking: updateLine.title = "Checking for updates…"
        case .current: updateLine.title = "Build \(updater.currentBuild) — up to date"
        case .available(let release): updateLine.title = "Build \(release.build) available"
        case .installing(let step): updateLine.title = step
        case .failed(let message): updateLine.title = message
        }
        if case .available = updater.state {
            updateItem.title = "Install Update"
        } else {
            updateItem.title = "Check for Updates…"
        }
        if case .installing = updater.state { updateItem.isEnabled = false }
    }

    private func show(_ detail: String) {
        detailLine.title = detail
        detailLine.isHidden = false
    }

    // MARK: Actions

    @objc private func rescan() {
        guard scanItem.isEnabled else { return }
        scanning = true
        show("Scanning…")
        updateActions()
        let socket = options.socket
        let stop = stopScan
        queue.async {
            let outcome = Result {
                try Engine.scan(socketPath: socket, progress: { counts in
                    DispatchQueue.main.async {
                        self.show("Scanning: \(counts.indexed) read, \(counts.visited) visited")
                    }
                }, shouldStop: { stop.value })
            }
            DispatchQueue.main.async { self.scanned(outcome) }
        }
    }

    private func scanned(_ outcome: Result<ScanOutcome, Error>) {
        scanning = false
        switch outcome {
        case .success(.complete(let counts)):
            show("Scan complete: \(counts.indexed) read, \(counts.visited) visited")
        case .success(.incomplete(let counts)):
            show("Scan incomplete (\(counts.indexed) read): unavailable folders or failed files")
        case .success(.failed(let message)):
            show("Scan failed: \(message)")
        case .success(.detached):
            break
        case .failure(let error):
            show("Scan failed: \(error)")
        }
        updateActions()
    }

    @objc private func restart() {
        guard restartItem.isEnabled else { return }
        restarting = true
        updateActions()
        queue.async {
            let result = System.restartAgent(LaunchAgents.engine)
            DispatchQueue.main.async {
                self.restarting = false
                self.show(result.status == 0 ? "Engine restarted" : "Restart failed: \(result.error)")
                self.refresh()
                self.updateActions()
            }
        }
    }

    @objc private func toggleEngine() {
        if engineAtLogin.state == .on {
            let alert = NSAlert()
            alert.messageText = "Stop running the engine here?"
            alert.informativeText = "melodyd stops now and no longer starts at login. Its library and settings are kept."
            alert.addButton(withTitle: "Stop Engine")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            System.removeAgent(LaunchAgents.engine)
            show("Engine stopped")
        } else {
            do {
                try System.installAgent(LaunchAgents.engineDefinition(executable: Paths.melodyd, logs: System.logs))
                show("Engine starting")
                // The engine is this app's to watch now: it opens at login too.
                if !System.agentInstalled(LaunchAgents.app) { toggleApp() }
            } catch {
                show("\(error)")
            }
        }
        refreshSettings()
        refresh()
    }

    @objc private func toggleApp() {
        if appAtLogin.state == .on {
            System.removeAgent(LaunchAgents.app)
            // Unloading the agent ended this process if launchd ran it.
        } else {
            do {
                try System.installAgent(LaunchAgents.appDefinition(executable: Paths.app, logs: System.logs))
                // launchd's copy takes over; this one, opened by hand, leaves.
                if ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] != LaunchAgents.app {
                    stopScan.value = true
                    NSApp.terminate(nil)
                }
            } catch {
                show("\(error)")
            }
        }
        refreshSettings()
    }

    @objc private func installTool() {
        do {
            try System.installTool(target: Paths.cli)
            show("melody-cli installed in /usr/local/bin")
        } catch {
            show("\(error)")
        }
        refreshSettings()
    }

    @objc private func checkForUpdates() {
        if case .available(let release) = updater.state {
            updater.install(release)
        } else {
            updater.check()
        }
    }

    @objc private func toggleAutoUpdate() {
        autoUpdate.toggle()
        refreshSettings()
    }

    @objc private func quit() {
        stopScan.value = true
        // Kept alive by its LaunchAgent: unloaded, or it would be back in
        // seconds. It returns at the next login.
        if ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == LaunchAgents.app {
            System.run("/bin/launchctl", ["bootout", "gui/\(System.uid)/\(LaunchAgents.app)"])
        }
        NSApp.terminate(nil)
    }
}

/// A flag read from the scan's thread and set from the main one.
final class Atomic<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

let options = parseOptions(CommandLine.arguments)
if options.check {
    do {
        print("melodyd is running — \(try Engine.probe(socketPath: options.socket)) (\(options.socket))")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(error) (\(options.socket))\n".utf8))
        exit(1)
    }
}
if options.enableEngine {
    do {
        try enableEngine()
        print("melodyd runs at login from \(Paths.melodyd); Melody Engine opens at login")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("melody-engine: \(error)\n".utf8))
        exit(1)
    }
}
if options.update {
    let updater = Updater()
    guard updater.enabled else {
        FileHandle.standardError.write(Data("melody-engine: a development build does not update\n".utf8))
        exit(1)
    }
    updater.relaunch = false
    updater.changed = { state in
        switch state {
        case .current:
            print("Build \(updater.currentBuild) is the latest")
            exit(0)
        case .installing(let step): print(step)
        case .failed(let message):
            FileHandle.standardError.write(Data("melody-engine: \(message)\n".utf8))
            exit(1)
        default: break
        }
    }
    updater.check(thenInstall: true)
    RunLoop.main.run()
}
guard holdSingleInstanceLock(socket: options.socket) else { exit(0) }
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller(options: options)
app.run()
