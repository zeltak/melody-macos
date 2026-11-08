// SPDX-License-Identifier: GPL-3.0-only
//
// Releases of melody-macos on GitHub, as the menu-bar app reads them: each
// is tagged build-<BUILD> -- melody-music's commit count, a dot, this
// repository's -- and carries one DMG holding both apps.

import Foundation

public struct BuildNumber: Comparable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ text: String) {
        let parts = text.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, !parts.contains(nil) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    public static func < (left: BuildNumber, right: BuildNumber) -> Bool {
        for index in 0..<max(left.parts.count, right.parts.count) {
            let a = index < left.parts.count ? left.parts[index] : 0
            let b = index < right.parts.count ? right.parts[index] : 0
            if a != b { return a < b }
        }
        return false
    }

    public static func == (left: BuildNumber, right: BuildNumber) -> Bool {
        !(left < right) && !(right < left)
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }
}

public struct Release: Equatable {
    public let build: BuildNumber
    public let title: String
    public let dmg: URL

    public static func == (left: Release, right: Release) -> Bool {
        left.build == right.build && left.dmg == right.dmg
    }

    /// The release GitHub's API describes; nil when it is not one of ours.
    public static func parse(_ data: Data) -> Release? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String, tag.hasPrefix("build-"),
              let build = BuildNumber(String(tag.dropFirst("build-".count))),
              let assets = object["assets"] as? [[String: Any]],
              let dmg = assets.lazy
                .filter({ ($0["name"] as? String)?.hasSuffix(".dmg") == true })
                .compactMap({ ($0["browser_download_url"] as? String).flatMap(URL.init(string:)) })
                .first
        else { return nil }
        return Release(build: build, title: object["name"] as? String ?? tag, dmg: dmg)
    }

    public static func latestURL(repository: String) -> URL? {
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")
    }
}

/// The LaunchAgents the menu-bar app keeps: one for itself, one for melodyd.
public enum LaunchAgents {
    public static let app = "org.melody.engine-app"
    public static let engine = "org.melody.melodyd"

    public static func path(_ label: String, home: String = NSHomeDirectory()) -> String {
        (home as NSString).appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// The menu-bar app: at login, and back whenever it stops.
    public static func appDefinition(executable: String, logs: String) -> [String: Any] {
        [
            "Label": app,
            "ProgramArguments": [executable],
            "LimitLoadToSessionType": "Aqua",
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 10,
            "StandardOutPath": "\(logs)/engine-app.log",
            "StandardErrorPath": "\(logs)/engine-app.log",
        ]
    }

    /// melodyd from the app bundle, with no options: it finds its state,
    /// configuration and socket where it always does. Restarted if it fails.
    public static func engineDefinition(executable: String, logs: String) -> [String: Any] {
        [
            "Label": engine,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 10,
            "ProcessType": "Interactive",
            "EnvironmentVariables": ["PATH": "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"],
            "StandardOutPath": "\(logs)/melodyd.log",
            "StandardErrorPath": "\(logs)/melodyd.log",
        ]
    }
}
