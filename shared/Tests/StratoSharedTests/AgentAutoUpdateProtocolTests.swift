import Foundation
import Testing

@testable import StratoShared

@Suite("Agent auto-update protocol")
struct AgentAutoUpdateProtocolTests {

    private static let update = DesiredAgentUpdate(
        targetVersion: "1.4.0",
        artifactURL: "https://releases.example/v1.4.0/strato-linux-arm64.tar.gz?sig=secret",
        sha256: String(repeating: "ab", count: 32),
        artifactKind: .tarball,
        tarballMember: "strato-agent"
    )

    @Test("DesiredStateMessage carries the desired agent update through the envelope")
    func desiredAgentUpdateRoundTrip() throws {
        let message = DesiredStateMessage(syncId: "sync-1", vms: [], desiredAgentUpdate: Self.update)
        let decoded = try throughEnvelope(message)

        let update = try #require(decoded.desiredAgentUpdate)
        #expect(update.targetVersion == "1.4.0")
        #expect(update.artifactURL == Self.update.artifactURL)
        #expect(update.sha256 == Self.update.sha256)
        #expect(update.artifactKind == .tarball)
        #expect(update.tarballMember == "strato-agent")
    }

    @Test("DesiredStateMessage from an older control plane decodes the update to nil")
    func desiredAgentUpdateBackwardCompatible() throws {
        // A pre-v7 control plane emits no `desiredAgentUpdate` key at all.
        // Nil means "no opinion" — never an instruction to downgrade — so
        // absence needs no version gating on the agent side.
        let legacy = """
            {"requestId":"r","timestamp":0,"syncId":"s","vms":[]}
            """
        let decoded = try decodeJSON(DesiredStateMessage.self, from: legacy)
        #expect(decoded.desiredAgentUpdate == nil)
        #expect(decoded.syncId == "s")
    }

    @Test("Redacted artifact URL strips the query string")
    func redactedURL() {
        #expect(!Self.update.redactedArtifactURL.contains("sig=secret"))
        #expect(Self.update.redactedArtifactURL.contains("strato-linux-arm64.tar.gz"))
    }

    @Test("ObservedStateReport carries the update status through the envelope")
    func observedUpdateStatusRoundTrip() throws {
        let report = ObservedStateReport(
            agentId: "agent-1",
            vms: [],
            resources: Fixtures.resources,
            agentUpdateStatus: ObservedAgentUpdateStatus(
                targetVersion: "1.4.0",
                disposition: ObservedAgentUpdateStatus.dispositionBlocked,
                reason: "2 Firecracker VM(s) are running and would be orphaned by a restart"
            )
        )
        let decoded = try throughEnvelope(report)

        let status = try #require(decoded.agentUpdateStatus)
        #expect(status.targetVersion == "1.4.0")
        #expect(status.disposition == ObservedAgentUpdateStatus.dispositionBlocked)
        #expect(status.reason.contains("Firecracker"))
    }

    @Test("ObservedStateReport from an older agent decodes the update status to nil")
    func observedUpdateStatusBackwardCompatible() throws {
        let legacy = """
            {"requestId":"r","timestamp":0,"agentId":"agent-1","vms":[],
             "resources":{"totalCPU":8,"availableCPU":4,"totalMemory":16,"availableMemory":8,
                          "totalDisk":100,"availableDisk":50}}
            """
        let decoded = try decodeJSON(ObservedStateReport.self, from: legacy)
        #expect(decoded.agentUpdateStatus == nil)
    }

    @Test("Nil update fields stay off the wire; present ones reach it")
    func encodedKeysReflectPresence() throws {
        let bare = DesiredStateMessage(syncId: "s", vms: [])
        let bareKeys = try encodedKeys(bare)
        #expect(!bareKeys.contains("desiredAgentUpdate"))

        let carrying = DesiredStateMessage(syncId: "s", vms: [], desiredAgentUpdate: Self.update)
        let carryingKeys = try encodedKeys(carrying)
        #expect(carryingKeys.contains("desiredAgentUpdate"))

        let bareReport = ObservedStateReport(agentId: "a", vms: [], resources: Fixtures.resources)
        let bareReportKeys = try encodedKeys(bareReport)
        #expect(!bareReportKeys.contains("agentUpdateStatus"))
    }

    @Test("Desired-agent-update support is keyed on protocol version 7")
    func desiredAgentUpdateVersionGate() {
        // A pre-v7 agent decodes the sync but never acts on the field, so the
        // rollout must not assign an update to one — its health budget would
        // expire against silence and halt the rollout.
        #expect(!WireProtocol.supportsDesiredAgentUpdate(6))
        #expect(WireProtocol.supportsDesiredAgentUpdate(7))
        #expect(WireProtocol.supportsDesiredAgentUpdate(WireProtocol.currentVersion))
    }
}
