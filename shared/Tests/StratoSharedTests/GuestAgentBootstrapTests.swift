import Foundation
import Testing
@testable import StratoShared

@Suite("Guest-agent bootstrap artifact installation")
struct GuestAgentBootstrapTests {
    @Test func executesInstallerFailuresAndArchitectureSelection() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("strato-bootstrap-\(UUID()).sh")
        defer { try? FileManager.default.removeItem(at: script) }
        try GuestAgentBootstrap.installScript().write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "python3", root.appendingPathComponent("scripts/test-guest-agent-bootstrap.py").path, script.path,
        ]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test func optionalBootstrapAndObservationDecodeForOlderPeers() throws {
        let metadata = InstanceMetadata(instanceId: UUID(), projectId: UUID(), serviceEnabled: true)
        let data = try JSONEncoder().encode(metadata)
        #expect(try JSONDecoder().decode(InstanceMetadata.self, from: data).guestAgentRelease == nil)
        let observation = ObservedVMState(vmId: UUID(), status: .running, observedGeneration: 1)
        #expect(
            try JSONDecoder().decode(ObservedVMState.self, from: JSONEncoder().encode(observation))
                .guestAgentObservation == nil)
    }
}
