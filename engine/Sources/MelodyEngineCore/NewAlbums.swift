// SPDX-License-Identifier: GPL-3.0-only
//
// What the app does with each album new to the library: the engine says
// catalogue.albums_added once an album is whole (no track of it for 30
// seconds), whatever added it -- a rescan, a copy into the music folder.
// For each, as the settings ask: ReplayGain measured and written by the
// engine, its tracks rated, and a command of the user's own run with its
// folder. The engine does the work; this only asks.

import Foundation

/// What is done with a new album. Stored in the app's defaults as JSON.
public struct NewAlbumActions: Codable, Equatable {
    /// Nothing is done unless this is on.
    public var enabled = false

    public var replayGain = true
    /// Album and track gain, or track gain alone.
    public var albumGain = true
    public var truePeak = false
    /// Gains kept beside the files, which are left untouched.
    public var sidecar = false

    public var rate = true
    /// 1-10 as Melody keeps it: 2 stars of 5 is 4.
    public var rating = 4
    /// Tracks rated already -- by their tags, say -- keep theirs.
    public var onlyUnrated = true

    public var runCommand = false
    /// Run by /bin/sh: {} is the album's folder, quoted;
    /// MELODY_ALBUM_FOLDER, _ARTIST, _TITLE and _DATE are set.
    public var command = ""

    public init() {}

    // Settings saved by an older app lack newer fields: those take their
    // defaults rather than the whole being lost.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = NewAlbumActions()
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        replayGain = try values.decodeIfPresent(Bool.self, forKey: .replayGain) ?? defaults.replayGain
        albumGain = try values.decodeIfPresent(Bool.self, forKey: .albumGain) ?? defaults.albumGain
        truePeak = try values.decodeIfPresent(Bool.self, forKey: .truePeak) ?? defaults.truePeak
        sidecar = try values.decodeIfPresent(Bool.self, forKey: .sidecar) ?? defaults.sidecar
        rate = try values.decodeIfPresent(Bool.self, forKey: .rate) ?? defaults.rate
        rating = try values.decodeIfPresent(Int.self, forKey: .rating) ?? defaults.rating
        onlyUnrated = try values.decodeIfPresent(Bool.self, forKey: .onlyUnrated) ?? defaults.onlyUnrated
        runCommand = try values.decodeIfPresent(Bool.self, forKey: .runCommand) ?? defaults.runCommand
        command = try values.decodeIfPresent(String.self, forKey: .command) ?? defaults.command
    }

    public static let defaultsKey = "newAlbumActions"

    public static func load(from defaults: UserDefaults = .standard) -> NewAlbumActions {
        guard let data = defaults.data(forKey: defaultsKey),
              let stored = try? JSONDecoder().decode(NewAlbumActions.self, from: data)
        else { return NewAlbumActions() }
        return stored
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: NewAlbumActions.defaultsKey)
        }
    }

    /// Whether anything at all would be done.
    public var doesSomething: Bool {
        enabled && (replayGain || (rate && (1...10).contains(rating))
                    || (runCommand && !command.trimmingCharacters(in: .whitespaces).isEmpty))
    }
}

/// An album as catalogue.albums_added says it.
public struct NewAlbum: Equatable {
    /// The album's key, encoded as the engine sends it.
    public var key: String
    public var artist: String
    public var title: String
    public var date: String
    /// The album's folder as raw bytes; empty when the engine said none.
    public var folder: Data
    /// Its tracks' paths, encoded as the engine sends them.
    public var paths: [String]

    public init(key: String, artist: String, title: String, date: String, folder: Data, paths: [String]) {
        self.key = key
        self.artist = artist
        self.title = title
        self.date = date
        self.folder = folder
        self.paths = paths
    }

    /// The albums of one catalogue.albums_added event's data.
    public static func albums(inEvent data: Message) -> [NewAlbum] {
        (data["albums"] as? [Message] ?? []).compactMap { album in
            guard let key = album["key"] as? String, !key.isEmpty else { return nil }
            return NewAlbum(key: key,
                            artist: album["artist"] as? String ?? "",
                            title: album["album"] as? String ?? "",
                            date: album["date"] as? String ?? "",
                            folder: RawPath.decode(album["folder"] as? String ?? "") ?? Data(),
                            paths: album["paths"] as? [String] ?? [])
        }
    }

    /// "Artist – Album (date)", for the menu and the log.
    public var described: String {
        let name = [artist, title].filter { !$0.isEmpty }.joined(separator: " – ")
        let shown = name.isEmpty ? RawPath.display(folder) : name
        return date.isEmpty ? shown : "\(shown) (\(date))"
    }
}

/// The engine's paths travel as base64 of their raw bytes: a path need not
/// be UTF-8.
public enum RawPath {
    public static func decode(_ encoded: String) -> Data? {
        Data(base64Encoded: encoded)
    }

