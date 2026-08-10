import SQLKit
import Testing
import Vapor
import Fluent
import VaporTesting
import AppTestSupport
@testable import App

/// Validates that the full migration set applies *and* reverses cleanly against
/// the configured database engine.
///
/// This is the guard for issue #195: it exercises every migration's `prepare`
/// and `revert` — including raw Postgres-specific SQL — against the real
/// engine production uses.
@Suite("Migration Round Trip", .serialized)
struct MigrationRoundTripTests {

    @Test("Membership role cutover canonicalizes legacy tokens and removes project mirrors")
    func membershipRoleCutover() async throws {
        try await withTestApp { app in
            let sql = try #require(app.db as? SQLDatabase)
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "role-cutover", email: "role-cutover@example.com")
            let org = try await builder.createOrganization(name: "Role Cutover Org")
            let project = try await builder.createProject(
                name: "Role Cutover Project", description: "", organization: org)
            let group = try await builder.createGroup(
                name: "Role Cutover Group", description: "", organization: org)
            let userID = try user.requireID()
            let organizationID = try org.requireID()
            let projectID = try project.requireID()
            let groupID = try group.requireID()
            let customRoleID = UUID()
            try await IAMRoleDefinition(
                id: customRoleID, name: "auditor", ownerType: .organization,
                ownerID: organizationID,
                cedarText: RoleDescriptor.canonicalPermitText(
                    id: customRoleID, actions: ["vm:read"]),
                actions: ["vm:read"], managed: false
            ).save(on: app.db)
            let provider = OIDCProvider(
                organizationID: organizationID, name: "Cutover IdP",
                clientID: "client", clientSecret: "secret",
                authorizationEndpoint: "https://idp.example.com/authorize",
                tokenEndpoint: "https://idp.example.com/token",
                jwksURI: "https://idp.example.com/jwks")
            try await provider.save(on: app.db)
            let providerID = try provider.requireID()

            // Recreate the immediately pre-STR-229 schema, then seed every
            // historical storage format through SQL because live models are
            // intentionally unable to express it.
            try await CanonicalizeMembershipRoleStorage().revert(on: app.db)
            try await sql.raw(
                """
                INSERT INTO user_organizations (id, user_id, organization_id, role, created_at)
                VALUES (\(bind: UUID()), \(bind: userID),
                        \(bind: organizationID), 'admin', now())
                """
            ).run()
            try await sql.raw(
                """
                INSERT INTO project_members (id, project_id, user_id, role, created_at)
                VALUES (\(bind: UUID()), \(bind: projectID),
                        \(bind: userID), 'member', now())
                """
            ).run()
            try await sql.raw(
                """
                INSERT INTO project_group_grants (id, project_id, group_id, role, created_at)
                VALUES (\(bind: UUID()), \(bind: projectID),
                        \(bind: groupID), 'viewer', now())
                """
            ).run()
            try await sql.raw(
                """
                INSERT INTO role_bindings
                    (id, principal_type, principal_id, role, node_type, node_id, created_at, expires_at)
                VALUES (\(bind: UUID()), 'user', \(bind: userID),
                        'operator', 'project', \(bind: projectID), now(), NULL),
                       (\(bind: UUID()), 'user', \(bind: userID),
                        \(bind: IAMRole.editor.seededID.uuidString), 'project', \(bind: projectID),
                        now(), now() - interval '1 hour')
                """
            ).run()
            try await sql.raw(
                "UPDATE oidc_providers SET default_role = 'auditor' WHERE id = \(bind: providerID)"
            ).run()

            try await CanonicalizeMembershipRoleStorage().prepare(on: app.db)

            let membership = try #require(
                try await UserOrganization.query(on: app.db)
                    .filter(\.$user.$id == userID)
                    .filter(\.$organization.$id == organizationID)
                    .first())
            #expect(membership.roleID == IAMRole.admin.seededID)

