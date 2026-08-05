import Foundation
import HTTPTypes
import Testing

@testable import StratoCLICore

/// The one piece of hand-written URL handling left in the CLI: splicing the
/// generated client's relative path onto the context's server URL.
@Suite("URLSessionClientTransport")
struct URLSessionClientTransportTests {
    private func request(path: String) -> HTTPRequest {
        HTTPRequest(method: .get, scheme: nil, authority: nil, path: path)
    }

    @Test("Joins the server URL with the operation's path and query")
    func testPlainServerURL() throws {
        let url = try URLSessionClientTransport.url(
            baseURL: URL(string: "https://strato.example.com")!,
            request: request(path: "/api/vms?limit=500"))
        #expect(url.absoluteString == "https://strato.example.com/api/vms?limit=500")
    }

    @Test("A server URL mounted under a path prefix keeps that prefix")
    func testPrefixedServerURL() throws {
        let url = try URLSessionClientTransport.url(
            baseURL: URL(string: "https://example.com/strato")!,
            request: request(path: "/api/vms"))
        #expect(url.absoluteString == "https://example.com/strato/api/vms")
    }

    @Test("A trailing slash on the server URL does not double up")
    func testTrailingSlash() throws {
        let url = try URLSessionClientTransport.url(
            baseURL: URL(string: "https://strato.example.com/")!,
            request: request(path: "/api/vms"))
        #expect(url.absoluteString == "https://strato.example.com/api/vms")
    }
}
