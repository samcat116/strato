import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Logging

#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// HTTP client that communicates over a Unix domain socket
/// Used to interact with the Firecracker API
public actor UnixSocketHTTPClient {
    private let socketPath: String
    private let logger: Logger
    private var socketFD: Int32?

    public init(socketPath: String, logger: Logger = Logger(label: "SwiftFirecracker.HTTPClient")) {
        self.socketPath = socketPath
        self.logger = logger
    }

    /// Connects to the Unix socket
    public func connect() async throws {
        logger.debug("Connecting to socket", metadata: ["path": "\(socketPath)"])

        // Verify socket exists
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw FirecrackerError.invalidSocketPath(socketPath)
        }

        // Create socket
        #if os(Linux)
        let sock = Glibc.socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let sock = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard sock >= 0 else {
            throw FirecrackerError.connectionFailed("Failed to create socket: \(errno)")
        }

        // Connect to Unix socket
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        // sun_path is a fixed-size C buffer (108 bytes on Linux, 104 on macOS).
        // Guard against overflow before copying — a path that doesn't fit, with
        // room for the trailing NUL, cannot be represented.
        let sunPathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        let pathBytes = socketPath.utf8
        guard pathBytes.count < sunPathCapacity else {
            close(sock)
            throw FirecrackerError.invalidSocketPath(
                "Socket path is \(pathBytes.count) bytes; must be < \(sunPathCapacity): \(socketPath)"
            )
        }

        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
                sunPath.withMemoryRebound(to: CChar.self, capacity: sunPathCapacity) { dest in
                    // Bounded copy: strncpy never writes past `sunPathCapacity - 1`,
                    // and the guard above guarantees the source fits with a NUL.
                    strncpy(dest, ptr, sunPathCapacity - 1)
                    dest[sunPathCapacity - 1] = 0
                }
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                #if os(Linux)
                Glibc.connect(sock, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                #else
                Darwin.connect(sock, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                #endif
            }
        }

        guard connectResult == 0 else {
            close(sock)
            throw FirecrackerError.connectionFailed("Failed to connect: \(errno)")
        }

        self.socketFD = sock
        logger.info("Connected to Firecracker socket", metadata: ["path": "\(socketPath)"])
    }

    /// Disconnects from the socket
    public func disconnect() {
        if let fd = socketFD {
            close(fd)
            socketFD = nil
        }
        logger.debug("Disconnected from socket")
    }

    /// Sends an HTTP request and returns the response
    public func request(
        method: HTTPMethod,
        path: String,
        body: Data? = nil
    ) async throws -> HTTPResponse {
        guard let fd = socketFD else {
            throw FirecrackerError.notConnected
        }

        // Build HTTP request
        var request = "\(method.rawValue) \(path) HTTP/1.1\r\n"
        request += "Host: localhost\r\n"
        request += "Accept: application/json\r\n"

        if let body = body {
            request += "Content-Type: application/json\r\n"
            request += "Content-Length: \(body.count)\r\n"
        }

        request += "\r\n"

        logger.debug("Sending request", metadata: [
            "method": "\(method.rawValue)",
            "path": "\(path)",
            "bodySize": "\(body?.count ?? 0)"
        ])

        // Send request
        var requestData = Data(request.utf8)
        if let body = body {
            requestData.append(body)
        }

        try await SocketIO.writeAll(fd: fd, data: requestData)

        // Read response
        let response = try await readHTTPResponse(fd: fd)

        logger.debug("Received response", metadata: [
            "statusCode": "\(response.statusCode)",
            "bodySize": "\(response.body?.count ?? 0)"
        ])

        return response
    }

    /// Reads an HTTP response from the socket
    private func readHTTPResponse(fd: Int32) async throws -> HTTPResponse {
        var responseData = Data()
        var headerComplete = false
        var contentLength = 0

        // Read response in chunks
        while true {
            let chunk = try await SocketIO.read(fd: fd, maxLength: 4096)
            if chunk.isEmpty {
                break
            }
            responseData.append(chunk)

            // Check if we've received complete headers
            if !headerComplete {
                if let headerEnd = responseData.range(of: Data("\r\n\r\n".utf8)) {
                    headerComplete = true
                    let headerData = responseData[..<headerEnd.lowerBound]
                    if let headerString = String(data: headerData, encoding: .utf8) {
                        contentLength = parseContentLength(from: headerString)
                    }

                    let bodyStart = headerEnd.upperBound
                    let currentBodyLength = responseData.count - bodyStart
                    if currentBodyLength >= contentLength {
                        break
                    }
                }
            } else {
                // Check if we have the full body
                if let headerEnd = responseData.range(of: Data("\r\n\r\n".utf8)) {
                    let bodyStart = headerEnd.upperBound
                    let currentBodyLength = responseData.count - bodyStart
                    if currentBodyLength >= contentLength {
                        break
                    }
                }
            }
        }

        return try parseHTTPResponse(from: responseData)
    }

    /// Parses Content-Length from headers
    private func parseContentLength(from headers: String) -> Int {
        let lines = headers.components(separatedBy: "\r\n")
        for line in lines {
            if line.lowercased().hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                return Int(value) ?? 0
            }
        }
        return 0
    }

    /// Parses HTTP response from raw data
    private func parseHTTPResponse(from data: Data) throws -> HTTPResponse {
        guard let string = String(data: data, encoding: .utf8) else {
            throw FirecrackerError.deserializationError("Invalid UTF-8 in response")
        }

        // Split headers and body
        let parts = string.components(separatedBy: "\r\n\r\n")
        guard parts.count >= 1 else {
            throw FirecrackerError.deserializationError("Invalid HTTP response format")
        }

        let headerSection = parts[0]
        let bodySection = parts.count > 1 ? parts.dropFirst().joined(separator: "\r\n\r\n") : nil

        // Parse status line
        let headerLines = headerSection.components(separatedBy: "\r\n")
        guard let statusLine = headerLines.first else {
            throw FirecrackerError.deserializationError("Missing status line")
        }

        let statusParts = statusLine.components(separatedBy: " ")
        guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else {
            throw FirecrackerError.deserializationError("Invalid status line: \(statusLine)")
        }

        // Parse headers
        var headers: [String: String] = [:]
        for line in headerLines.dropFirst() {
            if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                headers[key.lowercased()] = value
            }
        }

        let body = bodySection.flatMap { $0.isEmpty ? nil : Data($0.utf8) }

        return HTTPResponse(statusCode: statusCode, headers: headers, body: body)
    }
}

