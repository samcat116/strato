import Fluent
import SQLKit

/// One string-backed Fluent enum column and the exact raw values its model can
/// decode. Keep this list in sync with the corresponding `CaseIterable` enum;
/// adding a case requires a follow-up migration that replaces its constraint.
struct PersistedEnumConstraint: Sendable, Equatable {
    let table: String
    let column: String
    let allowedValues: [String]
    let defaultValue: String?
    let usesPostgresNativeEnum: Bool

    init(
        table: String,
        column: String,
        allowedValues: [String],
        defaultValue: String? = nil,
        usesPostgresNativeEnum: Bool = false
    ) {
        self.table = table
        self.column = column
        self.allowedValues = allowedValues
        self.defaultValue = defaultValue
        self.usesPostgresNativeEnum = usesPostgresNativeEnum
    }

    var name: String { "ck_\(table)_\(column)_enum" }
}

enum PersistedEnumConstraintMigrationError: Error, CustomStringConvertible, Sendable {
    case invalidValues(table: String, column: String, values: [String])

    var description: String {
        switch self {
        case .invalidValues(let table, let column, let values):
            return
                "Cannot enforce enum constraint on \(table).\(column); unsupported stored value(s): "
                + values.joined(separator: ", ")
        }
    }
}

/// Protects every `@Enum`/`@OptionalEnum` property backed by a string column.
///
/// FluentKit currently force-unwraps `RawRepresentable.init(rawValue:)` when an
/// enum property is first accessed. A single unexpected database value can
/// therefore trap the entire process instead of producing a request error.
/// This migration makes the database the validation boundary:
///
/// 1. Known values with casing drift are rewritten to the canonical raw value.
/// 2. Any genuinely unknown existing value aborts startup with a diagnostic
///    naming the table, column, and value, before application code can load it.
/// 3. Every string-backed column receives a `CHECK` constraint, except those
///    backed by the native `agent_status` enum, whose type already provides
///    the same guarantee. `PersistedEnumConstraintTests` asserts that type
///    still matches `AgentStatus`, since no `CHECK` guards it.
struct EnforcePersistedEnumValues: AsyncMigration {
    static let constraints: [PersistedEnumConstraint] = [
        .init(
            table: "agents", column: "status",
            allowedValues: ["online", "offline", "connecting", "error"],
            usesPostgresNativeEnum: true
        ),
        .init(
            table: "images", column: "format",
            allowedValues: ["qcow2", "raw", "vmdk", "vhd", "vhdx"], defaultValue: "qcow2"
        ),
        .init(
            table: "images", column: "architecture", allowedValues: ["x86_64", "arm64"],
            defaultValue: "x86_64"
        ),
        .init(
            table: "images", column: "status",
            allowedValues: ["pending", "uploading", "downloading", "validating", "ready", "error"],
            defaultValue: "pending"
        ),
        .init(
            table: "image_artifacts", column: "kind",
            allowedValues: ["disk-image", "kernel", "initramfs", "rootfs"]
        ),
        .init(
            table: "image_artifacts", column: "format",
            allowedValues: ["qcow2", "raw", "vmdk", "vhd", "vhdx"]
        ),
        .init(
            table: "image_artifacts", column: "architecture",
            allowedValues: ["x86_64", "arm64"]
        ),
        .init(
            table: "image_artifacts", column: "status",
            allowedValues: ["pending", "downloading", "ready", "error"], defaultValue: "ready"
        ),
        // The three `resource_operations` columns this list used to guard —
        // `resource_kind`, `kind`, `status` — went with the table (STR-152).
        // The same vocabularies are still guarded where they are still stored:
        // `resource_events.resource_kind`/`.mutation` (installed by
        // `CreateResourceEvent`, widened by `AddVolumeOperationKinds` and
        // `AddSnapshotOperationKinds`) and
        // `agent_workload_claims.resource_kind`.
        .init(
            table: "sandboxes", column: "status",
            allowedValues: ["Stopped", "Running", "Exited", "Starting", "Stopping", "Error", "Unknown"]
        ),
        .init(
            table: "sandboxes", column: "desired_status",
            allowedValues: ["Running", "Stopped", "Absent"]
        ),
        .init(
            table: "sandbox_snapshots", column: "status",
            allowedValues: ["creating", "ready", "deleting", "error"]
        ),
        .init(table: "storage_pools", column: "mode", allowedValues: ["local", "replicated"]),
        .init(table: "storage_pools", column: "backing", allowedValues: ["filesystem", "zfs"]),
        .init(
            table: "vms", column: "status",
            allowedValues: [
                "Created", "Running", "Shutdown", "Paused", "Starting", "Stopping", "Error", "Unknown",
            ],
            defaultValue: "Created"
        ),
        .init(
            table: "vms", column: "desired_status",
            allowedValues: ["Running", "Shutdown", "Paused", "Absent"], defaultValue: "Shutdown"
        ),
        .init(
            table: "vms", column: "hypervisor_type", allowedValues: ["qemu", "firecracker"],
            defaultValue: "qemu"
        ),
        .init(
            table: "vms", column: "console_mode",
            allowedValues: ["Off", "Pty", "Tty", "File", "Socket", "Null"], defaultValue: "Pty"
        ),
        .init(
            table: "vms", column: "serial_mode",
            allowedValues: ["Off", "Pty", "Tty", "File", "Socket", "Null"], defaultValue: "Pty"
        ),
        .init(table: "volumes", column: "format", allowedValues: ["qcow2", "raw"], defaultValue: "qcow2"),
        .init(table: "volumes", column: "type", allowedValues: ["boot", "data"], defaultValue: "data"),
        .init(
            table: "volumes", column: "status",
            allowedValues: [
                "creating", "available", "attaching", "attached", "detaching", "resizing", "snapshotting",
                "cloning", "deleting", "error",
            ],
            defaultValue: "creating"
        ),
        .init(
            table: "volume_replicas", column: "state",
            allowedValues: ["provisioning", "healthy", "degraded", "resyncing", "faulted"]
        ),
        .init(
            table: "volume_snapshots", column: "status",
            allowedValues: ["creating", "available", "restoring", "deleting", "error"],
            defaultValue: "creating"
        ),
    ]

