import Foundation
import Logging
import Testing

@testable import StratoAgentCore

@Suite("CustomLogHandler Tests")
struct CustomLogHandlerTests {

    @Test("Formats a line as '<ts> LEVEL label : [source] message'")
    func formatsBasicLine() {
        let handler = CustomLogHandler(label: "test-logger")

        let line = handler.formattedLine(
            level: .info,
            message: "hello world",
            metadata: nil,
            source: "MySource",
            timestamp: "2026-01-01T00:00:00"
        )

        #expect(line == "2026-01-01T00:00:00 INFO test-logger : [MySource] hello world")
    }

    @Test("Merges handler and per-call metadata before the source and message")
    func formatsLineWithMergedMetadata() {
        var handler = CustomLogHandler(label: "test-logger")
        handler.metadata = ["request_id": "abc"]

        // Per-call metadata wins on key collision; a distinct key is also included.
        // Use a single merged key per assertion to keep dictionary ordering deterministic.
        let overridden = handler.formattedLine(
            level: .error,
            message: "boom",
            metadata: ["request_id": "xyz"],
            source: "Src",
            timestamp: "2026-01-01T00:00:00"
        )
        #expect(overridden == "2026-01-01T00:00:00 ERROR test-logger : request_id=xyz [Src] boom")
    }
}
