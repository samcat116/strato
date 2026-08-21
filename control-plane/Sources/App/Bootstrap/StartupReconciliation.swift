import ControlPlanePostgres
import Vapor

extension Application {
    /// Reconciles code-owned registries and durable derived state after schema
    /// migration and before the process becomes ready.
    func reconcileStartupState(using persistence: ControlPlanePersistence) async throws {
        // STR-186 prevents new tenant IPv6 subnets from overlapping the ULA space
        // used by metadata and per-network resolvers. Existing rows cannot be
        // renumbered safely in place, so name every collision at each startup until
        // its operator remediates it.
        try await NetworkServiceSpaceAudit.warnAboutCollidingNetworks(
            using: persistence.networks,
            logger: logger)

        // Reconcile the iam_roles/iam_role_actions tables with the code-side
        // curated registry. Runs every startup so registry changes land with the
        // deploy that carries them.
        try await RoleRegistrySync.sync(using: persistence.iam, logger: logger)

        try await reconcileCedarPolicySet(using: persistence)

        // Converge any plaintext stored secrets (OIDC client secrets, SSF auth
        // tokens) to encrypted form. Runs every startup (not a one-shot migration)
        // so a key added after upgrade still picks up rows written before it
        // existed. No-op without a key.
        try await secretsEncryption.encryptStoredSecrets(
            oidcProviders: persistence.oidcProviders,
            ssfStreams: persistence.ssfStreams,
            registryPullSecrets: persistence.registryPullSecrets,
            webhookSubscriptions: persistence.webhookSubscriptions,
            logger: logger
        )

        // Initialize the WebAuthn decoy credential key (generates if not exists),
        // so the first login begin doesn't pay the generate-and-store round trip.
        _ = try await DecoyKeyService.getKey(from: self, settings: persistence.appSettings)
    }

    private func reconcileCedarPolicySet(
        using persistence: ControlPlanePersistence
    ) async throws {
        // The compiled set is authoritative. Production starts its level-triggered
        // cache and version watch; tests build once so no periodic task outlives
        // their application. Densifying stored Cedar text remains a production
        // startup repair and is idempotent.
        if environment != .testing {
            try await GuardrailStore.backfillCedarText(
                using: persistence.iam,
                logger: logger
            )
            await startCedarPolicySetCache()
            await startPolicySetVersionWatch()
        } else {
            let version = try await persistence.iam.currentPolicySetVersion()
            await cedarPolicySet.rebuild(version: version)
        }
    }
}
