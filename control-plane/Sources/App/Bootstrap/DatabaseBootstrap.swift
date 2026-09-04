import Fluent
import FluentPostgresDriver
import NIOSSL
import Vapor

extension Application {
    /// Configures PostgreSQL, registers the ordered schema history, and runs it
    /// through the control plane's serialized migration runner.
    func bootstrapDatabase() async throws {
        let databaseStatementTimeouts = try configureDatabaseDriver()
        registerMigrations()

        // Not `app.autoMigrate()` (STR-183). Fluent's migrator takes no lock and
        // wraps no transaction around a migration and the `_fluent_migrations` row
        // that records it, so concurrent replica boots race the same migration and a
        // crash mid-migration leaves a half-state no later boot can get past.
        // `SchemaMigrator` serializes the phase on a Postgres advisory lock and
        // commits each migration with its log row.
        var schemaMigrationOptions = SchemaMigrator.Options.fromConfiguration(controlPlaneConfiguration)
        schemaMigrationOptions.statementTimeouts = databaseStatementTimeouts
        do {
            try await SchemaMigrator.run(on: self, options: schemaMigrationOptions)
        } catch {
            // In particular, let a legacy MAC collision name every affected NIC
            // before the ledger migration refuses to install only half its safety
            // constraints. Schemas too old to have both interface tables simply
            // make this best-effort diagnostic unavailable.
            try? await MACAddressAudit.warnAboutDuplicates(on: db, logger: logger)
            throw error
        }
    }

    private func configureDatabaseDriver() throws -> SchemaMigrator.StatementTimeouts? {
        guard environment != .testing else {
            // Testing is already configured with a per-test Postgres database
            // clone in test setup, so do not replace its driver here.
            return nil
        }

        // TLS mode is configurable via DATABASE_TLS (disable|prefer|require) and
        // defaults to `require` outside development, so credentials and data are
        // encrypted whenever Postgres is remote. See issue #56.
        let databaseTLS = try makeDatabaseTLS(
            configuration: controlPlaneConfiguration, logger: logger)
        let statementTimeout = try DatabaseStatementTimeout(
            milliseconds: controlPlaneConfiguration.int(.databaseStatementTimeoutMS))
        let migrationStatementTimeout = try DatabaseStatementTimeout(
            milliseconds: controlPlaneConfiguration.int(.databaseMigrationStatementTimeoutMS))
        let statementTimeouts = SchemaMigrator.StatementTimeouts(
            normal: statementTimeout,
            migration: migrationStatementTimeout
        )
        let databaseConfiguration = SQLPostgresConfiguration(
            hostname: controlPlaneConfiguration.requiredString(.databaseHost),
            port: controlPlaneConfiguration.int(.databasePort),
            username: controlPlaneConfiguration.requiredString(.databaseUsername),
            password: controlPlaneConfiguration.requiredString(.databasePassword),
            database: controlPlaneConfiguration.requiredString(.databaseName),
            tls: databaseTLS
        )
        logger.info(
            "Database statement timeouts configured",
            metadata: [
                "servingMilliseconds": .stringConvertible(statementTimeout.milliseconds),
                "migrationMilliseconds": .stringConvertible(migrationStatementTimeout.milliseconds),
            ]
        )
        databases.use(
            statementTimeout.applying(
                to: DatabaseConfigurationFactory.postgres(
                    configuration: databaseConfiguration
                )
            ), as: .psql)
        return statementTimeouts
    }

    /// Registers the frozen fresh-install baseline followed by every upgrade
    /// migration. Internal so the baseline policy test can prove the full chain
    /// reaches the reviewed current catalog.
    func registerMigrations() {
        // STR-234 replaces the executable historical chain with the reviewed
        // current-schema baseline. This migration intentionally accepts only a
        // fresh database; see ADR 0009 for the cutover decision.
        migrations.add(CurrentSchemaBaseline())

        registerForwardMigrations()
    }

