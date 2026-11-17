import Foundation
import Testing

import StratoShared

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

        try #require(decoded.hasDesiredAgentUpdate)
        let update = decoded.desiredAgentUpdate
        #expect(update.targetVersion == "1.4.0")
        #expect(update.artifactURL == Self.update.artifactURL)
        #expect(update.sha256 == Self.update.sha256)
        #expect(update.artifactKind == .tarball)
        #expect(update.tarballMember == "strato-agent")
    }

    @Test("DesiredStateMessage without an update opinion decodes the update to nil")
    func desiredAgentUpdateSemanticAbsence() throws {
        let decoded = try throughEnvelope(DesiredStateMessage(syncId: "s", vms: []))
        #expect(!decoded.hasDesiredAgentUpdate)
        #expect(decoded.syncID == "s")
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
                reason: "3 reconcile work item(s) are in flight"
            )
        )
        let decoded = try throughEnvelope(report)

        try #require(decoded.hasAgentUpdateStatus)
        let status = decoded.agentUpdateStatus
        #expect(status.targetVersion == "1.4.0")
        #expect(status.disposition == ObservedAgentUpdateStatus.dispositionBlocked)
        #expect(status.reason.contains("in flight"))
    }

    @Test("ObservedStateReport without an update blocker decodes the status to nil")
    func observedUpdateStatusSemanticAbsence() throws {
        let decoded = try throughEnvelope(
            ObservedStateReport(agentId: "agent-1", vms: [], resources: Fixtures.resources))
        #expect(!decoded.hasAgentUpdateStatus)
    }
}
