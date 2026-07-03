@testable import App
import Testing

@Suite("Agent Controller Tests")
struct AgentControllerTests {

    @Test("sanitizedHost passes through a bare host")
    func bareHost() {
        #expect(AgentController.sanitizedHost("cp.example.com") == "cp.example.com")
    }

    @Test("sanitizedHost keeps a port")
    func hostWithPort() {
        #expect(AgentController.sanitizedHost("localhost:8080") == "localhost:8080")
    }

    @Test("sanitizedHost strips a scheme")
    func stripsScheme() {
        #expect(AgentController.sanitizedHost("https://cp.example.com") == "cp.example.com")
    }

    @Test("sanitizedHost strips a trailing path and slash")
    func stripsPath() {
        #expect(AgentController.sanitizedHost("https://cp.example.com/") == "cp.example.com")
        #expect(AgentController.sanitizedHost("cp.example.com/strato") == "cp.example.com")
    }

    @Test("sanitizedHost trims whitespace")
    func trimsWhitespace() {
        #expect(AgentController.sanitizedHost(" cp.example.com \n") == "cp.example.com")
    }
}
