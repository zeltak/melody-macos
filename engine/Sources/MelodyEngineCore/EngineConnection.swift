// SPDX-License-Identifier: GPL-3.0-only
//
// One connection to melodyd's local socket. The engine speaks one JSON
// object per line: requests {"id","method","params"}, answers {"id","result"}
// or {"id","error"}, and events {"event","data"}. A local socket needs no
// password; this client never talks to an engine over the network.

import Foundation

public enum EngineError: Error, Equatable, CustomStringConvertible {
    case connect(String)
    case timeout
    case closed
    case malformed(String)
    case remote(String)

    public var description: String {
        switch self {
        case .connect(let reason): return "cannot reach melodyd: \(reason)"
        case .timeout: return "melodyd did not answer in time"
        case .closed: return "melodyd closed the connection"
        case .malformed(let reason): return "melodyd sent something unreadable: \(reason)"
        case .remote(let message): return message
        }
    }
}

public typealias Message = [String: Any]

public final class EngineConnection {
    private var descriptor: Int32
    private var buffer = Data()

    public init(socketPath: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.count < capacity else {
            throw EngineError.connect("socket path is too long: \(socketPath)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: path)
            raw[path.count] = 0
        }
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw EngineError.connect(String(cString: strerror(errno)))
        }
        // A vanished engine must not kill this process when it is written to.
        var one: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(descriptor)
            descriptor = -1
            throw EngineError.connect(reason)
        }
    }

    deinit { close() }

    public func close() {
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    public func send(_ message: Message) throws {
        guard descriptor >= 0 else { throw EngineError.closed }
        var line = try JSONSerialization.data(withJSONObject: message)
        line.append(0x0A)
        try line.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(descriptor, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw EngineError.closed
                }
                offset += written
            }
        }
    }

    /// The next message, or nil when none arrived within `timeout` seconds.
    public func receive(timeout: TimeInterval) throws -> Message? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if line.isEmpty { continue }
                guard let object = try? JSONSerialization.jsonObject(with: line),
                      let message = object as? Message
                else {
                    throw EngineError.malformed(String(decoding: line.prefix(200), as: UTF8.self))
                }
                return message
            }
            guard descriptor >= 0 else { throw EngineError.closed }
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { return nil }
            var watched = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&watched, 1, Int32(min(left, 3600) * 1000))
            if ready < 0 {
                if errno == EINTR { continue }
                throw EngineError.closed
            }
            if ready == 0 { return nil }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = Darwin.read(descriptor, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw EngineError.closed
            }
            if count == 0 { throw EngineError.closed }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }

    /// Sends a request and waits for its answer, passing events by.
    public func call(_ method: String, params: Message = [:], id: Int = 1,
                     timeout: TimeInterval) throws -> Any {
        try send(["id": id, "method": method, "params": params])
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let left = deadline.timeIntervalSinceNow
            guard left > 0, let message = try receive(timeout: left) else {
                throw EngineError.timeout
            }
            if let answer = try EngineConnection.answer(message, to: id) {
                return answer
            }
        }
    }

    /// The result when `message` answers request `id`; nil for anything else.
    static func answer(_ message: Message, to id: Int) throws -> Any? {
        guard (message["id"] as? NSNumber)?.intValue == id, message["event"] == nil else {
            return nil
        }
        if let failure = message["error"] as? Message {
            throw EngineError.remote(failure["message"] as? String ?? "melodyd refused the request")
        }
        return message["result"] ?? NSNull()
    }
}
