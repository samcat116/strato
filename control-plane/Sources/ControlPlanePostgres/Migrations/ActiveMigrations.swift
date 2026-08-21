import PostgresNIO

/// The ordered migration list. Every name is the exact value written by the
/// former Fluent migration type, including its historical `App.` module prefix.
public enum StratoMigrations {
    public static var current: [any StratoMigration] {
        [
            CurrentSchemaBaselineMigration(),
            CreateLoadBalancerMigration(),
            CreateLoadBalancerListenerMigration(),
            CreateLoadBalancerBackendMigration(),
            AddLoadBalancerCountToResourceQuotaMigration(),
            BackfillNetworkQuotaAccountingMigration(),
            AddAgentDependencyObservationsMigration(),
            AddMetadataSourceToVMMigration(),
            AddAgentMetadataServiceCapabilityMigration(),
            AddMutableMetadataToVMMigration(),
            AddGuestAgentEnabledToVMMigration(),
            AddAdministrativeTextLengthConstraintsMigration(),
            CreateVMCommandExecutionsMigration(),
            ReplaceVolumeReplicaDatasetPathMigration(),
            CreateStorageDevicesMigration(),
            AddAgentEnrollmentBootstrapTokensMigration(),
        ]
    }
}

private struct CreateLoadBalancerMigration: StratoMigration {
    let name = "App.CreateLoadBalancer"

    func apply(on session: PostgresSession) async throws {
        try await run([
            """
            CREATE TABLE load_balancers (
                id UUID PRIMARY KEY,
                name TEXT NOT NULL,
                project_id UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
                logical_network_id UUID NOT NULL REFERENCES logical_networks(id) ON DELETE CASCADE,
                vip TEXT NOT NULL,
                protocol TEXT NOT NULL,
                desired_state TEXT NOT NULL,
                observed_state TEXT NOT NULL,
                generation BIGINT NOT NULL,
                observed_generation BIGINT NOT NULL,
                last_error TEXT,
                health_check_enabled BOOL NOT NULL,
                health_check_interval_seconds BIGINT NOT NULL,
                health_check_timeout_seconds BIGINT NOT NULL,
                health_check_success_threshold BIGINT NOT NULL,
                health_check_failure_threshold BIGINT NOT NULL,
                created_by_id UUID REFERENCES users(id) ON DELETE SET NULL,
                created_at TIMESTAMPTZ,
                updated_at TIMESTAMPTZ,
                CONSTRAINT "uq:load_balancers.project_id+load_balancers.name" UNIQUE (project_id, name),
                CONSTRAINT "uq:load_balancers.logical_network_id+load_balancers.vip" UNIQUE (logical_network_id, vip)
            )
            """,
            "ALTER TABLE floating_ips ADD COLUMN load_balancer_id UUID REFERENCES load_balancers(id) ON DELETE SET NULL",
            "ALTER TABLE load_balancers ADD CONSTRAINT ck_load_balancers_protocol CHECK (protocol IN ('tcp', 'udp'))",
            "ALTER TABLE floating_ips ADD CONSTRAINT ck_floating_ips_one_target CHECK (NOT (interface_id IS NOT NULL AND load_balancer_id IS NOT NULL))",
            "CREATE UNIQUE INDEX uq_floating_ips_load_balancer_id ON floating_ips (load_balancer_id) WHERE load_balancer_id IS NOT NULL",
        ], on: session, operation: "migration.create_load_balancer")
    }

    func revert(on session: PostgresSession) async throws {
        try await run([
            "ALTER TABLE floating_ips DROP COLUMN load_balancer_id",
            "DROP TABLE load_balancers",
        ], on: session, operation: "migration.revert_create_load_balancer")
    }
}

private struct CreateLoadBalancerListenerMigration: StratoMigration {
    let name = "App.CreateLoadBalancerListener"

    func apply(on session: PostgresSession) async throws {
        try await session.command(
            """
            CREATE TABLE load_balancer_listeners (
                id UUID PRIMARY KEY,
                load_balancer_id UUID NOT NULL REFERENCES load_balancers(id) ON DELETE CASCADE,
                port BIGINT NOT NULL,
                backend_port BIGINT NOT NULL,
                created_at TIMESTAMPTZ,
                updated_at TIMESTAMPTZ,
                CONSTRAINT "uq:load_balancer_listeners.load_balancer_id+load_balancer_listeners.port"
                    UNIQUE (load_balancer_id, port)
            )
            """,
            operation: "migration.create_load_balancer_listeners"
        )
    }

