// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import XCTest
@testable import MelodyEngineCore

final class NewAlbumsTests: XCTestCase {
    private func encoded(_ text: String) -> String { Data(text.utf8).base64EncodedString() }

    private func album(folder: Data = Data("/music/Boston/1976 Boston".utf8)) -> NewAlbum {
        NewAlbum(key: "a2V5", artist: "Boston", title: "Boston", date: "1976", folder: folder,
                 paths: [encoded("/music/Boston/1976 Boston/01 More Than a Feeling.flac"),
                         encoded("/music/Boston/1976 Boston/02 Peace of Mind.flac")])
    }

    func testTheEventsAlbumsAreRead() {
        let data: Message = ["albums": [
            ["key": "a2V5", "artist": "Boston", "album": "Boston", "date": "1976",
             "folder": encoded("/music/Boston/1976 Boston"), "paths": [encoded("/a.flac")]],
            ["artist": "no key, no album"],
        ]]
        let albums = NewAlbum.albums(inEvent: data)
        XCTAssertEqual(albums.count, 1)
        XCTAssertEqual(albums.first?.folder, Data("/music/Boston/1976 Boston".utf8))
        XCTAssertEqual(albums.first?.paths, [encoded("/a.flac")])
        XCTAssertEqual(albums.first?.described, "Boston – Boston (1976)")
    }

    func testOnlyUnratedTracksAreRatedUnlessAskedOtherwise() {
        let rows: [Message] = [["rating_hash": "h1", "rating": 0],
                               ["rating_hash": "h2", "rating": 8],
                               ["rating_hash": "h3", "rating": 4],
                               ["rating": 0]]
        var actions = NewAlbumActions()
        XCTAssertEqual(NewAlbumWork.ratings(for: rows, actions: actions).map(\.hash), ["h1"])
        actions.onlyUnrated = false
        XCTAssertEqual(NewAlbumWork.ratings(for: rows, actions: actions).map(\.hash), ["h1", "h2"])
        actions.rate = false
        XCTAssertTrue(NewAlbumWork.ratings(for: rows, actions: actions).isEmpty)
        actions.rate = true
        actions.rating = 11
        XCTAssertTrue(NewAlbumWork.ratings(for: rows, actions: actions).isEmpty)
    }

    func testTheFolderIsQuotedForTheShellWhateverItHolds() {
        let folder = Data("/music/Guns N' Roses/$(rm -rf ~) `x` \"q\"".utf8)
        let line = NewAlbumWork.commandLine("echo {} && ls {}", folder: folder)
        XCTAssertEqual(String(decoding: line, as: UTF8.self),
                       #"echo '/music/Guns N'\'' Roses/$(rm -rf ~) `x` "q"' && ls '/music/Guns N'\'' Roses/$(rm -rf ~) `x` "q"'"#)
        // What the shell hands the command is the folder, byte for byte.
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", String(decoding: NewAlbumWork.commandLine("printf %s {}", folder: folder), as: UTF8.self)]
        let output = Pipe()
        shell.standardOutput = output
        try? shell.run()
        shell.waitUntilExit()
        XCTAssertEqual(output.fileHandleForReading.readDataToEndOfFile(), folder)
        let added = NewAlbumWork.commandLine("my-tool --album", folder: Data("/x y".utf8))
        XCTAssertEqual(String(decoding: added, as: UTF8.self), "my-tool --album '/x y'")
        // Not UTF-8: its bytes, as they are.
        let raw = Data([0x2F, 0xFF])
        XCTAssertEqual(NewAlbumWork.commandLine("ls {}", folder: raw), Data("ls '".utf8) + raw + Data("'".utf8))
    }

    func testTheCommandIsToldTheAlbum() {
        let environment = NewAlbumWork.environment(for: album())
        XCTAssertEqual(environment["MELODY_ALBUM_FOLDER"], "/music/Boston/1976 Boston")
        XCTAssertEqual(environment["MELODY_ALBUM_ARTIST"], "Boston")
        XCTAssertEqual(environment["MELODY_ALBUM_TITLE"], "Boston")
        XCTAssertEqual(environment["MELODY_ALBUM_DATE"], "1976")
    }

    func testSettingsSavedByAnOlderAppKeepWhatTheySay() throws {
        let older = Data(#"{"enabled": true, "rating": 6}"#.utf8)
        let actions = try JSONDecoder().decode(NewAlbumActions.self, from: older)
        XCTAssertTrue(actions.enabled)
        XCTAssertEqual(actions.rating, 6)
        XCTAssertTrue(actions.replayGain)
        XCTAssertTrue(actions.onlyUnrated)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "new-albums-\(UUID().uuidString)"))
        var changed = NewAlbumActions()
        changed.command = "true"
        changed.save(to: defaults)
        XCTAssertEqual(NewAlbumActions.load(from: defaults), changed)
    }

    func testNothingIsDoneUntilItIsOn() {
        var actions = NewAlbumActions()
        XCTAssertFalse(actions.doesSomething)
        actions.enabled = true
        XCTAssertTrue(actions.doesSomething)
        actions.replayGain = false
        actions.rate = false
        XCTAssertFalse(actions.doesSomething)
        actions.runCommand = true
        XCTAssertFalse(actions.doesSomething, "an empty command is nothing")
        actions.command = "true"
        XCTAssertTrue(actions.doesSomething)
    }