/// Blocking socket reads/writes moved off the Swift concurrency cooperative
/// thread pool.
///
/// Raw `read(2)`/`write(2)` on a Unix socket block the calling thread until data
/// is available or drained. Invoking them directly in an `async` method would tie
/// up a cooperative-pool thread; instead each call is dispatched to a global queue
/// and its result delivered through a continuation, so the awaiting task suspends
/// rather than blocks. The socket file descriptor is a plain `Int32`, so it crosses
/// the concurrency boundary without a `Sendable` concern.
private enum SocketIO {
    /// Writes the entire buffer, looping over short writes and retrying `EINTR`.
    static func writeAll(fd: Int32, data: Data) async throws {
        try await runBlocking {
            try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let written = write(fd, base + offset, raw.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw FirecrackerError.connectionFailed("Socket write failed: \(errno)")
                    }
                    if written == 0 {
                        throw FirecrackerError.connectionFailed("Socket write returned 0 (connection closed)")
                    }
                    offset += written
                }
            }
        }
    }

    /// Reads up to `maxLength` bytes; an empty result signals EOF.
    static func read(fd: Int32, maxLength: Int) async throws -> Data {
        try await runBlocking {
            var buffer = [UInt8](repeating: 0, count: maxLength)
            while true {
                let count = buffer.withUnsafeMutableBytes { ptr in
                    #if os(Linux)
                    Glibc.read(fd, ptr.baseAddress, maxLength)
                    #else
                    Darwin.read(fd, ptr.baseAddress, maxLength)
                    #endif
                }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw FirecrackerError.connectionFailed("Socket read failed: \(errno)")
                }
                return Data(buffer.prefix(count))
            }
        }
    }

    private static func runBlocking<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// HTTP methods supported by Firecracker API
public enum HTTPMethod: String, Sendable {
    case GET
    case PUT
    case PATCH
    case DELETE
}

/// HTTP response from Firecracker
public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data?

    public var isSuccess: Bool {
        statusCode >= 200 && statusCode < 300
    }
}
