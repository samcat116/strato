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
    case unsupportedDatabase(String)
    case invalidValues(table: String, column: String, values: [String])

    var description: String {
        switch self {
        case .unsupportedDatabase(let dialect):
            return "Cannot enforce persisted enum values on unsupported SQL dialect '\(dialect)'"
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
/// 3. PostgreSQL receives `CHECK` constraints for all string-backed columns.
///    Its native `agent_status` enum already provides the same guarantee.
/// 4. SQLite receives equivalent insert/update validation triggers because it
///    cannot add `CHECK` constraints to existing tables.
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
        .init(
            table: "resource_operations", column: "resource_kind",
            allowedValues: ["virtual_machine", "sandbox"], defaultValue: "virtual_machine"
        ),
        .init(
            table: "resource_operations", column: "kind",
            allowedValues: [
                "create", "boot", "shutdown", "reboot", "pause", "resume", "delete", "snapshot",
                "snapshot_delete", "restore",
            ]
        ),
        .init(
            table: "resource_operations", column: "status",
            allowedValues: ["pending", "succeeded", "failed"]
        ),
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
        let constraints = Self.constraints.filter { Self.shouldInstall($0, dialect: sql.dialect.name) }

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
        for constraint in Self.constraints.reversed()
        where Self.shouldInstall(constraint, dialect: sql.dialect.name) {
            try await Self.uninstall(constraint, on: sql)
        }
    }

    /// Applies one constraint through the same normalize/validate/install flow.
    /// Kept internal so migration tests can exercise both database engines with
    /// an isolated table and a deliberately mis-cased pre-migration value.
    static func prepare(_ constraint: PersistedEnumConstraint, on database: Database) async throws {
        let sql = try sqlDatabase(database)
        guard shouldInstall(constraint, dialect: sql.dialect.name) else { return }
        try await normalize(constraint, on: sql)
        try await validateExistingValues(constraint, on: sql)
        try await install(constraint, on: sql)
    }

    static func revert(_ constraint: PersistedEnumConstraint, on database: Database) async throws {
        let sql = try sqlDatabase(database)
        guard shouldInstall(constraint, dialect: sql.dialect.name) else { return }
        try await uninstall(constraint, on: sql)
    }

    private static func sqlDatabase(_ database: Database) throws -> any SQLDatabase {
        guard let sql = database as? any SQLDatabase else {
            throw PersistedEnumConstraintMigrationError.unsupportedDatabase("non-SQL")
        }
        guard sql.dialect.name == "postgresql" || sql.dialect.name == "sqlite" else {
            throw PersistedEnumConstraintMigrationError.unsupportedDatabase(sql.dialect.name)
        }
        return sql
    }

    private static func shouldInstall(_ constraint: PersistedEnumConstraint, dialect: String) -> Bool {
        !(dialect == "postgresql" && constraint.usesPostgresNativeEnum)
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

        switch sql.dialect.name {
        case "postgresql":
            if let defaultValue = constraint.defaultValue {
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
        case "sqlite":
            let message = literal("invalid enum value for \(constraint.table).\(constraint.column)")
            for operation in ["insert", "update"] {
                let triggerName = identifier("\(constraint.name)_\(operation)")
                try await execute("DROP TRIGGER IF EXISTS \(triggerName)", on: sql)
                let event = operation == "insert" ? "INSERT" : "UPDATE OF \(column)"
                let legacyDefaultException: String
                if operation == "insert", let defaultValue = constraint.defaultValue {
                    legacyDefaultException =
                        " AND LOWER(NEW.\(column)) != LOWER(\(literal("'\(defaultValue)'"))) "
                } else {
                    legacyDefaultException = ""
                }
                try await execute(
                    "CREATE TRIGGER \(triggerName) BEFORE \(event) ON \(table) FOR EACH ROW "
                        + "WHEN NEW.\(column) IS NOT NULL AND NEW.\(column) NOT IN (\(allowed)) "
                        + legacyDefaultException
                        + "BEGIN SELECT RAISE(ABORT, \(message)); END",
                    on: sql
                )
            }
            if let defaultValue = constraint.defaultValue {
                // Older migrations accidentally encoded defaults as strings
                // containing quote characters (for example, `'ready'`).
                // SQLite cannot alter a column default in place, so normalize
                // that legacy default immediately after an omitted-field insert.
                let triggerName = identifier("\(constraint.name)_normalize_default")
                try await execute("DROP TRIGGER IF EXISTS \(triggerName)", on: sql)
                try await execute(
                    "CREATE TRIGGER \(triggerName) AFTER INSERT ON \(table) FOR EACH ROW "
                        + "WHEN LOWER(NEW.\(column)) = LOWER(\(literal("'\(defaultValue)'"))) "
                        + "BEGIN UPDATE \(table) SET \(column) = \(literal(defaultValue)) "
                        + "WHERE rowid = NEW.rowid; END",
                    on: sql
                )
            }
        default:
            throw PersistedEnumConstraintMigrationError.unsupportedDatabase(sql.dialect.name)
        }
    }

    private static func uninstall(_ constraint: PersistedEnumConstraint, on sql: any SQLDatabase) async throws {
        switch sql.dialect.name {
        case "postgresql":
            try await execute(
                "ALTER TABLE \(identifier(constraint.table)) DROP CONSTRAINT IF EXISTS "
                    + identifier(constraint.name),
                on: sql
            )
        case "sqlite":
            for operation in ["insert", "update", "normalize_default"] {
                try await execute(
                    "DROP TRIGGER IF EXISTS \(identifier("\(constraint.name)_\(operation)"))",
                    on: sql
                )
            }
        default:
            throw PersistedEnumConstraintMigrationError.unsupportedDatabase(sql.dialect.name)
        }
    }

    private static func identifier(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func literal(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private static func execute(_ statement: String, on sql: any SQLDatabase) async throws {
        try await sql.raw("\(unsafeRaw: statement)").run()
    }
}
