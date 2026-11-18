import Foundation
import Darwin
import ClipboardCore

enum ControlError: Error { case failed, alreadyRunning, unavailable, tooLarge }

struct ControlRequest: Codable, Sendable {
    var command: String
    var value: String?
    var configuration: Configuration?
}
struct ControlResponse: Codable, Sendable {
    var ok: Bool
    var message: String
    var pipeline: PipelineStatus?
    var clipboardAccess: String?
    var hotkeyRegistered: Bool?
    var hotkeyError: Int32?
    var outputHotkeyRegistered: Bool?
    var outputAccess: Bool?
    var credentialAvailable: Bool?
    var configuration: Configuration?
    var windowCount: Int?
    var activationPolicy: String?
    var loginStatus: String?
    var pid: Int32?
}

enum SocketIO {
    static let maximumBytes = 65_536
    static func newSocket() throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError.failed }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fd
    }
    static func withAddress<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(AppPaths.socket.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw ControlError.failed }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in destination.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
    static func send<T: Encodable>(_ value: T, fd: Int32) throws {
        var data = try JSONEncoder().encode(value)
        guard data.count < maximumBytes else { throw ControlError.tooLarge }
        data.append(10)
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.send(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw ControlError.failed }
                offset += written
            }
        }
    }
    static func receive<T: Decodable>(_ type: T.Type, fd: Int32) throws -> T {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < maximumBytes {
            let count = Darwin.recv(fd, &buffer, buffer.count, 0)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw ControlError.failed }
            if let newline = buffer[..<count].firstIndex(of: 10) {
                data.append(contentsOf: buffer[..<newline])
                guard data.count < maximumBytes else { throw ControlError.tooLarge }
                return try JSONDecoder().decode(type, from: data)
            }
            data.append(contentsOf: buffer[..<count])
        }
        throw ControlError.tooLarge
    }
    static func client(_ request: ControlRequest) throws -> ControlResponse {
        let fd = try newSocket(); defer { close(fd) }
        let connected = try withAddress { Darwin.connect(fd, $0, $1) }
        guard connected == 0 else { throw ControlError.unavailable }
        var uid: uid_t = 0; var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw ControlError.failed }
        try send(request, fd: fd)
        return try receive(ControlResponse.self, fd: fd)
    }
}

final class ControlServer: @unchecked Sendable {
    private let fd: Int32
    private let queue = DispatchQueue(label: "com.bear.silentclipboard.control", qos: .utility)
    private let source: DispatchSourceRead
    init(handler: @escaping @MainActor @Sendable (ControlRequest) -> ControlResponse) throws {
        fd = try SocketIO.newSocket()
        let listener = fd
        unlink(AppPaths.socket)
        let bound = try SocketIO.withAddress { Darwin.bind(listener, $0, $1) }
        guard bound == 0, chmod(AppPaths.socket, 0o600) == 0, listen(fd, 8) == 0 else {
            close(fd); throw ControlError.failed
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return }
            var uid: uid_t = 0; var gid: gid_t = 0
            guard getpeereid(connection, &uid, &gid) == 0, uid == getuid() else { close(connection); return }
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var noSigPipe: Int32 = 1
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(connection, F_SETFL, 0)
            _ = fcntl(connection, F_SETFD, FD_CLOEXEC)
            do {
                let request = try SocketIO.receive(ControlRequest.self, fd: connection)
                Task { @MainActor in
                    let reply = handler(request)
                    // Move socket writes off the event/hotkey actor.
                    DispatchQueue.global(qos: .utility).async {
                        try? SocketIO.send(reply, fd: connection)
                        close(connection)
                    }
                }
            } catch { close(connection) }
        }
        source.setCancelHandler { close(listener) }
        source.resume()
    }
    deinit { source.cancel(); unlink(AppPaths.socket) }
}