    func prepare(on database: Database) async throws {
        let sql = try Self.sqlDatabase(database)
        let constraints = Self.constraints.filter(Self.shouldInstall)

        // Normalize every column before validating any of them. If validation
        // finds a truly unknown value, no constraints have been partially
        // installed and the diagnostic tells the operator what to repair.
        for constraint in constraints {
            try await Self.normalize(constraint, on: sql)
        }
        for constraint in constraints {
            try await Self.validateExistingValues(constraint, on: sql)
        }
        for constraint in constraints {
            try await Self.install(constraint, on: sql)
        }
    }

    func revert(on database: Database) async throws {
        let sql = try Self.sqlDatabase(database)
        for constraint in Self.constraints.reversed() where Self.shouldInstall(constraint) {
            try await Self.uninstall(constraint, on: sql)
        }
    }

    /// Applies one constraint through the same normalize/validate/install flow.
    /// Kept internal so migration tests can exercise it with an isolated table
    /// and a deliberately mis-cased pre-migration value.
    static func prepare(_ constraint: PersistedEnumConstraint, on database: Database) async throws {
        let sql = try sqlDatabase(database)
        guard shouldInstall(constraint) else { return }
        try await normalize(constraint, on: sql)
        try await validateExistingValues(constraint, on: sql)
        try await install(constraint, on: sql)
    }

    static func revert(_ constraint: PersistedEnumConstraint, on database: Database) async throws {
        let sql = try sqlDatabase(database)
        guard shouldInstall(constraint) else { return }
        try await uninstall(constraint, on: sql)
    }

    private static func sqlDatabase(_ database: Database) throws -> any SQLDatabase {
        try PostgresMigrationSQL.database(database)
    }

    /// Columns backed by a native Postgres enum are already constrained by their
    /// type, so a redundant `CHECK` buys nothing.
    private static func shouldInstall(_ constraint: PersistedEnumConstraint) -> Bool {
        !constraint.usesPostgresNativeEnum
    }

    private static func normalize(_ constraint: PersistedEnumConstraint, on sql: any SQLDatabase) async throws {
        let table = identifier(constraint.table)
        let column = identifier(constraint.column)
        let cases = constraint.allowedValues.map { value in
            "WHEN LOWER(\(literal(value))) THEN \(literal(value)) "
                + "WHEN LOWER(\(literal("'\(value)'"))) THEN \(literal(value))"
        }.joined(separator: " ")
        try await execute(
            "UPDATE \(table) SET \(column) = CASE LOWER(CAST(\(column) AS TEXT)) "
                + "\(cases) ELSE \(column) END WHERE \(column) IS NOT NULL",
            on: sql
        )
    }

    private static func validateExistingValues(
        _ constraint: PersistedEnumConstraint,
        on sql: any SQLDatabase
    ) async throws {
        let table = identifier(constraint.table)
        let column = identifier(constraint.column)
        let allowed = constraint.allowedValues.map(literal).joined(separator: ", ")
        let query =
            "SELECT DISTINCT CAST(\(column) AS TEXT) AS value FROM \(table) "
            + "WHERE \(column) IS NOT NULL AND CAST(\(column) AS TEXT) NOT IN (\(allowed)) "
            + "ORDER BY value"
        let rows = try await sql.raw("\(unsafeRaw: query)").all()
        let invalidValues = try rows.map { try $0.decode(column: "value", as: String.self) }
        guard invalidValues.isEmpty else {
            throw PersistedEnumConstraintMigrationError.invalidValues(
                table: constraint.table,
                column: constraint.column,
                values: invalidValues
            )
        }
    }

    private static func install(_ constraint: PersistedEnumConstraint, on sql: any SQLDatabase) async throws {
        let table = identifier(constraint.table)
        let column = identifier(constraint.column)
        let name = identifier(constraint.name)
        let allowed = constraint.allowedValues.map(literal).joined(separator: ", ")

        if let defaultValue = constraint.defaultValue {
            // Older migrations accidentally encoded defaults as strings
            // containing quote characters (for example, `'ready'`); resetting
            // the default repairs that in place.
            try await execute(
                "ALTER TABLE \(table) ALTER COLUMN \(column) SET DEFAULT \(literal(defaultValue))",
                on: sql
            )
        }
        // Make a retry safe if a previous non-transactional migration run
        // installed some constraints before being interrupted.
        try await execute("ALTER TABLE \(table) DROP CONSTRAINT IF EXISTS \(name)", on: sql)
        try await execute(
            "ALTER TABLE \(table) ADD CONSTRAINT \(name) CHECK (\(column) IN (\(allowed)))",
            on: sql
        )
    }

    private static func uninstall(_ constraint: PersistedEnumConstraint, on sql: any SQLDatabase) async throws {
        try await execute(
            "ALTER TABLE \(identifier(constraint.table)) DROP CONSTRAINT IF EXISTS "
                + identifier(constraint.name),
            on: sql
        )
    }

    private static func identifier(_ value: String) -> String {
        PostgresMigrationSQL.identifier(value)
    }

    private static func literal(_ value: String) -> String {
        PostgresMigrationSQL.literal(value)
    }

    private static func execute(_ statement: String, on sql: any SQLDatabase) async throws {
        try await PostgresMigrationSQL.execute(statement, on: sql)
    }
}
