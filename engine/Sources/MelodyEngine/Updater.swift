// SPDX-License-Identifier: GPL-3.0-only
//
// Updates both apps from the latest GitHub release: downloads its DMG, checks
// that every app in it is signed by the same team as this one, and replaces
// the copies installed here -- this app always, Melody.app where it is
// installed. The engine is restarted on the new melodyd; this app is
// relaunched.

import AppKit
import MelodyEngineCore

final class Updater {
    enum State: Equatable {
        case idle
        case checking
        case current
        case available(Release)
        case installing(String)
        case failed(String)
    }

    private(set) var state: State = .idle { didSet { changed(state) } }
    var changed: (State) -> Void = { _ in }
    /// Whether to open the new copy when this one is opened by hand.
    var relaunch = true
    private let repository: String?
    private let current: BuildNumber?
    private let queue = DispatchQueue(label: "org.melody.engine-app.updates")

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        repository = (info["MelodyUpdateRepository"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        current = (info["CFBundleVersion"] as? String).flatMap(BuildNumber.init)
    }

    var enabled: Bool { repository != nil && current != nil }
    var currentBuild: String { current?.description ?? "development" }

    func check(thenInstall install: Bool = false) {
        guard let repository, let current, let url = Release.latestURL(repository: repository) else {
            return
        }
        if case .installing = state { return }
        state = .checking
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                guard let data, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    self.state = .failed("Could not check for updates: \(error?.localizedDescription ?? "no release found")")
                    return
                }
                guard let release = Release.parse(data) else {
                    self.state = .failed("The latest release has no Melody DMG")
                    return
                }
                if release.build > current {
                    self.state = .available(release)
                    if install { self.install(release) }
                } else {
                    self.state = .current
                }
            }
        }.resume()
    }

    func install(_ release: Release) {
        state = .installing("Downloading build \(release.build)…")
        URLSession.shared.downloadTask(with: release.dmg) { file, response, error in
            guard let file, (response as? HTTPURLResponse)?.statusCode == 200 else {
                DispatchQueue.main.async {
                    self.state = .failed("Download failed: \(error?.localizedDescription ?? "no file")")
                }
                return
            }
            let dmg = FileManager.default.temporaryDirectory.appendingPathComponent("melody-update-\(release.build).dmg")
            try? FileManager.default.removeItem(at: dmg)
            do {
                try FileManager.default.moveItem(at: file, to: dmg)
            } catch {
                DispatchQueue.main.async { self.state = .failed("Download failed: \(error)") }
                return
            }
            self.queue.async {
                let outcome = Result { try self.installApps(from: dmg) }
                try? FileManager.default.removeItem(at: dmg)
                DispatchQueue.main.async {
                    switch outcome {
                    case .success(let melodyUpdated):
                        self.finish(melodyUpdated: melodyUpdated)
                    case .failure(let error):
                        self.state = .failed("Update failed: \(error)")
                    }
                }
            }
        }.resume()
    }

    /// Replaces the installed apps with the DMG's; whether Melody.app was.
    private func installApps(from dmg: URL) throws -> Bool {
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("melody-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        let attached = System.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen",
                                                       "-mountpoint", mount.path, dmg.path])
        guard attached.status == 0 else { throw Failure("cannot open the DMG: \(attached.error)") }
        defer {
            System.run("/usr/bin/hdiutil", ["detach", "-force", mount.path])
            try? FileManager.default.removeItem(at: mount)
        }
        guard let ourTeam = System.team(of: Bundle.main.bundlePath) else {
            throw Failure("this app's own signature cannot be read")
        }
        let newEngineApp = mount.appendingPathComponent("Melody Engine.app")
        guard System.team(of: newEngineApp.path) == ourTeam else {
            throw Failure("Melody Engine.app in the update is not signed by the same team")
        }
        let newMelody = mount.appendingPathComponent("Melody.app")
        let installedMelody = ["/Applications/Melody.app",
                               (NSHomeDirectory() as NSString).appendingPathComponent("Applications/Melody.app")]
            .first { path in
                Bundle(path: path)?.bundleIdentifier == "org.melody.Melody"
            }
        if installedMelody != nil, System.team(of: newMelody.path) != ourTeam {
            throw Failure("Melody.app in the update is not signed by the same team")
        }
        try replace(Bundle.main.bundlePath, with: newEngineApp.path)
        if let installedMelody {
            try replace(installedMelody, with: newMelody.path)
        }
        return installedMelody != nil
    }

    /// Copies the new bundle beside the old, then swaps them, so a failure
    /// leaves the old one in place.
    private func replace(_ installed: String, with replacement: String) throws {
        let folder = (installed as NSString).deletingLastPathComponent
        let staged = (folder as NSString).appendingPathComponent(".melody-update-\(UUID().uuidString).app")
        let copied = System.run("/usr/bin/ditto", [replacement, staged])
        guard copied.status == 0 else { throw Failure("cannot copy into \(folder): \(copied.error)") }
        let old = (folder as NSString).appendingPathComponent(".melody-old-\(UUID().uuidString).app")
        do {
            try FileManager.default.moveItem(atPath: installed, toPath: old)
            try FileManager.default.moveItem(atPath: staged, toPath: installed)
        } catch {
            if !FileManager.default.fileExists(atPath: installed) {
                try? FileManager.default.moveItem(atPath: old, toPath: installed)
            }
            try? FileManager.default.removeItem(atPath: staged)
            throw error
        }
        try? FileManager.default.removeItem(atPath: old)
    }

    private func finish(melodyUpdated: Bool) {
        state = .installing(melodyUpdated ? "Updated — reopen Melody to use the new version" : "Updated")
        if System.agentInstalled(LaunchAgents.engine) {
            System.restartAgent(LaunchAgents.engine)
        }
        // Under its LaunchAgent, launchd starts the new copy; otherwise the
        // Finder opens it once this one has gone.
        if relaunch, ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] != LaunchAgents.app {
            let path = Bundle.main.bundlePath.replacingOccurrences(of: "'", with: "'\\''")
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = ["-c", "sleep 2; /usr/bin/open '\(path)'"]
            try? relaunch.run()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
    }
}
