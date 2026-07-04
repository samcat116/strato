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

    @Test("Builds a token-free dial URL from a bare base")
    func buildsDialURL() {
        let result = WebSocketURLs.appendingNameQueryParameter(
            to: "ws://control-plane:8080/agent/ws",
            name: "agent-1"
        )
        #expect(result == "ws://control-plane:8080/agent/ws?name=agent-1")
    }

    @Test("Dial URL builder replaces a stale name in the base")
    func buildReplacesExistingName() {
        let result = WebSocketURLs.appendingNameQueryParameter(
            to: "ws://cp:8080/agent/ws?name=old",
            name: "agent-2"
        )
        #expect(result == "ws://cp:8080/agent/ws?name=agent-2")
    }

    @Test("Round-trip: registration URL → persisted base → reconnect dial URL")
    func roundTrip() {
        // First join: the UI-provided URL carries token+name; the token is
        // extracted into the Authorization header, name stays in the URL.
        let original = "wss://cp.example.com/agent/ws?token=join-token&name=hv-01"
        let extracted = WebSocketURLs.extractingToken(from: original)
        #expect(extracted?.token == "join-token")
        #expect(extracted?.url == "wss://cp.example.com/agent/ws?name=hv-01")

        // Persistence stores the fully bare control plane URL.
        let base = WebSocketURLs.removingQuery(from: original)
        #expect(base == "wss://cp.example.com/agent/ws")

        // Restart: rebuild the token-free dial URL from the persisted state.
        let rebuilt = WebSocketURLs.appendingNameQueryParameter(to: base!, name: "hv-01")
        #expect(rebuilt == "wss://cp.example.com/agent/ws?name=hv-01")
    }

    @Test("removingQuery leaves query-less URLs unchanged")
    func removingQueryNoQuery() {
        #expect(WebSocketURLs.removingQuery(from: "ws://cp:8080/agent/ws") == "ws://cp:8080/agent/ws")
    }
}
