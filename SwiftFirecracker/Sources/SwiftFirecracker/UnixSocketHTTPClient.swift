import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Logging

/// HTTP client that communicates over a Unix domain socket
/// Used to interact with the Firecracker API
public actor UnixSocketHTTPClient {
    private let socketPath: String
    private let logger: Logger
    private var fileHandle: FileHandle?

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
        let socket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else {
            throw FirecrackerError.connectionFailed("Failed to create socket: \(errno)")
        }

        // Connect to Unix socket
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
                _ = strcpy(sunPath.pointer(to: \.0)!, ptr)
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(socket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard connectResult == 0 else {
            close(socket)
            throw FirecrackerError.connectionFailed("Failed to connect: \(errno)")
        }

        self.fileHandle = FileHandle(fileDescriptor: socket, closeOnDealloc: true)
        logger.info("Connected to Firecracker socket", metadata: ["path": "\(socketPath)"])
    }

    /// Disconnects from the socket
    public func disconnect() {
        fileHandle = nil
        logger.debug("Disconnected from socket")
    }

    /// Sends an HTTP request and returns the response
    public func request(
        method: HTTPMethod,
        path: String,
        body: Data? = nil
    ) async throws -> HTTPResponse {
        guard let handle = fileHandle else {
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

        try handle.write(contentsOf: requestData)

        // Read response
        let response = try await readHTTPResponse(from: handle)

        logger.debug("Received response", metadata: [
            "statusCode": "\(response.statusCode)",
            "bodySize": "\(response.body?.count ?? 0)"
        ])

        return response
    }

    /// Reads an HTTP response from the socket
    private func readHTTPResponse(from handle: FileHandle) async throws -> HTTPResponse {
        var responseData = Data()
        var headerComplete = false
        var contentLength = 0

        // Read response in chunks
        while true {
            let chunk = try handle.read(upToCount: 4096) ?? Data()
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
