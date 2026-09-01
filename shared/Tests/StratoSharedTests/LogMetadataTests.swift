import Testing

@testable import StratoShared

@Suite("Log metadata taxonomy")
struct LogMetadataTests {
    @Test("Canonical identifier keys are dot-separated")
    func canonicalKeysAreDotSeparated() {
        let keys = [
            LogMetadata.Key.serviceName,
            LogMetadata.Key.serviceInstanceID,
            LogMetadata.Key.deploymentEnvironmentName,
            LogMetadata.Key.serviceVersion,
            LogMetadata.Key.requestID,
            LogMetadata.Key.operationID,
            LogMetadata.Key.agentID,
            LogMetadata.Key.agentName,
            LogMetadata.Key.agentIdentity,
            LogMetadata.Key.vmID,
            LogMetadata.Key.sandboxID,
            LogMetadata.Key.projectID,
            LogMetadata.Key.sessionID,
            LogMetadata.Key.sessionKind,
        ]

        #expect(keys.allSatisfy { $0.contains(".") })
    }

    @Test("Legacy identifier spellings resolve to their canonical key")
    func legacyAliasesResolve() {
        #expect(LogMetadata.canonicalKey(for: "vmId") == LogMetadata.Key.vmID)
        #expect(LogMetadata.canonicalKey(for: "vm_id") == LogMetadata.Key.vmID)
        #expect(LogMetadata.canonicalKey(for: "session_id") == "session_id")
        #expect(LogMetadata.canonicalKey(for: "request-id") == LogMetadata.Key.requestID)
        #expect(LogMetadata.canonicalKey(for: "unrelated") == "unrelated")
    }

    @Test("Guest resource kinds map to their entity identifier key")
    func guestResourceKeys() {
        #expect(
            LogMetadata.guestResourceIDKey(for: .virtualMachine)
                == LogMetadata.Key.vmID)
        #expect(
            LogMetadata.guestResourceIDKey(for: .sandbox)
                == LogMetadata.Key.sandboxID)
    }
}
