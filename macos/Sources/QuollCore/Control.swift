import Foundation
import Darwin

public struct ControlFault: Codable, Sendable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct ControlRequest: Codable, Sendable {
    public var id: String?
    public var command: String
    public var query: String?
    public var limit: Int?
    public var offset: Int?
    public var sort: SortKey?
    public var ascending: Bool?
    public var path: String?
    public var paths: [String]?
    public var format: String?

    public init(
        id: String? = nil,
        command: String,
        query: String? = nil,
        limit: Int? = nil,
        offset: Int? = nil,
        sort: SortKey? = nil,
        ascending: Bool? = nil,
        path: String? = nil,
        paths: [String]? = nil,
        format: String? = nil
    ) {
        self.id = id
        self.command = command
        self.query = query
        self.limit = limit
        self.offset = offset
        self.sort = sort
        self.ascending = ascending
        self.path = path
        self.paths = paths
        self.format = format
    }
}

public struct ControlReply: Codable, Sendable {
    public var id: String?
    public var ok: Bool
    public var error: ControlFault?
    public var count: Int?
    public var total: Int?
    public var tookMS: Double?
    public var results: [FileEntry]?
    public var status: CatalogStatus?
    public var warnings: [String]?
    public var message: String?
    public var data: String?

    public init(
        id: String? = nil,
        ok: Bool = true,
        error: ControlFault? = nil,
        count: Int? = nil,
        total: Int? = nil,
        tookMS: Double? = nil,
        results: [FileEntry]? = nil,
        status: CatalogStatus? = nil,
        warnings: [String]? = nil,
        message: String? = nil,
        data: String? = nil
    ) {
        self.id = id
        self.ok = ok
        self.error = error
        self.count = count
        self.total = total
        self.tookMS = tookMS
        self.results = results
        self.status = status
        self.warnings = warnings
        self.message = message
        self.data = data
    }

    public static func failure(_ code: String, _ message: String, id: String? = nil) -> ControlReply {
        ControlReply(id: id, ok: false, error: ControlFault(code: code, message: message))
    }
}

public final class ControlServer {
    public typealias Handler = (ControlRequest) -> ControlReply

    private let controlPath: String
    private let handler: Handler
    private let acceptQueue = DispatchQueue(label: "quoll.control.accept")
    private let clientQueue = DispatchQueue(label: "quoll.control.clients", attributes: .concurrent)
    private let lock = NSLock()
    private var serverFD: Int32 = -1
    private var running = false

    public init(controlPath: String, handler: @escaping Handler) {
        self.controlPath = controlPath
        self.handler = handler
    }

    public func start() throws {
        guard !running else { return }

        let directory = (controlPath as NSString).deletingLastPathComponent
        if !directory.isEmpty {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        unlink(controlPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(.ENFILE)
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(controlPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) - 1 else {
            close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 104) { destination in
                for (index, byte) in pathBytes.enumerated() {
                    destination[index] = CChar(bitPattern: byte)
                }
                destination[pathBytes.count] = 0
            }
        }

        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, length)
            }
        }
        guard bound == 0 else {
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        chmod(controlPath, 0o600)

        guard listen(fd, 32) == 0 else {
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        lock.lock()
        serverFD = fd
        running = true
        lock.unlock()

        acceptQueue.async { [weak self] in
            self?.acceptLoop(fd: fd)
        }
    }

    public func stop() {
        lock.lock()
        guard running else {
            lock.unlock()
            return
        }
        running = false
        let fd = serverFD
        serverFD = -1
        lock.unlock()

        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        unlink(controlPath)
    }

    private func acceptLoop(fd: Int32) {
        while true {
            lock.lock()
            let alive = running
            lock.unlock()
            if !alive { break }

            var clientAddress = sockaddr_un()
            var length = socklen_t(MemoryLayout<sockaddr_un>.size)
            let client = withUnsafeMutablePointer(to: &clientAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    accept(fd, sockaddrPointer, &length)
                }
            }
            if client < 0 {
                if errno == EINTR { continue }
                break
            }

            clientQueue.async { [weak self] in
                self?.handle(client: client)
            }
        }
    }

    private func handle(client: Int32) {
        defer { close(client) }

        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        guard let requestData = readLineData(from: client), requestData.count <= 1_048_576 else {
            _ = writeAll(client, Data("{\"ok\":false,\"error\":{\"code\":\"bad_request\",\"message\":\"request too large or unreadable\"}}\n".utf8))
            return
        }

        let decoder = JSONDecoder()
        let request: ControlRequest
        do {
            request = try decoder.decode(ControlRequest.self, from: requestData)
        } catch {
            let response = ControlReply.failure("bad_request", "invalid JSON: \(error.localizedDescription)")
            write(response, to: client)
            return
        }

        let response = handler(request)
        write(response, to: client)
    }

    private func write(_ response: ControlReply, to client: Int32) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var data = try? encoder.encode(response) else { return }
        data.append(0x0A)
        _ = writeAll(client, data)
    }

    private func readLineData(from fd: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while data.count <= 1_048_576 {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 { break }
            data.append(buffer, count: count)
            if data.contains(0x0A) { break }
        }
        if let newline = data.firstIndex(of: 0x0A) {
            data = data.prefix(upTo: newline)
        }
        return data.isEmpty ? nil : data
    }

    private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return true }
            var written = 0
            while written < data.count {
                let count = Darwin.write(fd, base.advanced(by: written), data.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                written += count
            }
            return true
        }
    }
}

public struct ControlClient {
    public let controlPath: String

    public init(controlPath: String) {
        self.controlPath = controlPath
    }

    public func send(_ request: ControlRequest) throws -> ControlReply {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.ENFILE) }
        defer { close(fd) }

        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(controlPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) - 1 else {
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 104) { destination in
                for (index, byte) in pathBytes.enumerated() {
                    destination[index] = CChar(bitPattern: byte)
                }
                destination[pathBytes.count] = 0
            }
        }

        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, length)
            }
        }
        guard connected == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(request)
        data.append(0x0A)

        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var written = 0
            while written < data.count {
                let count = Darwin.write(fd, base.advanced(by: written), data.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                written += count
            }
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while response.count <= 64 * 1_048_576 {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 { break }
            response.append(buffer, count: count)
            if response.contains(0x0A) { break }
        }
        if let newline = response.firstIndex(of: 0x0A) {
            response = response.prefix(upTo: newline)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ControlReply.self, from: response)
    }

    public func isAvailable() -> Bool {
        do {
            let response = try send(ControlRequest(command: "ping"))
            return response.ok
        } catch {
            return false
        }
    }
}
