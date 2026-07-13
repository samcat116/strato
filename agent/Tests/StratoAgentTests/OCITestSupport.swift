import Crypto
import Foundation

@testable import StratoAgentCore

// Shared fixtures for the OCI pipeline tests: a tar writer (so layer content
// is crafted byte-exactly, independent of any host tar flavor) and a scripted
// HTTP transport that drives the registry client without a network.

// MARK: - Tar construction

/// Builds tar archives in memory for tests.
struct TarTestBuilder {
    private var data = Data()

    mutating func addFile(
        _ name: String, content: Data, mode: UInt16 = 0o644, uid: Int = 0, gid: Int = 0
    ) {
        appendHeader(
            name: name, mode: mode, uid: uid, gid: gid, size: content.count, typeFlag: UInt8(ascii: "0"))
        appendContent(content)
    }

    mutating func addDirectory(_ name: String, mode: UInt16 = 0o755, uid: Int = 0, gid: Int = 0) {
        appendHeader(name: name, mode: mode, uid: uid, gid: gid, size: 0, typeFlag: UInt8(ascii: "5"))
    }

    mutating func addSymlink(_ name: String, target: String) {
        appendHeader(name: name, mode: 0o777, uid: 0, gid: 0, size: 0, typeFlag: UInt8(ascii: "2"), linkName: target)
    }

    mutating func addHardlink(_ name: String, target: String) {
        appendHeader(name: name, mode: 0o644, uid: 0, gid: 0, size: 0, typeFlag: UInt8(ascii: "1"), linkName: target)
    }

    /// PAX extended header applying `records` to the next entry.
    mutating func addPax(_ records: [String: String]) {
        var body = Data()
        for (key, value) in records.sorted(by: { $0.key < $1.key }) {
            // "<len> <key>=<value>\n" where len counts the whole record.
            let payload = " \(key)=\(value)\n"
            var length = payload.utf8.count + 1
            while "\(length)".utf8.count + payload.utf8.count != length {
                length = "\(length)".utf8.count + payload.utf8.count
            }
            body.append(Data("\(length)\(payload)".utf8))
        }
        appendHeader(
            name: "./PaxHeaders/next", mode: 0o644, uid: 0, gid: 0, size: body.count,
            typeFlag: UInt8(ascii: "x"))
        appendContent(body)
    }

    /// GNU `L` long-name entry applying `name` to the next entry.
    mutating func addGNULongName(_ name: String) {
        let body = Data(name.utf8) + Data([0])
        appendHeader(
            name: "././@LongLink", mode: 0o644, uid: 0, gid: 0, size: body.count,
            typeFlag: UInt8(ascii: "L"))
        appendContent(body)
    }

    /// An entry with an arbitrary type flag (fifo, device, unknown).
    mutating func addSpecial(_ name: String, typeFlag: UInt8, mode: UInt16 = 0o644) {
        appendHeader(name: name, mode: mode, uid: 0, gid: 0, size: 0, typeFlag: typeFlag)
    }

    func finish() -> Data {
        data + Data(count: 1024)
    }

    private mutating func appendHeader(
        name: String, mode: UInt16, uid: Int, gid: Int, size: Int, typeFlag: UInt8,
        linkName: String = ""
    ) {
        var block = [UInt8](repeating: 0, count: 512)

        func put(_ text: String, _ offset: Int, _ length: Int) {
            for (index, byte) in text.utf8.prefix(length).enumerated() {
                block[offset + index] = byte
            }
        }

        put(name, 0, 100)
        put(String(format: "%07o", mode), 100, 8)
        put(String(format: "%07o", uid), 108, 8)
        put(String(format: "%07o", gid), 116, 8)
        put(String(format: "%011o", size), 124, 12)
        put(String(format: "%011o", 0), 136, 12)  // mtime
        block[156] = typeFlag
        put(linkName, 157, 100)
        put("ustar", 257, 6)
        put("00", 263, 2)

        // Checksum: header bytes with the checksum field as spaces.
        for index in 148..<156 { block[index] = UInt8(ascii: " ") }
        let sum = block.reduce(0) { $0 + Int($1) }
        put(String(format: "%06o", sum), 148, 7)
        block[155] = UInt8(ascii: " ")

        data.append(contentsOf: block)
    }

    private mutating func appendContent(_ content: Data) {
        data.append(content)
        let padding = (512 - content.count % 512) % 512
        data.append(Data(count: padding))
    }
}

// MARK: - Scripted transport

/// An `OCIHTTPTransport` serving canned responses keyed by exact URL, and
/// recording every request for assertions. When a URL's queue holds several
/// responses they are consumed in order, with the last one repeating.
actor MockOCITransport: OCIHTTPTransport {
    struct Response {
        let status: Int
        let headers: [String: String]
        let body: Data

        init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
            self.status = status
            self.headers = headers
            self.body = body
        }
    }

    struct RecordedRequest {
        let method: String
        let url: String
        let headers: [String: String]
    }

    private var routes: [String: [Response]] = [:]
    private(set) var requests: [RecordedRequest] = []

    func script(_ url: String, _ responses: Response...) {
        routes[url] = responses
    }

    func requests(to url: String) -> [RecordedRequest] {
        requests.filter { $0.url == url }
    }

    func execute(_ request: OCIHTTPRequest) async throws -> OCIHTTPResponse {
        let response = try respond(to: request)
        return OCIHTTPResponse(statusCode: response.status, headers: response.headers, body: response.body)
    }

    func download(_ request: OCIHTTPRequest, to destinationPath: String) async throws
        -> (statusCode: Int, headers: [String: String])
    {
        let response = try respond(to: request)
        try response.body.write(to: URL(fileURLWithPath: destinationPath))
        var headers: [String: String] = [:]
        for (name, value) in response.headers {
            headers[name.lowercased()] = value
        }
        return (response.status, headers)
    }

    private func respond(to request: OCIHTTPRequest) throws -> Response {
        requests.append(
            RecordedRequest(
                method: request.method, url: request.url.absoluteString, headers: request.headers))
        guard var queue = routes[request.url.absoluteString], !queue.isEmpty else {
            throw MockTransportError.unscripted(request.url.absoluteString)
        }
        let response = queue.count > 1 ? queue.removeFirst() : queue[0]
        routes[request.url.absoluteString] = queue
        return response
    }

    enum MockTransportError: Error, CustomStringConvertible {
        case unscripted(String)

        var description: String {
            switch self {
            case .unscripted(let url): return "no scripted response for \(url)"
            }
        }
    }
}

// MARK: - Digest helpers

func testSHA256Digest(of data: Data) -> String {
    "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
