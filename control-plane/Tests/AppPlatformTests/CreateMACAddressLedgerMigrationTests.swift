import AppTestSupport
import SQLKit
import Testing
import Vapor

@testable import App

@Suite("Create MAC address ledger migration", .serialized)
struct CreateMACAddressLedgerMigrationTests {
    @Test("Backfills both interface families and installs all uniqueness constraints")
    func backfillsAndConstrains() async throws {
        let app = try await legacyInterfaceDatabase()
        do {
            let sql = try #require(app.db as? any SQLDatabase)
            let vmID = UUID()
            let sandboxID = UUID()
            try await sql.raw(
                "INSERT INTO vm_network_interfaces (id, mac_address) VALUES (\(bind: vmID), '00:0C:29:00:00:01')"
            ).run()
            try await sql.raw(
                "INSERT INTO sandbox_network_interfaces (id, mac_address) VALUES (\(bind: sandboxID), '00:0c:29:00:00:02')"
            ).run()

            let migration = CreateMACAddressLedger()
            try await migration.prepare(on: app.db)
            try await migration.prepare(on: app.db)

            let rows = try await sql.raw(
                "SELECT mac_address, owner_kind, owner_id FROM mac_address_allocations ORDER BY mac_address"
            ).all(decoding: LedgerRow.self)
            #expect(
                rows == [
                    LedgerRow(macAddress: "00:0c:29:00:00:01", ownerKind: "vm", ownerID: vmID),
                    LedgerRow(macAddress: "00:0c:29:00:00:02", ownerKind: "sandbox", ownerID: sandboxID),
                ])

            let constraintNames = try await sql.raw(
                """
                SELECT conname
                FROM pg_constraint
                WHERE conname IN (
                    'uq_vm_network_interfaces_mac_address',
                    'uq_sandbox_network_interfaces_mac_address'
                )
                ORDER BY conname
                """
            ).all(decodingColumn: "conname", as: String.self)
            #expect(
                constraintNames == [
                    "uq_sandbox_network_interfaces_mac_address",
                    "uq_vm_network_interfaces_mac_address",
                ])
        } catch {
            try? await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    @Test("A legacy cross-table duplicate fails loudly with both interface ids")
    func duplicateFailsLoudly() async throws {
        let app = try await legacyInterfaceDatabase()
        do {
            let sql = try #require(app.db as? any SQLDatabase)
            let vmID = UUID()
            let sandboxID = UUID()
            try await sql.raw(
                "INSERT INTO vm_network_interfaces (id, mac_address) VALUES (\(bind: vmID), '00:0C:29:AA:BB:CC')"
            ).run()
            try await sql.raw(
                "INSERT INTO sandbox_network_interfaces (id, mac_address) VALUES (\(bind: sandboxID), '00:0c:29:aa:bb:cc')"
            ).run()

            var thrown: (any Error)?
            do {
                try await CreateMACAddressLedger().prepare(on: app.db)
            } catch {
                thrown = error
            }
            let message = String(describing: try #require(thrown))
            #expect(message.contains("duplicate existing addresses"))
            #expect(message.contains(vmID.uuidString))
            #expect(message.contains(sandboxID.uuidString))
            #expect(message.contains("00:0c:29:aa:bb:cc"))

            let ledgerExists = try await sql.raw(
                "SELECT to_regclass('public.mac_address_allocations') IS NOT NULL AS present"
            ).first(decodingColumn: "present", as: Bool.self)
            #expect(ledgerExists == false)
        } catch {
            try? await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    private func legacyInterfaceDatabase() async throws -> Application {
        let app = try await Application.makeForBareDatabaseTesting()
        let sql = try #require(app.db as? any SQLDatabase)
        try await sql.raw("CREATE TABLE vm_network_interfaces (id uuid PRIMARY KEY, mac_address text NOT NULL)").run()
        try await sql.raw(
            "CREATE TABLE sandbox_network_interfaces (id uuid PRIMARY KEY, mac_address text NOT NULL)"
        ).run()
        return app
    }
}

private struct LedgerRow: Decodable, Equatable {
    let macAddress: String
    let ownerKind: String
    let ownerID: UUID

    enum CodingKeys: String, CodingKey {
        case macAddress = "mac_address"
        case ownerKind = "owner_kind"
        case ownerID = "owner_id"
    }
}
