import Fluent
import Vapor

extension Application {
    /// Reconciles code-owned registries and durable derived state after schema
    /// migration and before the process becomes ready.
    func reconcileStartupState() async throws {
        try await NetworkServiceSpaceAudit.warnAboutCollidingNetworks(on: db, logger: logger)
        try await RoleRegistrySync.sync(on: db, logger: logger)
        try await reconcileCedarPolicySet()
        try await secretsEncryption.encryptStoredSecrets(on: db, logger: logger)
        _ = try await DecoyKeyService.getKey(from: self)
    }

    private func reconcileCedarPolicySet() async throws {
        if environment != .testing {
            try await GuardrailStore.backfillCedarText(on: db, logger: logger)
            await startCedarPolicySetCache()
            await startPolicySetVersionWatch()
        } else {
            let version = try await PolicySetVersionService.current(on: db)
            await cedarPolicySet.rebuild(version: version, on: db)
        }
    }
}