    func revert(on session: PostgresSession) async throws {
        try await session.command("DROP TABLE load_balancer_listeners", operation: "migration.drop_load_balancer_listeners")
    }
}

private struct CreateLoadBalancerBackendMigration: StratoMigration {
    let name = "App.CreateLoadBalancerBackend"

    func apply(on session: PostgresSession) async throws {
        try await session.command(
            """
            CREATE TABLE load_balancer_backends (
                id UUID PRIMARY KEY,
                load_balancer_id UUID NOT NULL REFERENCES load_balancers(id) ON DELETE CASCADE,
                interface_id UUID REFERENCES vm_network_interfaces(id) ON DELETE SET NULL,
                address TEXT,
                health_status TEXT NOT NULL,
                last_health_check_at TIMESTAMPTZ,
                created_at TIMESTAMPTZ,
                updated_at TIMESTAMPTZ,
                CONSTRAINT uq_lb_backend_interface UNIQUE (load_balancer_id, interface_id),
                CONSTRAINT uq_lb_backend_address UNIQUE (load_balancer_id, address)
            )
            """,
            operation: "migration.create_load_balancer_backends"
        )
    }

    func revert(on session: PostgresSession) async throws {
        try await session.command("DROP TABLE load_balancer_backends", operation: "migration.drop_load_balancer_backends")
    }
}

private struct AddLoadBalancerCountToResourceQuotaMigration: StratoMigration {
    let name = "App.AddLoadBalancerCountToResourceQuota"

    func apply(on session: PostgresSession) async throws {
        try await run([
            "ALTER TABLE resource_quotas ADD COLUMN max_load_balancers INTEGER",
            "UPDATE resource_quotas SET max_load_balancers = max_vms",
            "ALTER TABLE resource_quotas ALTER COLUMN max_load_balancers SET NOT NULL",
            "ALTER TABLE resource_quotas ADD COLUMN load_balancer_count INTEGER NOT NULL DEFAULT 0",
            QuotaCounterResync.statement,
        ], on: session, operation: "migration.add_load_balancer_quota")
    }

    func revert(on session: PostgresSession) async throws {
        try await run([
            "ALTER TABLE resource_quotas DROP COLUMN load_balancer_count",
            "ALTER TABLE resource_quotas DROP COLUMN max_load_balancers",
        ], on: session, operation: "migration.revert_load_balancer_quota")
    }
}

private struct BackfillNetworkQuotaAccountingMigration: StratoMigration {
    let name = "App.BackfillNetworkQuotaAccounting"

    func apply(on session: PostgresSession) async throws {
        try await session.command(QuotaCounterResync.statement, operation: "migration.backfill_network_quota")
    }

    func revert(on session: PostgresSession) async throws {}
}

private struct AddAgentDependencyObservationsMigration: StratoMigration {
    let name = "App.AddAgentDependencyObservations"

    func apply(on session: PostgresSession) async throws {
        try await run([
            "ALTER TABLE agents ADD COLUMN dependency_observations JSONB[] NOT NULL DEFAULT '{}'",
            "ALTER TABLE agents ADD COLUMN dependency_observations_received_at TIMESTAMPTZ",
        ], on: session, operation: "migration.add_agent_dependency_observations")
    }

    func revert(on session: PostgresSession) async throws {
        try await run([
            "ALTER TABLE agents DROP COLUMN dependency_observations_received_at",
            "ALTER TABLE agents DROP COLUMN dependency_observations",
        ], on: session, operation: "migration.revert_agent_dependency_observations")
    }
}

private struct AddMetadataSourceToVMMigration: StratoMigration {
    let name = "App.AddMetadataSourceToVM"

