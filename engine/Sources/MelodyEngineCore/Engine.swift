// SPDX-License-Identifier: GPL-3.0-only
//
// What the status icon asks melodyd: whether it answers, and to rescan its
// library -- through the engine's own catalogue.scan job, as every Melody
// client starts it -- plus how the engine's service is restarted.

import Foundation

public enum Engine {
    /// The engine's name when it answers engine.info.
    public static func probe(socketPath: String, timeout: TimeInterval = 1) throws -> String {
        let connection = try EngineConnection(socketPath: socketPath)
        defer { connection.close() }
        let info = try connection.call("engine.info", timeout: timeout)
        guard let name = (info as? Message)?["name"] as? String else {
            throw EngineError.malformed("engine.info has no name")
        }
        return name
    }

    /// Runs a library scan to its end, reporting progress as it goes. When
    /// `shouldStop` turns true the connection is dropped, which stops
    /// watching, not the engine's scan.
    public static func scan(socketPath: String,
                            progress: @escaping (ScanCounts) -> Void,
                            shouldStop: @escaping () -> Bool = { false }) throws -> ScanOutcome {
        let connection = try EngineConnection(socketPath: socketPath)
        defer { connection.close() }
        try connection.send(["id": 1, "method": "job.submit",
                             "params": ["job": "catalogue.scan"]])
        var job: String?
        // Finished before job.submit's answer named it.
        var finishedEarly: [String: Message] = [:]
        while true {
            if shouldStop() { return .detached }
            guard let message = try connection.receive(timeout: 0.25) else { continue }
            if let answer = try EngineConnection.answer(message, to: 1) {
                guard let id = (answer as? Message)?["job_id"] as? String else {
                    throw EngineError.malformed("job.submit did not name the job it started")
                }
                job = id
                if let outcome = finishedEarly[id] {
                    return ScanOutcome(outcome)
                }
                continue
            }
            guard let event = message["event"] as? String,
                  let data = message["data"] as? Message,
                  let id = data["job_id"] as? String
            else { continue }
            switch event {
            case "job.progress" where id == job:
                progress(ScanCounts(data))
            case "job.finished":
                let outcome = data["outcome"] as? Message ?? [:]
                if id == job { return ScanOutcome(outcome) }
                if job == nil { finishedEarly[id] = outcome }
            default:
                break
            }
        }
    }

    /// launchctl's arguments to restart a LaunchAgent of this user; nil
    /// without a label. A label is an argument, never shell text.
    public static func restartCommand(service: String, uid: uid_t) -> (program: String, arguments: [String])? {
        guard !service.isEmpty else { return nil }
        return ("/bin/launchctl", ["kickstart", "-k", "gui/\(uid)/\(service)"])
    }

    /// Where melodyd listens by default: $XDG_RUNTIME_DIR, else the user's
    /// temporary directory -- the same one a LaunchAgent of this user gets.
    public static func defaultSocketPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let directory = environment["XDG_RUNTIME_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? NSTemporaryDirectory()
        return (directory as NSString).appendingPathComponent("melodyd.sock")
    }
}

public struct ScanCounts: Equatable {
    public var visited: UInt64
    public var indexed: UInt64

    public init(visited: UInt64 = 0, indexed: UInt64 = 0) {
        self.visited = visited
        self.indexed = indexed
    }

    init(_ data: Message) {
        visited = (data["visited"] as? NSNumber)?.uint64Value ?? 0
        indexed = (data["indexed"] as? NSNumber)?.uint64Value ?? 0
    }
}

public enum ScanOutcome: Equatable {
    case complete(ScanCounts)
    /// Unavailable folders, failed files, or cancelled.
    case incomplete(ScanCounts)
    case failed(String)
    /// Stopped watching; the engine carries on.
    case detached

    init(_ outcome: Message) {
        let counts = ScanCounts(outcome)
        if let error = outcome["error"] {
            if let text = error as? String {
                self = .failed(text)
            } else if let message = (error as? Message)?["message"] as? String {
                self = .failed(message)
            } else {
                self = .failed("the scan failed")
            }
        } else if (outcome["cancelled"] as? Bool) == true || (outcome["incomplete"] as? Bool) == true
                    || ((outcome["failed"] as? NSNumber)?.uint64Value ?? 0) != 0 {
            self = .incomplete(counts)
        } else {
            self = .complete(counts)
        }
    }
}
