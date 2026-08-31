import Fluent
import SQLKit

/// Adds the fleet-wide MAC ledger and backfills every existing workload NIC
/// without renumbering it (STR-288). Fresh databases already receive these
/// objects from `CurrentSchema.sql`, so every statement is catalog-guarded.
struct CreateMACAddressLedger: AsyncMigration {
    var name: String { "App.CreateMACAddressLedger" }

    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" else {
            throw CreateMACAddressLedgerError.postgresRequired
        }

        let assignments = try await MACAddressAudit.assignments(on: database)
        let invalid = MACAddressAudit.invalidAssignments(in: assignments)
        guard invalid.isEmpty else {
            throw CreateMACAddressLedgerError.invalidExistingAddresses(invalid)
        }
        let duplicates = MACAddressAudit.duplicates(in: assignments)
        guard duplicates.isEmpty else {
            throw CreateMACAddressLedgerError.duplicateExistingAddresses(duplicates)
        }

        try await sql.raw(
            """
            CREATE TABLE IF NOT EXISTS mac_address_allocations (
                mac_address text PRIMARY KEY,
                owner_kind text NOT NULL,
                owner_id uuid NOT NULL,
                created_at timestamp with time zone,
                CONSTRAINT ck_mac_address_allocations_owner_kind
                    CHECK (owner_kind IN ('vm', 'sandbox')),
                CONSTRAINT uq_mac_address_allocations_owner UNIQUE (owner_kind, owner_id)
            )
            """
        ).run()

        for assignment in assignments {
            guard let canonical = assignment.canonicalMACAddress else { continue }
            try await sql.raw(
                """
                INSERT INTO mac_address_allocations (
                    mac_address, owner_kind, owner_id, created_at
                ) VALUES (
                    \(bind: canonical), \(bind: assignment.interfaceKind),
                    \(bind: assignment.interfaceID), now()
                )
                ON CONFLICT DO NOTHING
                """
            ).run()
        }

        for statement in Self.constraintStatements {
            try await sql.raw("\(unsafeRaw: statement)").run()
        }

        try await sql.raw(
            """
            CREATE OR REPLACE FUNCTION public.release_mac_address_allocation()
            RETURNS trigger
            LANGUAGE plpgsql
            AS $str288$
            BEGIN
                DELETE FROM public.mac_address_allocations
                WHERE mac_address = lower(OLD.mac_address)
                  AND owner_kind = TG_ARGV[0]
                  AND owner_id = OLD.id;
                RETURN OLD;
            END;
            $str288$
            """
        ).run()
        for statement in Self.triggerStatements {
            try await sql.raw("\(unsafeRaw: statement)").run()
        }
    }

    /// The fresh-schema baseline may own every object this migration repairs.
    /// Retaining the compatible uniqueness invariant is safe for both database
    /// histories; dropping it on revert would not be.
    func revert(on database: any Database) async throws {}

    private static let constraintStatements = [
        uniqueConstraint(
            table: "vm_network_interfaces",
            constraint: "uq_vm_network_interfaces_mac_address"),
        uniqueConstraint(
            table: "sandbox_network_interfaces",
            constraint: "uq_sandbox_network_interfaces_mac_address"),
    ]

    private static let triggerStatements = [
        releaseTrigger(table: "vm_network_interfaces", trigger: "trg_vm_network_interfaces_release_mac", kind: "vm"),
        releaseTrigger(
            table: "sandbox_network_interfaces", trigger: "trg_sandbox_network_interfaces_release_mac",
            kind: "sandbox"),
    ]

    private static func uniqueConstraint(table: String, constraint: String) -> String {
        """
        DO $str288$
        BEGIN
            IF NOT EXISTS (
                SELECT 1 FROM pg_constraint
                WHERE conname = '\(constraint)'
                  AND conrelid = 'public.\(table)'::regclass
            ) THEN
                ALTER TABLE public.\(table)
                    ADD CONSTRAINT \(constraint) UNIQUE (mac_address);
            END IF;
        END
        $str288$
        """
    }

    private static func releaseTrigger(table: String, trigger: String, kind: String) -> String {
        """
        DO $str288$
        BEGIN
            IF NOT EXISTS (
                SELECT 1 FROM pg_trigger
                WHERE tgname = '\(trigger)'
                  AND tgrelid = 'public.\(table)'::regclass
            ) THEN
                CREATE TRIGGER \(trigger)
                AFTER DELETE ON public.\(table)
                FOR EACH ROW EXECUTE FUNCTION public.release_mac_address_allocation('\(kind)');
            END IF;
        END
        $str288$
        """
    }
}

enum CreateMACAddressLedgerError: Error, CustomStringConvertible {
    case postgresRequired
    case invalidExistingAddresses([MACAddressAudit.Assignment])
    case duplicateExistingAddresses([MACAddressAudit.Duplicate])

    var description: String {
        switch self {
        case .postgresRequired:
            return "The MAC address ledger requires PostgreSQL"
        case .invalidExistingAddresses(let assignments):
            return "Cannot create the MAC address ledger: invalid existing addresses: "
                + assignments.map { "\($0.label)=\($0.storedMACAddress)" }.joined(separator: ", ")
        case .duplicateExistingAddresses(let duplicates):
            return "Cannot create the MAC address ledger: duplicate existing addresses: "
                + duplicates.map { duplicate in
                    "\(duplicate.macAddress) [\(duplicate.assignments.map(\.label).joined(separator: ", "))]"
                }.joined(separator: "; ")
        }
    }
}
