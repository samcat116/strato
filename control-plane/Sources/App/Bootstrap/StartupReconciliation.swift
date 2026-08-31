import Fluent
import Vapor

extension Application {
    /// Reconciles code-owned registries and durable derived state after schema
    /// migration and before the process becomes ready.
    func reconcileStartupState() async throws {
        // STR-186 prevents new tenant IPv6 subnets from overlapping the ULA space
        // used by metadata and per-network resolvers. Existing rows cannot be
        // renumbered safely in place, so name every collision at each startup until
        // its operator remediates it.
        try await NetworkServiceSpaceAudit.warnAboutCollidingNetworks(on: db, logger: logger)

        // Reconcile the iam_roles/iam_role_actions tables with the code-side
        // curated registry. Runs every startup so registry changes land with the
        // deploy that carries them.
        try await RoleRegistrySync.sync(on: db, logger: logger)

        try await reconcileCedarPolicySet()

        // Audit all recoverable stored secrets and seal plaintext/previous-key rows
        // to the primary. The pass is an every-boot convergence boundary, not a
        // one-shot migration: it validates already-primary ciphertext too, records
        // unknown rows for readiness/metrics, and refuses ciphertext-without-key.
        try await secretsEncryption.encryptStoredSecrets(on: db, logger: logger)

        // Initialize the WebAuthn decoy credential key (generates if not exists),
        // so the first login begin doesn't pay the generate-and-store round trip.
        _ = try await DecoyKeyService.getKey(from: self)
    }

    private func reconcileCedarPolicySet() async throws {
        // IAM phase 2: track the policy-set version. Runs after the registry sync
        // so this replica starts from the version that sync may have just written,
        // and before anything can change policy. Under `.testing` the periodic
        // re-read would outlive the test's application, and the tests that care
        // drive the cache directly.
        //
        // IAM phase 3 (#480): the compiled Cedar policy set hangs off the version
        // watch, level-triggered so a failed rebuild retries on the periodic
        // re-read. The listener registers first so the watch's initial refresh
        // performs the boot-time build.
        //
        // Since cutover (#482) the compiled set is the authoritative decision
        // path, so `.testing` needs it too — but built once at boot rather than
        // via the watch, whose periodic re-read would outlive the test's
        // application. Tests that change policy (guardrail writes) drive
        // `cedarPolicySet.reconcile` directly.
        //
        // IAM #610: densify `iam_guardrails.cedar_text` before the set is built, so
        // the compiled set uses the stored text rather than the cache's
        // matcher-regeneration fallback. Idempotent, only touches NULL rows, and
        // needs no version bump (regeneration is byte-identical). Skipped in
        // `.testing`, where the fallback covers any null row and suites that need a
        // dense column write it explicitly.
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