    /// For people: the bytes as UTF-8, any that are not replaced.
    public static func display(_ raw: Data) -> String {
        String(decoding: raw, as: UTF8.self)
    }

    /// The path quoted for /bin/sh: within single quotes every byte is
    /// itself, and a single quote is closed, escaped and opened again.
    public static func shellQuoted(_ raw: Data) -> Data {
        var quoted = Data("'".utf8)
        for byte in raw {
            if byte == UInt8(ascii: "'") {
                quoted.append(contentsOf: Array("'\\''".utf8))
            } else {
                quoted.append(byte)
            }
        }
        quoted.append(UInt8(ascii: "'"))
        return quoted
    }
}

public enum NewAlbumWork {
    /// The ratings to set: each track's rating hash and the rating it gets.
    /// Rows are catalogue.query's, with `rating` and `rating_hash`.
    public static func ratings(for rows: [Message], actions: NewAlbumActions) -> [(hash: String, rating: Int)] {
        guard actions.rate, (1...10).contains(actions.rating) else { return [] }
        return rows.compactMap { row in
            guard let hash = row["rating_hash"] as? String, !hash.isEmpty else { return nil }
            let current = (row["rating"] as? NSNumber)?.intValue ?? 0
            if current == actions.rating || (actions.onlyUnrated && current > 0) { return nil }
            return (hash, actions.rating)
        }
    }

    /// The shell command for an album: every {} its folder, quoted; with
    /// none, the folder is added at the end. Bytes, as the folder may not be
    /// UTF-8.
    public static func commandLine(_ template: String, folder: Data) -> Data {
        let quoted = RawPath.shellQuoted(folder)
        let parts = template.components(separatedBy: "{}")
        var line = Data()
        for (index, part) in parts.enumerated() {
            if index > 0 { line.append(quoted) }
            line.append(Data(part.utf8))
        }
        if parts.count == 1 {
            line.append(UInt8(ascii: " "))
            line.append(quoted)
        }
        return line
    }

    /// What the command is told of the album, beside {}.
    public static func environment(for album: NewAlbum) -> [String: String] {
        ["MELODY_ALBUM_FOLDER": RawPath.display(album.folder),
         "MELODY_ALBUM_ARTIST": album.artist,
         "MELODY_ALBUM_TITLE": album.title,
         "MELODY_ALBUM_DATE": album.date]
    }

    /// replaygain.apply's parameters, as melody-cli replaygain asks it.
    public static func replayGainParams(for album: NewAlbum, actions: NewAlbumActions) -> Message {
        ["paths": album.paths,
         "grouping": actions.albumGain ? "album" : "track",
         "true_peak": actions.truePeak,
         "sidecar": actions.sidecar]
    }

    /// One line saying what came of ReplayGain, from its job's outcome.
    public static func describeReplayGain(_ outcome: Message) -> String {
        if let failure = outcome["error"] {
            return "ReplayGain failed: \(message(of: failure) ?? "the engine could not measure it")"
        }
        let result = outcome["result"] as? Message ?? [:]
        let problems = (result["problems"] as? [Message] ?? []).compactMap { message(of: $0["message"] as Any) }
        if (result["refused"] as? Bool) == true {
            return "ReplayGain not written: " + (problems.first ?? "a file could not take it")
        }
        let written = (result["written"] as? NSNumber)?.intValue ?? 0
        let failed = (result["failed"] as? NSNumber)?.intValue ?? 0
        var line = "ReplayGain written to \(written) file\(written == 1 ? "" : "s")"
        if failed > 0 { line += ", \(failed) failed" }
        if let first = problems.first { line += ": \(first)" }
        return line
    }

    /// Text the engine sends as a string, or as {"message"}, or as
    /// {"bytes"} when it is not UTF-8.
    static func message(of value: Any) -> String? {
        if let text = value as? String { return text }
        guard let object = value as? Message else { return nil }
        if let text = object["message"] { return message(of: text) }
        if let bytes = object["bytes"] as? String, let raw = RawPath.decode(bytes) {
            return RawPath.display(raw)
        }
        return nil
    }
}

extension Engine {
    /// Runs a job to its end, reporting its progress; its outcome. When
    /// `shouldStop` turns true the connection is dropped, which stops
    /// watching, not the engine's job: nil.
    public static func runJob(_ connection: EngineConnection, job: String, params: Message = [:],
                              progress: @escaping (Message) -> Void = { _ in },
                              shouldStop: @escaping () -> Bool = { false }) throws -> Message? {
        var submission: Message = ["job": job]
        if !params.isEmpty { submission["params"] = params }
        try connection.send(["id": 1, "method": "job.submit", "params": submission])
        var id: String?
        // Finished before job.submit's answer named it.
        var finishedEarly: [String: Message] = [:]
        while true {
            if shouldStop() { return nil }
            guard let message = try connection.receive(timeout: 0.25) else { continue }
            if let answer = try EngineConnection.answer(message, to: 1) {
                guard let named = (answer as? Message)?["job_id"] as? String else {
                    throw EngineError.malformed("job.submit did not name the job it started")
                }
                id = named
                if let outcome = finishedEarly[named] { return outcome }
                continue
            }
            guard let event = message["event"] as? String,
                  let data = message["data"] as? Message,
                  let jobID = data["job_id"] as? String
            else { continue }
            switch event {
            case "job.progress" where jobID == id:
                progress(data)
            case "job.finished":
                let outcome = data["outcome"] as? Message ?? [:]
                if jobID == id { return outcome }
                if id == nil { finishedEarly[jobID] = outcome }
            default:
                break
            }
        }
    }

