import Foundation
import StratoShared
import Testing
@testable import App

@Suite("Loki batched payloads")
struct LokiBatchTests {
    @Test("Sandbox streams group by complete labels and preserve each stream's arrival order")
    func sandboxStreams() throws {
        let logs = [
            SandboxLogMessage(sandboxId: "a", stream: "stdout", message: "one"),
            SandboxLogMessage(sandboxId: "a", stream: "stderr", message: "error"),
            SandboxLogMessage(sandboxId: "b", stream: "stdout", message: "other"),
            SandboxLogMessage(sandboxId: "a", stream: "stdout", message: "two"),
        ]
        let batch = try LokiService.sandboxBatch(logs)
        #expect(batch.streams.count == 3)
        #expect(batch.streams[0].values.map { $0[1] } == ["one", "two"])
        #expect(batch.streams[1].values.map { $0[1] } == ["error"])
        #expect(batch.streams[2].values.map { $0[1] } == ["other"])
        #expect(batch.streams[0].stream["source"] == "workload")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(batch)) as! [String: Any]
        #expect((json["streams"] as! [[String: Any]]).count == 3)
    }

    @Test("VM level and operation remain part of stream identity")
    func vmStreams() throws {
        let logs = [
            VMLogMessage(vmId: "v", level: .info, source: .agent, eventType: .operation, message: "one"),
            VMLogMessage(vmId: "v", level: .error, source: .agent, eventType: .operation, message: "error"),
            VMLogMessage(vmId: "v", level: .info, source: .agent, eventType: .operation, message: "two"),
        ]
        let batch = try LokiService.vmBatch(logs)
        #expect(batch.streams.count == 2)
        #expect(batch.streams[0].values.map { $0[1] } == ["one", "two"])
        #expect(batch.streams[0].stream["operation"] == nil)
        #expect(try LokiService.vmBatch([]).streams.isEmpty)
    }
}
