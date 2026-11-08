// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import XCTest
@testable import MelodyEngineCore

/// A stand-in for melodyd: accepts one connection on a Unix socket and
/// answers each request line with the lines `reply` gives for it.
final class FakeEngine {
    let path: String
    private let listener: Int32
    private let thread: Thread

    init(reply: @escaping (Message) -> [Message]) throws {
        let path = "/tmp/melody-engine-test-\(UUID().uuidString.prefix(8)).sock"
        self.path = path
        unlink(path)
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            let bytes = Array(path.utf8)
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 1) == 0 else {
            throw EngineError.connect("fake engine cannot listen")
        }
        self.listener = listener
        thread = Thread {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            // The client may hang up first; that is not the fake's death.
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var pending = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = read(client, &chunk, chunk.count)
                if count <= 0 { return }
                pending.append(contentsOf: chunk[0..<count])
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = pending[pending.startIndex..<newline]
                    pending.removeSubrange(pending.startIndex...newline)
                    guard let request = try? JSONSerialization.jsonObject(with: line) as? Message else {
                        return
                    }
                    for answer in reply(request) {
                        var bytes = try! JSONSerialization.data(withJSONObject: answer)
                        bytes.append(0x0A)
                        _ = bytes.withUnsafeBytes { write(client, $0.baseAddress!, $0.count) }
                    }
                }
            }
        }
        thread.start()
    }

    deinit {
        close(listener)
        unlink(path)
    }
}

final class EngineTests: XCTestCase {
    func testProbeNamesTheEngine() throws {
        let engine = try FakeEngine { request in
            XCTAssertEqual(request["method"] as? String, "engine.info")
            return [["event": "playback.changed", "data": [:]],
                    ["id": request["id"]!, "result": ["name": "ikloogmniserver"]]]
        }
        XCTAssertEqual(try Engine.probe(socketPath: engine.path), "ikloogmniserver")
    }

    func testProbeWithoutAnEngineSaysItCannotReachIt() {
        XCTAssertThrowsError(try Engine.probe(socketPath: "/tmp/melody-engine-no-such.sock")) { error in
            guard case EngineError.connect = error else {
                return XCTFail("unexpected \(error)")
            }
        }
    }

    func testProbeReportsTheEnginesRefusal() throws {
        let engine = try FakeEngine { request in
            [["id": request["id"]!, "error": ["code": "unauthorized", "message": "no"]]]
        }
        XCTAssertThrowsError(try Engine.probe(socketPath: engine.path)) { error in
            XCTAssertEqual(error as? EngineError, .remote("no"))
        }
    }

    func testScanFollowsItsJobToTheEnd() throws {
        let engine = try FakeEngine { request in
            XCTAssertEqual(request["method"] as? String, "job.submit")
            XCTAssertEqual((request["params"] as? Message)?["job"] as? String, "catalogue.scan")
            return [["id": request["id"]!, "result": ["job_id": "j1"]],
                    // Another client's job is not this one.
                    ["event": "job.progress", "data": ["job_id": "other", "visited": 99]],
                    ["event": "job.progress", "data": ["job_id": "j1", "visited": 4, "indexed": 2]],
                    ["event": "job.finished",
                     "data": ["job_id": "j1", "outcome": ["visited": 10, "indexed": 7]]]]
        }
        var seen: [ScanCounts] = []
        let outcome = try Engine.scan(socketPath: engine.path, progress: { seen.append($0) })
        XCTAssertEqual(seen, [ScanCounts(visited: 4, indexed: 2)])
        XCTAssertEqual(outcome, .complete(ScanCounts(visited: 10, indexed: 7)))
    }

    func testAScanFinishedBeforeItWasNamedIsStillItsOwn() throws {
        let engine = try FakeEngine { request in
            [["event": "job.finished",
              "data": ["job_id": "fast", "outcome": ["visited": 1, "indexed": 1, "failed": 1]]],
             ["id": request["id"]!, "result": ["job_id": "fast"]]]
        }
        let outcome = try Engine.scan(socketPath: engine.path, progress: { _ in })
        XCTAssertEqual(outcome, .incomplete(ScanCounts(visited: 1, indexed: 1)))
    }