    /// Registers upgrades that follow the current-schema snapshot. Kept
    /// separate so the schema test can compare the baseline and upgrade paths
    /// in one database without registering the baseline twice.
    func registerForwardMigrations() {

        // STR-28: project-scoped native OVN load balancers, incremental listener
        // and backend membership, external Floating IP attachment, and quota.
        migrations.add(CreateLoadBalancer())
        migrations.add(CreateLoadBalancerListener())
        migrations.add(CreateLoadBalancerBackend())
        migrations.add(AddLoadBalancerCountToResourceQuota())

        // STR-237: fresh, feature-scoped dependency health becomes the authority
        // for new placement while existing workloads remain untouched.
        migrations.add(AddAgentDependencyObservations())

        // STR-64: choose full seed ISO or IMDS-backed NoCloud per VM. Existing
        // rows stay on the full ISO explicitly; this phase does not cut them over.
        migrations.add(AddMetadataSourceToVM())

        // STR-64: an OVN agent may still disable its metadata listener. Persist
        // the explicit registration capability and fail closed until it reports.
        migrations.add(AddAgentMetadataServiceCapability())

        // STR-66: mutable VM tags and plural authorized keys. Existing single-key
        // rows are backfilled without changing what their guests receive.
        migrations.add(AddMutableMetadataToVM())

        // STR-246: the guest-agent opt-in was added to the fresh-schema baseline
        // without an upgrade migration. Repair preserved databases before any VM
        // query can select the required field.
        migrations.add(AddGuestAgentEnabledToVM())

        // STR-256: reject oversized IAM names before their unique btree indexes
        // turn caller input into PostgreSQL 54000 and an API 500.
        migrations.add(AddAdministrativeTextLengthConstraints())

        // STR-79: durable captured VM command state with cold output payloads.
        migrations.add(CreateVMCommandExecutions())

        // STR-260: failed recorded commands may expose bounded partial output
        // without inventing a guest exit code.
        migrations.add(AllowPartialVMCommandResults())

        // STR-84: append-only guest command and interactive execution facts.
        migrations.add(AddVMGuestExecutionAudit())

        // STR-154: preserve the attachment case and its coordinates instead of
        // interpreting every agent-owned storage reference as a host path.
        migrations.add(ReplaceVolumeReplicaDatasetPath())

        // STR-156: durable agent-reported physical disk inventory and operator OSD
        // eligibility intent. Missing disks remain rows until their agent is removed.
        migrations.add(CreateStorageDevices())

        // STR-300: Fluent binds `[StorageDeviceUse]` as `text[]`; repair the
        // original `jsonb[]` column so non-empty agent inventories can persist.
        migrations.add(FixStorageDeviceUsesArrayType())

        // STR-288: one fleet-wide ledger owns VM and sandbox NIC MAC uniqueness.
        // Existing addresses are retained exactly; incompatible legacy rows make
        // this migration fail closed with their interface ids.
        migrations.add(CreateMACAddressLedger())

        // STR-33: optional one-per-network stateless ACLs with ordered ingress and
        // egress rules. Existing logical networks intentionally keep no ACL row.
        migrations.add(CreateNetworkACLs())

        // STR-287: keep a per-VM assembly failure visible even though the agent's
        // heartbeat still reports convergence for its last successfully received
        // sync and owns the ordinary convergence-error columns.
        migrations.add(AddDesiredStateAssemblyFailureToVM())

        // STR-289: caller-scoped, expiring replay claims for HTTP mutations. The
        // durable audit event remains permanent; only this deduplication window is
        // swept.
        migrations.add(CreateIdempotencyKeys())

        // Agent enrollment now hands the host one opaque bearer and derives every
        // identity/network value server-side when it is redeemed. Existing rows
        // stay on their issued bootstrap commands; no secret can be backfilled.
        migrations.add(AddAgentEnrollmentBootstrapTokens())

        // STR-155: external Ceph clusters, per-project cephx identities, RBD
        // pools, and a permanent credential-revocation ledger. Local pools and
        // local-volume replica placement are unchanged.
        migrations.add(AddExternalCephStorage())
        migrations.add(AddCephCredentialRevocations())

        // STR-264: distinguish active claims from retry backoff, preserve the
        // enqueue time across mixed-version drop retention, and add the partial
        // queue index used by fair claims and per-subscription shedding.
        migrations.add(AddWebhookDeliveryClaimLease())

        // STR-297: creator references are attribution, not ownership. Deleting a
        // user must never cascade their volumes, snapshots or images away — nor
        // be blocked by an unhandled constraint on the tables that declared no
        // rule.
        migrations.add(MakeCreatorReferencesNullable())

        // VM command execution records a `run` resource event. The Swift enum
        // gained that case before the database check constraint did, so repair
        // both preserved databases and the current-schema baseline.
        migrations.add(AddRunResourceEventMutation())

        // The exact-match registration handshake makes a persisted wire version
        // redundant. Fresh baselines omit it; preserved databases drop it here.
        migrations.add(DropAgentWireProtocolVersion())

        // STR-269: opt-in cache policy plus the agent's exact applied/fallback
        // report. Existing volumes remain conservative.
        migrations.add(AddVolumeBlockPolicy())
    }
}