    func apply(on session: PostgresSession) async throws {
        try await run([
            "ALTER TABLE vms ADD COLUMN metadata_source TEXT NOT NULL DEFAULT 'iso'",
            "ALTER TABLE vms ADD COLUMN metadata_seed_token UUID NOT NULL DEFAULT gen_random_uuid()",
            "ALTER TABLE vms ADD CONSTRAINT \"uq:vms.metadata_seed_token\" UNIQUE (metadata_seed_token)",
            "ALTER TABLE vms ADD CONSTRAINT ck_vms_metadata_source_enum CHECK (metadata_source IN ('iso', 'imds'))",
        ], on: session, operation: "migration.add_vm_metadata_source")
    }

    func revert(on session: PostgresSession) async throws {
        try await run([
            "ALTER TABLE vms DROP CONSTRAINT IF EXISTS ck_vms_metadata_source_enum",
            "ALTER TABLE vms DROP COLUMN metadata_seed_token",
            "ALTER TABLE vms DROP COLUMN metadata_source",
        ], on: session, operation: "migration.revert_vm_metadata_source")
    }
}

private struct AddAgentMetadataServiceCapabilityMigration: StratoMigration {
    let name = "App.AddAgentMetadataServiceCapability"

    func apply(on session: PostgresSession) async throws {
        try await session.command(
            "ALTER TABLE agents ADD COLUMN metadata_service_capable BOOL NOT NULL DEFAULT false",
            operation: "migration.add_agent_metadata_capability"
        )
    }

    func revert(on session: PostgresSession) async throws {
        try await session.command(
            "ALTER TABLE agents DROP COLUMN metadata_service_capable",
            operation: "migration.revert_agent_metadata_capability"
        )
    }
}

private struct AddMutableMetadataToVMMigration: StratoMigration {
    let name = "App.AddMutableMetadataToVM"

    func apply(on session: PostgresSession) async throws {
        try await run([
            "ALTER TABLE vms ADD COLUMN tags JSONB NOT NULL DEFAULT '{}'",
            "ALTER TABLE vms ADD COLUMN ssh_authorized_keys TEXT[] NOT NULL DEFAULT '{}'",
            "UPDATE vms SET ssh_authorized_keys = ARRAY[ssh_public_key] WHERE ssh_public_key IS NOT NULL",
        ], on: session, operation: "migration.add_vm_mutable_metadata")
    }

    func revert(on session: PostgresSession) async throws {
        try await run([
            "ALTER TABLE vms DROP COLUMN ssh_authorized_keys",
            "ALTER TABLE vms DROP COLUMN tags",
        ], on: session, operation: "migration.revert_vm_mutable_metadata")
    }
}

private struct AddGuestAgentEnabledToVMMigration: StratoMigration {
    let name = "App.AddGuestAgentEnabledToVM"

    func apply(on session: PostgresSession) async throws {
        try await session.command(
            "ALTER TABLE vms ADD COLUMN IF NOT EXISTS guest_agent_enabled BOOL DEFAULT false NOT NULL",
            operation: "migration.add_guest_agent_enabled"
        )
    }

    func revert(on session: PostgresSession) async throws {}
}

private struct AddAdministrativeTextLengthConstraintsMigration: StratoMigration {
    let name = "App.AddAdministrativeTextLengthConstraints"

    func apply(on session: PostgresSession) async throws {
        let rows = try await session.query(
            """
            SELECT table_name
            FROM (
                SELECT 'iam_guardrails' AS table_name FROM iam_guardrails
                WHERE char_length(name) > 128 OR char_length(description) > 4096
                UNION ALL
                SELECT 'iam_policies' AS table_name FROM iam_policies
                WHERE char_length(name) > 128 OR char_length(description) > 4096
                UNION ALL
                SELECT 'iam_roles' AS table_name FROM iam_roles
                WHERE char_length(name) > 128 OR char_length(description) > 4096
            ) AS invalid_rows
            GROUP BY table_name ORDER BY table_name
            """,
            operation: "migration.validate_administrative_text"
        )
        let invalidTables = try rows.map { try $0.decode(String.self) }
        guard invalidTables.isEmpty else {
            throw AdministrativeTextLengthMigrationError.existingRowsExceedLimits(invalidTables)
        }
        for (table, name, expression) in [
            ("iam_guardrails", "ck_iam_guardrails_name_length", "char_length(name) <= 128"),
            ("iam_guardrails", "ck_iam_guardrails_description_length", "char_length(description) <= 4096"),
            ("iam_policies", "ck_iam_policies_name_length", "char_length(name) <= 128"),
            ("iam_policies", "ck_iam_policies_description_length", "char_length(description) <= 4096"),
            ("iam_roles", "ck_iam_roles_name_length", "char_length(name) <= 128"),
            ("iam_roles", "ck_iam_roles_description_length", "char_length(description) <= 4096"),
        ] {
            try await session.command(
                """
                DO $str256$
                BEGIN
                    IF NOT EXISTS (
                        SELECT 1 FROM pg_constraint
                        WHERE conname = '\(name)' AND conrelid = 'public.\(table)'::regclass
                    ) THEN
                        ALTER TABLE public.\(table) ADD CONSTRAINT \(name) CHECK (\(expression));
                    END IF;
                END
                $str256$
                """,
                operation: "migration.add_administrative_text_constraint"
            )
        }
    }