    func testAFailedScanSaysWhy() throws {
        let engine = try FakeEngine { request in
            [["id": request["id"]!, "result": ["job_id": "j"]],
             ["event": "job.finished",
              "data": ["job_id": "j", "outcome": ["error": ["message": "no music folders"]]]]]
        }
        XCTAssertEqual(try Engine.scan(socketPath: engine.path, progress: { _ in }),
                       .failed("no music folders"))
    }

    func testStoppingLeavesTheScanToTheEngine() throws {
        let engine = try FakeEngine { request in
            [["id": request["id"]!, "result": ["job_id": "slow"]]]
        }
        let outcome = try Engine.scan(socketPath: engine.path, progress: { _ in },
                                      shouldStop: { true })
        XCTAssertEqual(outcome, .detached)
    }

    func testRestartIsTheUsersLaunchAgentAsArguments() {
        XCTAssertNil(Engine.restartCommand(service: "", uid: 501))
        let command = Engine.restartCommand(service: "com.zeltak.melodyd; rm -rf ~", uid: 501)
        XCTAssertEqual(command?.program, "/bin/launchctl")
        XCTAssertEqual(command?.arguments, ["kickstart", "-k", "gui/501/com.zeltak.melodyd; rm -rf ~"])
    }

    func testDefaultSocketIsTheRuntimeOrTemporaryDirectory() {
        XCTAssertEqual(Engine.defaultSocketPath(environment: ["XDG_RUNTIME_DIR": "/run/user/1"]),
                       "/run/user/1/melodyd.sock")
        XCTAssertTrue(Engine.defaultSocketPath(environment: [:]).hasSuffix("/melodyd.sock"))
    }
}

final class UpdateTests: XCTestCase {
    func testBuildNumbersCompareByPart() {
        XCTAssertLessThan(BuildNumber("1228.1")!, BuildNumber("1228.2")!)
        XCTAssertLessThan(BuildNumber("999.9")!, BuildNumber("1228.1")!)
        XCTAssertEqual(BuildNumber("1228")!, BuildNumber("1228.0")!)
        XCTAssertNil(BuildNumber("0.3.0-12-gabc"))
    }

    func testAReleaseNamesItsBuildAndDMG() throws {
        let json = """
        {"tag_name": "build-1230.4", "name": "Melody 0.3.0-300 (build 1230.4)",
         "assets": [{"name": "SHA256SUMS", "browser_download_url": "https://x/SHA256SUMS"},
                    {"name": "Melody-1230.4.dmg", "browser_download_url": "https://x/Melody-1230.4.dmg"}]}
        """
        let release = try XCTUnwrap(Release.parse(Data(json.utf8)))
        XCTAssertEqual(release.build, BuildNumber("1230.4"))
        XCTAssertEqual(release.dmg, URL(string: "https://x/Melody-1230.4.dmg"))
    }

    func testAReleaseThatIsNotOursIsIgnored() {
        XCTAssertNil(Release.parse(Data(#"{"tag_name": "v1.0", "assets": []}"#.utf8)))
        XCTAssertNil(Release.parse(Data(#"{"tag_name": "build-5", "assets": []}"#.utf8)))
    }

    func testTheEngineRunsFromTheBundleWithNoOptions() {
        let engine = LaunchAgents.engineDefinition(executable: "/Applications/Melody Engine.app/Contents/MacOS/melodyd",
                                                   logs: "/tmp/logs")
        XCTAssertEqual(engine["Label"] as? String, "org.melody.melodyd")
        XCTAssertEqual(engine["ProgramArguments"] as? [String],
                       ["/Applications/Melody Engine.app/Contents/MacOS/melodyd"])
        XCTAssertEqual((engine["KeepAlive"] as? [String: Bool])?["SuccessfulExit"], false)
        let app = LaunchAgents.appDefinition(executable: "/x/melody-engine", logs: "/tmp/logs")
        XCTAssertEqual(app["KeepAlive"] as? Bool, true)
        XCTAssertEqual(app["LimitLoadToSessionType"] as? String, "Aqua")
    }
}