    /// The album's tracks, with their ratings and rating hashes.
    public static func albumTracks(_ connection: EngineConnection, albumKey: String) throws -> [Message] {
        var rows: [Message] = []
        var offset = 0
        while true {
            let page = try connection.call("catalogue.query",
                                           params: ["kind": 2, "text": "", "album_key": albumKey,
                                                    "offset": offset, "limit": 2000,
                                                    "fields": ["rating", "rating_hash"]],
                                           timeout: 30) as? Message ?? [:]
            let entries = page["entries"] as? [Message] ?? []
            rows += entries
            offset += entries.count
            if entries.isEmpty || (page["more"] as? Bool) != true { return rows }
        }
    }

    /// Does what `actions` asks with one new album, in order: ratings,
    /// ReplayGain, the command. Each step is said in a line; one that fails
    /// does not keep the next from being tried. `run` runs the command line
    /// with the album's environment and returns its exit status.
    public static func applyActions(_ actions: NewAlbumActions, to album: NewAlbum, socketPath: String,
                                    run: (Data, [String: String]) -> Int32,
                                    shouldStop: @escaping () -> Bool = { false }) -> [String] {
        var lines: [String] = []
        if actions.rate && (1...10).contains(actions.rating) {
            do {
                let connection = try EngineConnection(socketPath: socketPath)
                defer { connection.close() }
                let wanted = NewAlbumWork.ratings(for: try albumTracks(connection, albumKey: album.key),
                                                  actions: actions)
                for (index, change) in wanted.enumerated() {
                    _ = try connection.call("catalogue.set_rating",
                                            params: ["hash": change.hash, "album": false, "rating": change.rating],
                                            id: index + 2, timeout: 10)
                }
                lines.append("rated \(wanted.count) track\(wanted.count == 1 ? "" : "s") \(actions.rating)")
            } catch {
                lines.append("rating failed: \(error)")
            }
        }
        if actions.replayGain && !album.paths.isEmpty && !shouldStop() {
            do {
                let connection = try EngineConnection(socketPath: socketPath)
                defer { connection.close() }
                if let outcome = try runJob(connection, job: "replaygain.apply",
                                            params: NewAlbumWork.replayGainParams(for: album, actions: actions),
                                            shouldStop: shouldStop) {
                    lines.append(NewAlbumWork.describeReplayGain(outcome))
                }
            } catch {
                lines.append("ReplayGain failed: \(error)")
            }
        }
        let template = actions.command.trimmingCharacters(in: .whitespaces)
        if actions.runCommand && !template.isEmpty && !shouldStop() {
            let status = run(NewAlbumWork.commandLine(template, folder: album.folder),
                             NewAlbumWork.environment(for: album))
            lines.append(status == 0 ? "command done" : "command ended with \(status)")
        }
        return lines
    }
}

/// Follows catalogue.albums_added on its own thread, connecting again when
/// the engine goes and comes back. Albums new while it was not connected
/// are not said by the engine again.
public final class NewAlbumWatcher {
    private let socketPath: String
    private let arrived: (NewAlbum) -> Void
    private let connected: (Bool) -> Void
    private let lock = NSLock()
    private var stopped = false
    private var thread: Thread?

    public init(socketPath: String, connected: @escaping (Bool) -> Void = { _ in },
                arrived: @escaping (NewAlbum) -> Void) {
        self.socketPath = socketPath
        self.connected = connected
        self.arrived = arrived
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    public func start() {
        let thread = Thread { [weak self] in self?.follow() }
        thread.name = "org.melody.engine-app.new-albums"
        self.thread = thread
        thread.start()
    }

    public func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    private func follow() {
        while !isStopped {
            do {
                let connection = try EngineConnection(socketPath: socketPath)
                defer { connection.close() }
                connected(true)
                while !isStopped {
                    guard let message = try connection.receive(timeout: 1) else { continue }
                    guard message["event"] as? String == "catalogue.albums_added",
                          let data = message["data"] as? Message
                    else { continue }
                    NewAlbum.albums(inEvent: data).forEach(arrived)
                }
            } catch {
                connected(false)
            }
            // The engine restarting, or not yet started: asked again soon.
            for _ in 0..<50 where !isStopped { Thread.sleep(forTimeInterval: 0.1) }
        }
    }
}