            let storedRoles = Set(
                try await RoleBinding.query(on: app.db).all().map(\.roleID))
            #expect(
                storedRoles
                    == Set([
                        IAMRole.admin.seededID,
                        IAMRole.editor.seededID,
                        IAMRole.viewer.seededID,
                        IAMRole.operator.seededID,
                    ]))
            let editorBinding = try #require(
                try await RoleBinding.query(on: app.db)
                    .filter(\.$principalType == IAMPrincipalType.user.rawValue)
                    .filter(\.$principalID == userID)
                    .filter(\.$roleID == IAMRole.editor.seededID)
                    .filter(\.$nodeType == IAMNodeType.project.rawValue)
                    .filter(\.$nodeID == projectID)
                    .first())
            #expect(editorBinding.expiresAt == nil)
            let storedProvider = try #require(try await OIDCProvider.find(provider.id, on: app.db))
            #expect(storedProvider.defaultRoleID == customRoleID)

            await #expect(throws: (any Error).self) {
                _ = try await sql.raw("SELECT id FROM project_members").all()
            }
            await #expect(throws: (any Error).self) {
                _ = try await sql.raw("SELECT id FROM project_group_grants").all()
            }
            await #expect(throws: (any Error).self) {
                _ = try await sql.raw("SELECT role FROM role_bindings").all()
            }
            await #expect(throws: (any Error).self) {
                _ = try await sql.raw("SELECT role FROM user_organizations").all()
            }
            await #expect(throws: (any Error).self) {
                _ = try await sql.raw("SELECT default_role FROM oidc_providers").all()
            }
        }
    }

    @Test("All migrations apply, revert, and re-apply cleanly")
    func migrationsRoundTrip() async throws {
        try await withTestApp { app in
            // The app's database is a clone of the template every migration was
            // applied to. Drive a full down → up cycle so a broken `revert` or a
            // non-idempotent `prepare` surfaces here rather than in production.
            try await app.autoRevert()
            try await app.autoMigrate()

            // Sanity check: after re-applying, a core table is queryable.
            let userCount = try await User.query(on: app.db).count()
            #expect(userCount == 0)

            // Second cycle: teardown no longer reverts (per-test databases are
            // simply dropped), so confirm revert is repeatable here.
            try await app.autoRevert()
            try await app.autoMigrate()
        }
    }

    /// STR-181: `AddVolumeQuotaAccounting` adds an environment column to two
    /// tables that never had one, so the interesting cases are rows that predate
    /// it. Written through raw SQL with the column nulled out, because the live
    /// models cannot express storage without an environment.
    @Test("Pre-existing storage follows its attached VM, then falls back to the project default")
    func volumeEnvironmentBackfillUsesAttachmentThenProjectDefault() async throws {
        try await withTestApp { app in
            let sql = try #require(app.db as? SQLDatabase)
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "backfill", email: "backfill@example.com")
            let org = try await builder.createOrganization(name: "Backfill Org")
            let project = try await builder.createProject(
                name: "Backfill Project", description: "p", organization: org)
            project.defaultEnvironment = "production"
            try await project.save(on: app.db)

            let vm = try await builder.createVM(
                name: "legacy-vm", project: project, environment: "staging")
            let attachedVolume = try await builder.createVolume(
                name: "legacy-attached", project: project, createdBy: user)
            attachedVolume.$vm.id = try vm.requireID()
            attachedVolume.deviceName = "disk1"
            try await attachedVolume.save(on: app.db)
            let attachedSnapshot = VolumeSnapshot(
                name: "legacy-attached-snap", description: "",
                volumeID: try attachedVolume.requireID(),
                projectID: try project.requireID(), environment: "development",
                size: 1 << 30, createdByID: try user.requireID())
            try await attachedSnapshot.save(on: app.db)

            let unattachedVolume = try await builder.createVolume(
                name: "legacy-unattached", project: project, createdBy: user)
            let unattachedSnapshot = VolumeSnapshot(
                name: "legacy-unattached-snap", description: "",
                volumeID: try unattachedVolume.requireID(),
                projectID: try project.requireID(), environment: "development",
                size: 1 << 30, createdByID: try user.requireID())
            try await unattachedSnapshot.save(on: app.db)

            // Rewind both rows to the pre-migration shape.
            for table in ["volumes", "volume_snapshots"] {
                try await sql.raw(
                    "ALTER TABLE \(ident: table) ALTER COLUMN environment DROP NOT NULL"
                ).run()
                try await sql.raw("UPDATE \(ident: table) SET environment = NULL").run()
            }

            try await AddVolumeQuotaAccounting().backfillEnvironments(on: app.db)

            let backfilledAttached = try #require(
                try await Volume.find(attachedVolume.id, on: app.db))
            let backfilledAttachedSnapshot = try #require(
                try await VolumeSnapshot.find(attachedSnapshot.id, on: app.db))
            #expect(backfilledAttached.environment == "staging")
            #expect(backfilledAttachedSnapshot.environment == "staging")

            let backfilledUnattached = try #require(
                try await Volume.find(unattachedVolume.id, on: app.db))
            let backfilledUnattachedSnapshot = try #require(
                try await VolumeSnapshot.find(unattachedSnapshot.id, on: app.db))
            #expect(backfilledUnattached.environment == "production")
            #expect(backfilledUnattachedSnapshot.environment == "production")
        }
    }

    @Test("Volume quota migration backfills storage and count reservations")
    func volumeQuotaMigrationBackfillsReservations() async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "quota-backfill", email: "quota-backfill@example.com")
            let org = try await builder.createOrganization(name: "Quota Backfill Org")
            let project = try await builder.createProject(
                name: "Quota Backfill Project", description: "p", organization: org)
            let vm = try await builder.createVM(name: "existing-vm", project: project)
            let quota = try await builder.createResourceQuota(name: "existing", project: project)

            let volume = try await builder.createVolume(
                name: "existing-volume", project: project, sizeGB: 20, createdBy: user)
            let snapshot = VolumeSnapshot(
                name: "existing-snapshot", description: "",
                volumeID: try volume.requireID(), projectID: try project.requireID(),
                environment: "development", size: volume.size,
                createdByID: try user.requireID())
            // A live footprint is reporting data, not capacity that can safely
            // be released from the reservation cache.
            snapshot.observedSizeBytes = 4 * 1024 * 1024
            try await snapshot.save(on: app.db)

            // Pre-upgrade storage already covered the VM but knew nothing about
            // the new volume families; volume_count was newly added as zero.
            quota.reservedStorage = vm.disk
            quota.volumeCount = 0
            try await quota.save(on: app.db)

            try await AddVolumeQuotaAccounting().backfillQuotaCounters(on: app.db)

            let backfilled = try #require(try await ResourceQuota.find(quota.id, on: app.db))
            #expect(backfilled.reservedStorage == vm.disk + 2 * volume.size)
            #expect(backfilled.volumeCount == 1)
        }
    }

    @Test("Legacy NIC address columns are dropped from the migrated schema")
    func legacyNICAddressColumnsAreDropped() async throws {
        try await withTestApp { app in
            let sql = try #require(app.db as? SQLDatabase)

            // DropLegacyVMInterfaceAddressColumns removed the single-address
            // columns; selecting them must fail on the fully-migrated schema.
            await #expect(throws: (any Error).self) {
                _ = try await sql.raw("SELECT ip_address FROM vm_network_interfaces").all()
            }
            await #expect(throws: (any Error).self) {
                _ = try await sql.raw("SELECT netmask FROM vm_network_interfaces").all()
            }
            await #expect(throws: (any Error).self) {
                _ = try await sql.raw("SELECT gateway FROM vm_network_interfaces").all()
            }

            // Their replacement is queryable.
            let addressRows = try await sql.raw("SELECT address FROM vm_interface_addresses").all()
            #expect(addressRows.isEmpty)
        }
    }

    @Test("The legacy agent capability bag is absent from the migrated schema")
    func legacyAgentCapabilitiesAreDropped() async throws {
        try await withTestApp { app in
            let sql = try #require(app.db as? SQLDatabase)

            await #expect(throws: (any Error).self) {
                _ = try await sql.raw("SELECT capabilities FROM agents").all()
            }

            // Its typed replacement remains queryable after the drop.
            let rows = try await sql.raw(
                "SELECT hypervisors, network_capability, sandbox_capable, "
                    + "sandbox_networking_capable, tpm_capable, resolver_capable FROM agents"
            ).all()
            #expect(rows.isEmpty)
        }
    }

    @Test("Workload convergence observability columns are nullable")
    func workloadConvergenceObservabilityColumnsAreNullable() async throws {
        try await withTestApp { app in
            let sql = try #require(app.db as? SQLDatabase)
            struct Column: Decodable {
                let table_name: String
                let column_name: String
                let is_nullable: String
            }
            let rows = try await sql.raw(
                """
                SELECT table_name, column_name, is_nullable
                FROM information_schema.columns
                WHERE table_schema = current_schema()
                  AND table_name IN ('vms', 'sandboxes')
                  AND column_name IN ('last_error_at', 'divergence_detected_at')
                """
            ).all(decoding: Column.self)

            #expect(rows.count == 4)
            #expect(rows.allSatisfy { $0.is_nullable == "YES" })
            #expect(
                Set(rows.map { "\($0.table_name).\($0.column_name)" })
                    == Set([
                        "vms.last_error_at", "vms.divergence_detected_at",
                        "sandboxes.last_error_at", "sandboxes.divergence_detected_at",
                    ]))
        }
    }

    /// The fully-migrated schema is the *fresh database* half of STR-152: the
    /// migrations that built `resource_operations` are deleted rather than
    /// reverted, so the table is simply never created.
    @Test("The retired operations table is absent from the migrated schema")
    func resourceOperationsIsAbsent() async throws {
        try await withTestApp { app in
            let sql = try #require(app.db as? SQLDatabase)
            await #expect(throws: (any Error).self) {
                _ = try await sql.raw("SELECT id FROM resource_operations").all()
            }
        }
    }

    /// And the *existing database* half. A deployment upgrading into this build
    /// still has the table, its rows, its indexes and the `CHECK` constraints
    /// `EnforcePersistedEnumValues` installed on it — none of which the deleted
    /// migrations are around to take down. `DropResourceOperations` is the only
    /// thing that removes them, so it is worth asserting against a table shaped
    /// like the one it will actually meet rather than against nothing.
    @Test("The drop migration removes both pre-upgrade operations tables and their dependents")
    func dropMigrationRemovesPreUpgradeTable() async throws {
        try await withTestApp { app in
            let sql = try #require(app.db as? SQLDatabase)

            try await sql.raw(
                """
                CREATE TABLE resource_operations (
                    id uuid PRIMARY KEY,
                    resource_kind text NOT NULL DEFAULT 'virtual_machine',
                    resource_id uuid NOT NULL,
                    user_id uuid NOT NULL,
                    kind text NOT NULL,
                    status text NOT NULL,
                    error text,
                    created_at timestamptz,
                    completed_at timestamptz,
                    organization_id uuid,
                    project_id uuid,
                    resource_name text,
                    CONSTRAINT ck_resource_operations_status_enum
                        CHECK (status IN ('pending', 'succeeded', 'failed'))
                )
                """
            ).run()
            try await sql.raw(
                "CREATE UNIQUE INDEX idx_resource_operations_pending_resource "
                    + "ON resource_operations (resource_kind, resource_id) WHERE status = 'pending'"
            ).run()
            // A row the previous build left `pending` — the case the sweep and
            // the verdict path survived nine stages to take terminal.
            try await sql.raw(
                """
                INSERT INTO resource_operations (id, resource_id, user_id, kind, status, created_at)
                VALUES (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), 'boot', 'pending', now())
                """
            ).run()

            // A database old enough to have run `CreateVMOperation` but never
            // `GeneralizeVMOperations` keeps the pre-rename table; both
            // migrations are deleted, so this is the only thing left that names
            // it.
            try await sql.raw(
                "CREATE TABLE vm_operations (id uuid PRIMARY KEY, vm_id uuid NOT NULL, status text NOT NULL)"
            ).run()

            try await DropResourceOperations().prepare(on: app.db)

            await #expect(throws: (any Error).self) {
                _ = try await sql.raw("SELECT id FROM resource_operations").all()
            }
            await #expect(throws: (any Error).self) {
                _ = try await sql.raw("SELECT id FROM vm_operations").all()
            }
            let indexes = try await sql.raw(
                "SELECT indexname FROM pg_indexes WHERE schemaname = current_schema() "
                    + "AND tablename = 'resource_operations'"
            ).all()
            #expect(indexes.isEmpty)

            // Idempotent: a replica that runs it twice, or a fresh database
            // that never had the table, must not fail.
            try await DropResourceOperations().prepare(on: app.db)
        }
    }

    @Test("Every hot-path index is present on the migrated schema")
    func hotPathIndexesArePresent() async throws {
        try await withTestApp { app in
            let sql = try #require(app.db as? SQLDatabase)

            // The migration's raw SQL only fails loudly if it is malformed, so
            // read the indexes back: a typo'd table or an unsupported partial
            // predicate would otherwise land silently as a missing index and a
            // sequential scan in production.
            let rows = try await sql.raw(
                "SELECT indexname FROM pg_indexes WHERE schemaname = current_schema()"
            ).all()
            let present = Set(try rows.map { try $0.decode(column: "indexname", as: String.self) })

            // `idx_vm_network_interfaces_network` is deliberately absent: its
            // column went away with the name→id re-key, and
            // `RekeyInterfacesToLogicalNetworkID` replaced it with the
            // id-keyed indexes below (issue #765).
            let retired: Set<String> = ["idx_vm_network_interfaces_network"]
            let expected =
                (AddHotPathIndexes.indexes + AddFolderPathIndex.indexes)
                .filter { !retired.contains($0.name) } + RekeyInterfacesToLogicalNetworkID.indexes
                // The three snapshot tables' `agent_id` indexes (STR-150): sync
                // assembly and observed-state application both scan by it, once
                // per poll and once per report.
                + AddConvergenceToSnapshots.agentIndexes.map {
                    (name: $0.index, definition: "\($0.table) (agent_id)")
                }
                // The VM-owned registrations' partial unique index (STR-55):
                // one identity per VM, and the lookup the sync assembly makes
                // once per poll.
                + AddVMToWorkloadRegistration.indexes
                // `volume_snapshots.project_id` (STR-181): the two other
                // snapshot tables got theirs in their create migrations for the
                // quota aggregate, and volume snapshots joined that aggregate.
                + AddVolumeQuotaAccounting.indexes
            for index in expected {
                let exists = present.contains(index.name)
                #expect(exists, "missing index \(index.name)")
            }
        }
    }

    @Test("The orphan sweep drops bindings whose node is gone and keeps the rest")
    func orphanedRoleBindingSweep() async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(username: "sweeper", email: "sweeper@example.com")
            let org = try await builder.createOrganization(name: "Sweep Org")
            let project = try await builder.createProject(
                name: "Sweep Project", description: "orphan sweep", organization: org)
            let vm = try await builder.createVM(name: "live-vm", project: project)

            func grant(_ nodeType: IAMNodeType, _ nodeID: UUID) async throws {
                try await RoleBindingService.grant(
                    principalType: .user, principalID: user.id!, role: .admin,
                    nodeType: nodeType, nodeID: nodeID, createdBy: user.id!, on: app.db)
            }
            func count(_ nodeType: IAMNodeType, _ nodeID: UUID) async throws -> Int {
                try await RoleBinding.query(on: app.db)
                    .filter(\.$nodeType == nodeType.rawValue)
                    .filter(\.$nodeID == nodeID)
                    .count()
            }

            let liveVMID = try vm.requireID()
            let deletedVMID = UUID()
            let deletedSnapshotID = UUID()
            let deletedVolumeID = UUID()
            try await grant(.virtualMachine, liveVMID)
            try await grant(.virtualMachine, deletedVMID)
            try await grant(.vmSnapshot, deletedSnapshotID)
            // A type the sweep deliberately leaves alone, orphan or not: only
            // the types whose delete paths were leaking are in scope.
            try await grant(.volume, deletedVolumeID)

            try await DeleteOrphanedResourceRoleBindings().prepare(on: app.db)

            let liveVMBindings = try await count(.virtualMachine, liveVMID)
            let orphanedVMBindings = try await count(.virtualMachine, deletedVMID)
            let orphanedSnapshotBindings = try await count(.vmSnapshot, deletedSnapshotID)
            let untouchedVolumeBindings = try await count(.volume, deletedVolumeID)
            #expect(liveVMBindings == 1)
            #expect(orphanedVMBindings == 0)
            #expect(orphanedSnapshotBindings == 0)
            #expect(untouchedVolumeBindings == 1)
        }
    }

    @Test("The instance-identity backfill reaches every VM, twice over, and undoes itself")
    func vmWorkloadRegistrationBackfill() async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "Backfill Org")
            let orgID = try org.requireID()

            // Both legs of the org walk: a project owned directly by the
            // organization, and one owned by a folder that is. `COALESCE` over
            // the two nullable columns is `Project.getRootOrganizationId` in
            // SQL, and a join that got either leg wrong would leave one of
            // these scoped to nothing.
            let directProject = try await builder.createProject(
                name: "Backfill Direct", description: "d", organization: org)
            let folder = try await builder.createOU(
                name: "Backfill Folder", description: "d", organization: org)
            let folderProject = try await builder.createProject(
                name: "Backfill Folder Project", description: "d", ou: folder)

            // `createVM` writes the row directly, so these VMs are genuinely
            // missing an identity — exactly the state a VM created before
            // STR-55 is in.
            let directVM = try await builder.createVM(name: "backfill-direct", project: directProject)
            let folderVM = try await builder.createVM(name: "backfill-folder", project: folderProject)
            let directVMID = try directVM.requireID()
            let folderVMID = try folderVM.requireID()

            func rows(forVM vmID: UUID) async throws -> [WorkloadRegistration] {
                try await WorkloadRegistration.query(on: app.db).filter(\.$vm.$id == vmID).all()
            }

            #expect(try await rows(forVM: directVMID).isEmpty)

            try await BackfillVMWorkloadRegistrations().prepare(on: app.db)

            for (vmID, name) in [(directVMID, "backfill-direct"), (folderVMID, "backfill-folder")] {
                let found = try await rows(forVM: vmID)
                #expect(found.count == 1, "\(name)")
                let row = try #require(found.first)
                #expect(row.kind == .workload)
                // No stored label, matching `GuestIdentity.register`: the
                // registry hydrates it from the VM.
                #expect(row.displayName == nil)
                // The organization is reached through the project either way.
                #expect(row.$organization.id == orgID, "\(name)")
                #expect(
                    row.spiffeID
                        == GuestIdentity.spiffeID(
                            forVM: vmID, trustDomain: PlatformTrustDomain.current),
                    "\(name)")
            }

            // Idempotent: `migrationsRoundTrip` re-applies the whole set, and a
            // second insert would trip the `spiffe_id` unique index.
            try await BackfillVMWorkloadRegistrations().prepare(on: app.db)
            #expect(try await rows(forVM: directVMID).count == 1)
            #expect(try await rows(forVM: folderVMID).count == 1)

            // Not a no-op: the migration above this one drops `vm_id`, so a
            // surviving row would keep squatting its `spiffe_id` while naming
            // nothing, and the re-applied backfill would skip that VM forever.
            try await BackfillVMWorkloadRegistrations().revert(on: app.db)
            let remaining = try await WorkloadRegistration.query(on: app.db).all()
                .filter { $0.$vm.id != nil }
            #expect(remaining.isEmpty)
        }
    }
}
