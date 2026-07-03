import Testing
import Foundation
@testable import StratoAgentCore

@Suite("WebSocketURLs Tests")
struct WebSocketURLsTests {

    @Test("Extracts the token and strips it from the URL")
    func extractsToken() {
        let url = "ws://control-plane:8080/agent/ws?token=abc123&name=agent-1"
        let result = WebSocketURLs.extractingToken(from: url)
        #expect(result?.token == "abc123")
        #expect(result?.url == "ws://control-plane:8080/agent/ws?name=agent-1")
    }

    @Test("Preserves other query parameters and their order")
    func preservesOtherParameters() {
        let url = "wss://cp.example.com/agent/ws?name=node-a&token=abc123&foo=bar"
        let result = WebSocketURLs.extractingToken(from: url)
        #expect(result?.token == "abc123")
        #expect(result?.url == "wss://cp.example.com/agent/ws?name=node-a&foo=bar")
    }

    @Test("Drops the query entirely when token is the only parameter")
    func dropsQueryWhenTokenOnly() {
        let url = "ws://cp:8080/agent/ws?token=abc123"
        let result = WebSocketURLs.extractingToken(from: url)
        #expect(result?.token == "abc123")
        #expect(result?.url == "ws://cp:8080/agent/ws")
    }

    @Test("Returns nil when the URL has no token parameter")
    func nilWithoutToken() {
        let url = "wss://cp.example.com/agent/ws?name=node-a"
        #expect(WebSocketURLs.extractingToken(from: url) == nil)
    }

    @Test("Returns nil when the URL has no query at all")
    func nilWithoutQuery() {
        #expect(WebSocketURLs.extractingToken(from: "ws://cp:8080/agent/ws") == nil)
    }

    @Test("Percent-encoded agent names survive the extraction")
    func percentEncodedNamePreserved() {
        let url = "ws://cp:8080/agent/ws?token=abc123&name=node%20one"
        let result = WebSocketURLs.extractingToken(from: url)
        #expect(result?.token == "abc123")
        #expect(result?.url == "ws://cp:8080/agent/ws?name=node%20one")
    }
}
