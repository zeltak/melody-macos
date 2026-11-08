// SPDX-License-Identifier: GPL-3.0-only
//
// What the menu-bar app asks of macOS: LaunchAgents through launchctl, the
// command-line tool's link, and whether a downloaded app was signed by the
// same team as this one.

import Foundation
import MelodyEngineCore

enum System {
    static var uid: uid_t { getuid() }
    static var logs: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/Melody")
    }

    /// Runs a program and waits; its status and standard error.
    @discardableResult
    static func run(_ program: String, _ arguments: [String]) -> (status: Int32, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func output(_ program: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: LaunchAgents

    static func agentInstalled(_ label: String) -> Bool {
        FileManager.default.fileExists(atPath: LaunchAgents.path(label))
    }

    static func agentRunning(_ label: String) -> Bool {
        run("/bin/launchctl", ["print", "gui/\(uid)/\(label)"]).status == 0
    }

    /// Writes the agent and loads it, replacing one loaded before.
    static func installAgent(_ definition: [String: Any]) throws {
        guard let label = definition["Label"] as? String else { return }
        try FileManager.default.createDirectory(atPath: logs, withIntermediateDirectories: true)
        let path = LaunchAgents.path(label)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: definition, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
        let loaded = run("/bin/launchctl", ["bootstrap", "gui/\(uid)", path])
        if loaded.status != 0 {
            throw Failure("launchctl could not load \(label): \(loaded.error)")
        }
    }

    static func removeAgent(_ label: String) {
        run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
        try? FileManager.default.removeItem(atPath: LaunchAgents.path(label))
    }

    @discardableResult
    static func restartAgent(_ label: String) -> (status: Int32, error: String) {
        run("/bin/launchctl", ["kickstart", "-k", "gui/\(uid)/\(label)"])
    }

    // MARK: The command-line tool

    static let toolLink = "/usr/local/bin/melody-cli"

    static func toolInstalled(pointingAt target: String) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: toolLink)) == target
    }

    /// Links melody-cli into /usr/local/bin, asking for an administrator's
    /// password as the Installer does.
    static func installTool(target: String) throws {
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command = "/bin/mkdir -p /usr/local/bin && /bin/ln -sfn \(quoted(target)) \(quoted(toolLink))"
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        if let error {
            throw Failure(error[NSAppleScript.errorMessage] as? String ?? "melody-cli was not installed")
        }
    }

    // MARK: Signatures

    /// The team that signed the code at `path`, if it verifies.
    static func team(of path: String) -> String? {
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", path]).status == 0 else {
            return nil
        }
        for line in output("/usr/bin/codesign", ["-dv", path]).split(separator: "\n")
            where line.hasPrefix("TeamIdentifier=") {
            let team = String(line.dropFirst("TeamIdentifier=".count))
            return team == "not set" ? nil : team
        }
        return nil
    }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
