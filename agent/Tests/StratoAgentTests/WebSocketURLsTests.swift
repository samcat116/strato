import Testing
import Foundation
@testable import StratoAgentCore

@Suite("WebSocketURLs Tests")
struct WebSocketURLsTests {

    @Test("Replaces the token query parameter")
    func replacesToken() {
        let url = "ws://control-plane:8080/agent/ws?token=old-token&name=agent-1"
        let result = WebSocketURLs.replacingTokenQueryParameter(in: url, with: "new-token")
        #expect(result == "ws://control-plane:8080/agent/ws?token=new-token&name=agent-1")
    }

    @Test("Preserves other query parameters and their order")
    func preservesOtherParameters() {
        let url = "wss://cp.example.com/agent/ws?name=node-a&token=abc123"
        let result = WebSocketURLs.replacingTokenQueryParameter(in: url, with: "xyz789")
        #expect(result == "wss://cp.example.com/agent/ws?name=node-a&token=xyz789")
    }

    @Test("Returns nil when the URL has no token parameter")
    func nilWithoutToken() {
        let url = "wss://cp.example.com/agent/ws?name=node-a"
        #expect(WebSocketURLs.replacingTokenQueryParameter(in: url, with: "xyz") == nil)
    }

    @Test("Returns nil when the URL has no query at all")
    func nilWithoutQuery() {
        #expect(WebSocketURLs.replacingTokenQueryParameter(in: "ws://cp:8080/agent/ws", with: "xyz") == nil)
    }

    @Test("Percent-encoded agent names survive the rewrite")
    func percentEncodedNamePreserved() {
        let url = "ws://cp:8080/agent/ws?token=old&name=node%20one"
        let result = WebSocketURLs.replacingTokenQueryParameter(in: url, with: "new")
        #expect(result == "ws://cp:8080/agent/ws?token=new&name=node%20one")
    }
}