    func revert(on session: PostgresSession) async throws {}
}

private enum AdministrativeTextLengthMigrationError: Error, Sendable {
    case existingRowsExceedLimits([String])
}

private struct CreateVMCommandExecutionsMigration: StratoMigration {
    let name = "App.CreateVMCommandExecutions"

    func apply(on session: PostgresSession) async throws {
        try await run([
            """
            CREATE TABLE vm_command_executions (
                id UUID PRIMARY KEY,
                vm_id UUID NOT NULL,
                actor_type TEXT NOT NULL,
                actor_id UUID NOT NULL,
                agent_key TEXT NOT NULL,
                status TEXT NOT NULL,
                error TEXT,
                deadline TIMESTAMPTZ NOT NULL,
                created_at TIMESTAMPTZ,
                completed_at TIMESTAMPTZ
            )
            """,
            """
            CREATE TABLE vm_command_payloads (
                execution_id UUID PRIMARY KEY REFERENCES vm_command_executions(id) ON DELETE CASCADE,
                command TEXT[] NOT NULL,
                stdout BYTEA,
                stderr BYTEA,
                exit_code BIGINT,
                truncated BOOL
            )
            """,
            "ALTER TABLE vm_command_executions ADD CONSTRAINT ck_vm_command_executions_actor_type CHECK (actor_type = 'user')",
            "ALTER TABLE vm_command_executions ADD CONSTRAINT ck_vm_command_executions_status CHECK (status IN ('pending', 'succeeded', 'failed'))",
            "CREATE INDEX idx_vm_command_executions_vm_created ON vm_command_executions (vm_id, created_at DESC)",
            "CREATE INDEX idx_vm_command_executions_pending_deadline ON vm_command_executions (deadline) WHERE status = 'pending'",
            "ALTER TABLE vm_command_payloads ADD CONSTRAINT ck_vm_command_payloads_command CHECK (cardinality(command) > 0)",
            """
            ALTER TABLE vm_command_payloads ADD CONSTRAINT ck_vm_command_payloads_result
            CHECK (
                (stdout IS NULL AND stderr IS NULL AND exit_code IS NULL AND truncated IS NULL)
                OR (stdout IS NOT NULL AND stderr IS NOT NULL AND exit_code IS NOT NULL AND truncated IS NOT NULL
                    AND octet_length(stdout) + octet_length(stderr) <= 1048576)
            )
            """,
        ], on: session, operation: "migration.create_vm_command_executions")
    }

    func revert(on session: PostgresSession) async throws {
        try await run([
            "DROP TABLE vm_command_payloads",
            "DROP TABLE vm_command_executions",
        ], on: session, operation: "migration.revert_vm_command_executions")
    }
}

private struct ReplaceVolumeReplicaDatasetPathMigration: StratoMigration {
    let name = "App.ReplaceVolumeReplicaDatasetPath"

    func apply(on session: PostgresSession) async throws {
        try await session.command(Self.applySQL, operation: "migration.replace_replica_dataset_path")
    }

    func revert(on session: PostgresSession) async throws {
        try await session.command(Self.revertSQL, operation: "migration.revert_replica_dataset_path")
    }