    func testReplayGainOutcomesAreSaidInALine() {
        XCTAssertEqual(NewAlbumWork.describeReplayGain(["result": ["written": 9, "failed": 0, "problems": []]]),
                       "ReplayGain written to 9 files")
        XCTAssertEqual(NewAlbumWork.describeReplayGain(
            ["result": ["refused": true, "problems": [["message": "read-only"]]]]),
                       "ReplayGain not written: read-only")
        XCTAssertEqual(NewAlbumWork.describeReplayGain(["error": ["message": "no such file"]]),
                       "ReplayGain failed: no such file")
    }

    /// The whole of it against a stand-in engine: rated, measured, the
    /// command run, in that order, as the settings ask.
    func testANewAlbumIsRatedMeasuredAndItsCommandRun() throws {
        let lock = NSLock()
        var methods: [String] = []
        var rated: [Message] = []
        var gain: Message = [:]
        let engine = try FakeEngine { request in
            let method = request["method"] as? String ?? ""
            let params = request["params"] as? Message ?? [:]
            lock.lock(); methods.append(method); lock.unlock()
            switch method {
            case "catalogue.query":
                XCTAssertEqual(params["album_key"] as? String, "a2V5")
                return [["id": request["id"]!, "result": ["entries": [
                    ["key": "t1", "rating": 0, "rating_hash": "h1"],
                    ["key": "t2", "rating": 9, "rating_hash": "h2"]], "more": false]]]
            case "catalogue.set_rating":
                lock.lock(); rated.append(params); lock.unlock()
                return [["id": request["id"]!, "result": [:]]]
            case "job.submit":
                lock.lock(); gain = params; lock.unlock()
                return [["id": request["id"]!, "result": ["job_id": "rg"]],
                        ["event": "job.finished", "data": ["job_id": "rg", "outcome":
                            ["result": ["written": 2, "failed": 0, "problems": []]]]]]
            default:
                return [["id": request["id"]!, "error": ["message": "unexpected \(method)"]]]
            }
        }
        var actions = NewAlbumActions()
        actions.enabled = true
        actions.truePeak = true
        actions.runCommand = true
        actions.command = "tag-it {}"
        var ran: (Data, [String: String])?
        let lines = Engine.applyActions(actions, to: album(), socketPath: engine.path,
                                        run: { line, environment in ran = (line, environment); return 0 })
        XCTAssertEqual(lines, ["rated 1 track 4", "ReplayGain written to 2 files", "command done"])
        XCTAssertEqual(methods, ["catalogue.query", "catalogue.set_rating", "job.submit"])
        XCTAssertEqual(rated.first?["hash"] as? String, "h1")
        XCTAssertEqual(rated.first?["rating"] as? Int, 4)
        XCTAssertEqual(gain["job"] as? String, "replaygain.apply")
        let gainParams = gain["params"] as? Message ?? [:]
        XCTAssertEqual(gainParams["grouping"] as? String, "album")
        XCTAssertEqual(gainParams["true_peak"] as? Bool, true)
        XCTAssertEqual(gainParams["sidecar"] as? Bool, false)
        XCTAssertEqual((gainParams["paths"] as? [String])?.count, 2)
        XCTAssertEqual(ran.map { String(decoding: $0.0, as: UTF8.self) }, "tag-it '/music/Boston/1976 Boston'")
        XCTAssertEqual(ran?.1["MELODY_ALBUM_ARTIST"], "Boston")
    }

    func testAFailedStepDoesNotKeepTheNextFromBeingTried() throws {
        let engine = try FakeEngine { request in
            if request["method"] as? String == "catalogue.query" {
                return [["id": request["id"]!, "error": ["message": "no such album"]]]
            }
            return [["id": request["id"]!, "result": ["job_id": "rg"]],
                    ["event": "job.finished", "data": ["job_id": "rg", "outcome": ["error": ["message": "disk full"]]]]]
        }
        var actions = NewAlbumActions()
        actions.enabled = true
        let lines = Engine.applyActions(actions, to: album(), socketPath: engine.path, run: { _, _ in 0 })
        XCTAssertEqual(lines, ["rating failed: no such album", "ReplayGain failed: disk full"])
    }

    func testTheWatcherSaysEachNewAlbum() throws {
        let engine = try FakeEngine(opened: [
            ["event": "playback.changed", "data": [:]],
            ["event": "catalogue.albums_added", "data": ["albums": [
                ["key": "a2V5", "artist": "Boston", "album": "Boston", "date": "1976",
                 "folder": encoded("/music/Boston/1976 Boston"), "paths": []]]]],
        ]) { _ in [] }
        let seen = expectation(description: "the album is said")
        var albums: [NewAlbum] = []
        let watcher = NewAlbumWatcher(socketPath: engine.path) { album in
            albums.append(album)
            seen.fulfill()
        }
        watcher.start()
        defer { watcher.stop() }
        wait(for: [seen], timeout: 5)
        XCTAssertEqual(albums.map(\.described), ["Boston – Boston (1976)"])
    }
}
