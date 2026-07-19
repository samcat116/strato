import Testing
import Foundation
@testable import StratoAgentCore

@Suite("WebSocketURLs Tests")
struct WebSocketURLsTests {

    @Test("Builds a dial URL from a bare base")
    func buildsDialURL() {
        let result = WebSocketURLs.appendingNameQueryParameter(
            to: "wss://control-plane:8080/agent/ws",
            name: "agent-1"
        )
        #expect(result == "wss://control-plane:8080/agent/ws?name=agent-1")
    }

    @Test("Dial URL builder replaces a stale name in the base")
    func buildReplacesExistingName() {
        let result = WebSocketURLs.appendingNameQueryParameter(
            to: "wss://cp:8080/agent/ws?name=old",
            name: "agent-2"
        )
        #expect(result == "wss://cp:8080/agent/ws?name=agent-2")
    }

    @Test("Dial URL builder preserves other query parameters")
    func buildPreservesOtherParameters() {
        let result = WebSocketURLs.appendingNameQueryParameter(
            to: "wss://cp.example.com/agent/ws?foo=bar",
            name: "node-a"
        )
        #expect(result == "wss://cp.example.com/agent/ws?foo=bar&name=node-a")
    }

    @Test("Names needing escaping are percent-encoded in the dial URL")
    func percentEncodesName() {
        let result = WebSocketURLs.appendingNameQueryParameter(
            to: "wss://cp:8080/agent/ws",
            name: "node one"
        )
        #expect(result == "wss://cp:8080/agent/ws?name=node%20one")
    }

    @Test("Round-trip: configured URL → dial URL → persisted bare URL")
    func roundTrip() {
        // The dialed URL carries only the agent name; authentication is the
        // SPIFFE X.509 SVID presented during the TLS handshake.
        let configured = "wss://cp.example.com/agent/ws"
        let dialed = WebSocketURLs.appendingNameQueryParameter(to: configured, name: "hv-01")
        #expect(dialed == "wss://cp.example.com/agent/ws?name=hv-01")

        // Persistence stores the fully bare control plane URL.
        let base = WebSocketURLs.removingQuery(from: dialed!)
        #expect(base == configured)
    }

    @Test("removingQuery leaves query-less URLs unchanged")
    func removingQueryNoQuery() {
        #expect(WebSocketURLs.removingQuery(from: "wss://cp:8080/agent/ws") == "wss://cp:8080/agent/ws")
    }
}