    private static let applySQL = """
        DO $$
        BEGIN
          IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
              AND table_name = 'volume_replicas' AND column_name = 'dataset_path') THEN
            ALTER TABLE volume_replicas ADD COLUMN IF NOT EXISTS disk_attachment jsonb;
            UPDATE volume_replicas SET disk_attachment = jsonb_build_object(
              'file', jsonb_build_object('path', dataset_path, 'format',
                CASE WHEN lower(dataset_path) LIKE '%.raw' THEN 'raw' ELSE 'qcow2' END))
            WHERE dataset_path IS NOT NULL AND disk_attachment IS NULL;
            ALTER TABLE volume_replicas DROP COLUMN dataset_path;
          END IF;
        END
        $$
        """

    private static let revertSQL = """
        DO $$
        BEGIN
          IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
              AND table_name = 'volume_replicas' AND column_name = 'disk_attachment') THEN
            IF EXISTS (SELECT 1 FROM volume_replicas WHERE disk_attachment IS NOT NULL
                AND NOT (disk_attachment ? 'file')) THEN
              RAISE EXCEPTION 'cannot revert typed disk attachments while non-file replicas exist';
            END IF;
            ALTER TABLE volume_replicas ADD COLUMN IF NOT EXISTS dataset_path text;
            UPDATE volume_replicas SET dataset_path = disk_attachment -> 'file' ->> 'path'
            WHERE dataset_path IS NULL AND disk_attachment ? 'file';
            ALTER TABLE volume_replicas DROP COLUMN disk_attachment;
          END IF;
        END
        $$
        """
}

private struct CreateStorageDevicesMigration: StratoMigration {
    let name = "App.CreateStorageDevices"

    func apply(on session: PostgresSession) async throws {
        try await run([
            """
            CREATE TABLE storage_devices (
                id UUID PRIMARY KEY,
                agent_id UUID NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
                identity_kind TEXT,
                identity_value TEXT,
                device_path TEXT NOT NULL,
                size_bytes BIGINT NOT NULL,
                model TEXT,
                serial TEXT,
                wwn TEXT,
                rotational BOOL NOT NULL,
                uses JSONB[] NOT NULL DEFAULT '{}',
                role TEXT NOT NULL,
                state TEXT NOT NULL,
                osd_id BIGINT,
                present BOOL NOT NULL,
                last_seen_at TIMESTAMPTZ NOT NULL,
                created_at TIMESTAMPTZ,
                updated_at TIMESTAMPTZ
            )
            """,
            "ALTER TABLE storage_devices ADD CONSTRAINT ck_storage_devices_identity_pair CHECK ((identity_kind IS NULL) = (identity_value IS NULL))",
            "ALTER TABLE storage_devices ADD CONSTRAINT ck_storage_devices_identity_kind CHECK (identity_kind IS NULL OR identity_kind IN ('wwn', 'serial'))",
            "ALTER TABLE storage_devices ADD CONSTRAINT ck_storage_devices_size_bytes CHECK (size_bytes >= 0)",
            "ALTER TABLE storage_devices ADD CONSTRAINT ck_storage_devices_role CHECK (role IN ('unassigned', 'osd', 'excluded'))",
            "ALTER TABLE storage_devices ADD CONSTRAINT ck_storage_devices_state CHECK (state IN ('available', 'inUse', 'draining', 'faulted'))",
            "CREATE UNIQUE INDEX uq_storage_devices_agent_identity ON storage_devices (agent_id, identity_kind, identity_value)",
            "CREATE INDEX idx_storage_devices_agent_present ON storage_devices (agent_id, present)",
        ], on: session, operation: "migration.create_storage_devices")
    }

    func revert(on session: PostgresSession) async throws {
        try await session.command("DROP TABLE storage_devices", operation: "migration.drop_storage_devices")
    }
}

private struct AddAgentEnrollmentBootstrapTokensMigration: StratoMigration {
    let name = "App.AddAgentEnrollmentBootstrapTokens"

    func apply(on session: PostgresSession) async throws {
        try await run([
            "ALTER TABLE agent_enrollments ADD COLUMN bootstrap_token_hash TEXT",
            "ALTER TABLE agent_enrollments ADD CONSTRAINT \"uq:agent_enrollments.bootstrap_token_hash\" UNIQUE (bootstrap_token_hash)",
        ], on: session, operation: "migration.add_enrollment_bootstrap_token")
    }

