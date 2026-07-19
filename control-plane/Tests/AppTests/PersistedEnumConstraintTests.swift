import Fluent
import SQLKit
import StratoShared
import Testing

@testable import App

@Suite("Persisted enum constraints", .serialized)
struct PersistedEnumConstraintTests {
    @Test("Constraint registry matches every Fluent enum's raw values")
    func registryMatchesModelEnums() {
        let expected: [String: Set<String>] = [
            "agents.status": rawValues(AgentStatus.self),
            "images.format": rawValues(ImageFormat.self),
            "images.architecture": rawValues(CPUArchitecture.self),
            "images.status": rawValues(ImageStatus.self),
            "image_artifacts.kind": rawValues(ArtifactKind.self),
            "image_artifacts.format": rawValues(ImageFormat.self),
            "image_artifacts.architecture": rawValues(CPUArchitecture.self),
            "image_artifacts.status": rawValues(ArtifactStatus.self),
            "resource_operations.resource_kind": rawValues(OperationResourceKind.self),
            "resource_operations.kind": rawValues(VMOperationKind.self),
            "resource_operations.status": rawValues(VMOperationStatus.self),
            "sandboxes.status": rawValues(SandboxStatus.self),
            "sandboxes.desired_status": rawValues(DesiredSandboxStatus.self),
            "sandbox_snapshots.status": rawValues(SandboxSnapshotStatus.self),
            "storage_pools.mode": rawValues(StoragePoolMode.self),
            "storage_pools.backing": rawValues(StoragePoolBacking.self),
            "vms.status": rawValues(VMStatus.self),
            "vms.desired_status": rawValues(DesiredVMStatus.self),
            "vms.hypervisor_type": rawValues(HypervisorType.self),
            "vms.console_mode": rawValues(ConsoleMode.self),
            "vms.serial_mode": rawValues(ConsoleMode.self),
            "volumes.format": rawValues(VolumeFormat.self),
            "volumes.type": rawValues(VolumeType.self),
            "volumes.status": rawValues(VolumeStatus.self),
            "volume_replicas.state": rawValues(VolumeReplicaState.self),
            "volume_snapshots.status": rawValues(SnapshotStatus.self),
        ]
        let actual = Dictionary(
            uniqueKeysWithValues: EnforcePersistedEnumValues.constraints.map {
                ("\($0.table).\($0.column)", Set($0.allowedValues))
            })

        #expect(actual == expected)
    }

    @Test("Migration normalizes casing and rejects future invalid writes")
    func normalizesThenRejectsInvalidWrites() async throws {
        try await withTestApp { app in
            let sql = try #require(app.db as? any SQLDatabase)
            let constraint = PersistedEnumConstraint(
                table: "persisted_enum_constraint_test",
                column: "status",
                allowedValues: ["Running", "Stopped"],
                defaultValue: "Running"
            )
            try await app.db.schema(constraint.table)
                // Reproduce the legacy migrations' accidentally quoted SQL
                // default so both engines exercise its repair path.
                .field(.string(constraint.column), .string, .required, .sql(.default("'Running'")))
                .create()

            try await sql.raw(
                "INSERT INTO persisted_enum_constraint_test (status) VALUES ('rUnNiNg')"
            ).run()
            try await EnforcePersistedEnumValues.prepare(constraint, on: app.db)

            let row = try #require(
                try await sql.raw("SELECT status FROM persisted_enum_constraint_test").first()
            )
            #expect(try row.decode(column: "status", as: String.self) == "Running")

            await #expect(throws: (any Error).self) {
                try await sql.raw(
                    "UPDATE persisted_enum_constraint_test SET status = 'running'"
                ).run()
            }
            await #expect(throws: (any Error).self) {
                try await sql.raw(
                    "INSERT INTO persisted_enum_constraint_test (status) VALUES ('FutureState')"
                ).run()
            }

            try await sql.raw("INSERT INTO persisted_enum_constraint_test DEFAULT VALUES").run()
            let statuses = try await sql.raw(
                "SELECT status FROM persisted_enum_constraint_test ORDER BY status"
            ).all()
            #expect(try statuses.map { try $0.decode(column: "status", as: String.self) } == ["Running", "Running"])

            try await sql.raw(
                "UPDATE persisted_enum_constraint_test SET status = 'Stopped'"
            ).run()
            try await EnforcePersistedEnumValues.revert(constraint, on: app.db)
            try await app.db.schema(constraint.table).delete()
        }
    }

    @Test("Migration reports unknown existing values before model access")
    func reportsUnknownExistingValues() async throws {
        try await withTestApp { app in
            let sql = try #require(app.db as? any SQLDatabase)
            let constraint = PersistedEnumConstraint(
                table: "persisted_enum_unknown_test",
                column: "status",
                allowedValues: ["Running", "Stopped"]
            )
            try await app.db.schema(constraint.table)
                .field(.string(constraint.column), .string)
                .create()
            try await sql.raw(
                "INSERT INTO persisted_enum_unknown_test (status) VALUES ('FutureState')"
            ).run()

            do {
                try await EnforcePersistedEnumValues.prepare(constraint, on: app.db)
                Issue.record("Expected the migration to reject an unknown stored value")
            } catch let error as PersistedEnumConstraintMigrationError {
                #expect(
                    error.description
                        == "Cannot enforce enum constraint on persisted_enum_unknown_test.status; "
                        + "unsupported stored value(s): FutureState"
                )
            }

            try await app.db.schema(constraint.table).delete()
        }
    }

    private func rawValues<E>(_ type: E.Type) -> Set<String>
    where E: CaseIterable & RawRepresentable, E.RawValue == String {
        Set(E.allCases.map(\.rawValue))
    }
}