    func revert(on session: PostgresSession) async throws {
        try await run([
            "ALTER TABLE agent_enrollments DROP CONSTRAINT \"uq:agent_enrollments.bootstrap_token_hash\"",
            "ALTER TABLE agent_enrollments DROP COLUMN bootstrap_token_hash",
        ], on: session, operation: "migration.revert_enrollment_bootstrap_token")
    }
}

private func run(
    _ statements: [String],
    on session: PostgresSession,
    operation: PostgresOperation
) async throws {
    for statement in statements {
        try await session.command(statement, operation: operation)
    }
}

private enum QuotaCounterResync {
    /// Reproduces `QuotaUsageAggregator` with correlated aggregates so migration
    /// backfills do not depend on mutable Fluent models.
    static let statement = """
        UPDATE resource_quotas AS q
        SET reserved_vcpus =
                (SELECT COALESCE(SUM(v.cpu), 0) FROM vms v WHERE \(workloadScope("v")))
              + (SELECT COALESCE(SUM(s.vcpus), 0) FROM sandboxes s WHERE \(workloadScope("s"))),
            reserved_memory =
                (SELECT COALESCE(SUM(v.memory), 0) FROM vms v WHERE \(workloadScope("v")))
              + (SELECT COALESCE(SUM(s.memory), 0) FROM sandboxes s WHERE \(workloadScope("s"))),
            reserved_storage =
                (SELECT COALESCE(SUM(v.size), 0) FROM volumes v WHERE \(workloadScope("v")))
              + (SELECT COALESCE(SUM(vs.size), 0) FROM volume_snapshots vs
                    WHERE \(workloadScope("vs")) AND vs.status::text <> 'error')
              + (SELECT COALESCE(SUM(ss.size), 0)
                       + COALESCE(SUM((SELECT COALESCE(SUM((a->>'sizeBytes')::bigint), 0)
                                      FROM unnest(ss.exported_artifacts) a)), 0)
                 FROM sandbox_snapshots ss WHERE \(workloadScope("ss")) AND ss.status::text <> 'error')
              + (SELECT COALESCE(SUM(vs.size), 0) FROM vm_snapshots vs
                    WHERE \(workloadScope("vs")) AND vs.status::text <> 'error'),
            vm_count = (SELECT COUNT(*) FROM vms v WHERE \(workloadScope("v"))),
            sandbox_count = (SELECT COUNT(*) FROM sandboxes s WHERE \(workloadScope("s"))),
            volume_count = (SELECT COUNT(*) FROM volumes v WHERE \(workloadScope("v"))),
            network_count = CASE WHEN q.environment IS NULL THEN
                (SELECT COUNT(*) FROM logical_networks n WHERE \(projectScope("n"))) ELSE 0 END,
            load_balancer_count = CASE WHEN q.environment IS NULL THEN
                (SELECT COUNT(*) FROM load_balancers lb WHERE \(projectScope("lb"))) ELSE 0 END,
            updated_at = CURRENT_TIMESTAMP
        """

    private static func workloadScope(_ alias: String) -> String {
        "(\(projectScope(alias))) AND (q.environment IS NULL OR \(alias).environment = q.environment)"
    }

    private static func projectScope(_ alias: String) -> String {
        """
        (
            (q.project_id IS NOT NULL AND \(alias).project_id = q.project_id)
            OR (q.organizational_unit_id IS NOT NULL AND \(alias).project_id IN (
                SELECT p.id FROM projects p
                JOIN organizational_units child ON child.id = p.organizational_unit_id
                JOIN organizational_units root ON root.id = q.organizational_unit_id
                WHERE child.path = root.path OR child.path LIKE root.path || '/%'
            ))
            OR (q.organization_id IS NOT NULL AND \(alias).project_id IN (
                SELECT p.id FROM projects p
                LEFT JOIN organizational_units ou ON ou.id = p.organizational_unit_id
                WHERE p.organization_id = q.organization_id OR ou.organization_id = q.organization_id
            ))
        )
        """
    }
}
