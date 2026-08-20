import Fluent
import Foundation
import SQLKit
import StratoShared
import Vapor

struct InterfaceAddressSnapshot: Equatable, Sendable, InterfaceAddressRow {
    let id: UUID
    let interfaceID: UUID
    let logicalNetworkID: UUID
    let family: String
    let address: String
    let prefixLength: Int
    let gateway: String?
    let createdAt: Date?
    let updatedAt: Date?

    var ipFamily: IPFamily? { IPFamily(rawValue: family) }
}

/// Immutable SQL bridge for the VM and sandbox address tables. The allowlisted
/// workload kind supplies structure; every address value remains bound.
enum LegacyInterfaceAddressStore {
    static func addresses(
        kind: InterfaceWorkloadKind,
        interfaceIDs: [UUID]? = nil,
        logicalNetworkID: UUID? = nil,
        family: IPFamily? = nil,
        on db: any Database
    ) async throws -> [InterfaceAddressSnapshot] {
        if let interfaceIDs, interfaceIDs.isEmpty { return [] }
        let sql = try requireSQL(db)
        var query: SQLQueryString =
            "SELECT \(unsafeRaw: columns) FROM \(unsafeRaw: addressTable(for: kind)) WHERE TRUE"
        if let interfaceIDs { query += " AND interface_id = ANY(\(bind: interfaceIDs))" }
        if let logicalNetworkID { query += " AND logical_network_id = \(bind: logicalNetworkID)" }
        if let family { query += " AND family = \(bind: family.rawValue)" }
        query += " ORDER BY family, address, id"
        return try await sql.raw(query).all(decoding: Record.self).map(\.snapshot)
    }

    static func address(
        kind: InterfaceWorkloadKind,
        id: UUID,
        on db: any Database
    ) async throws -> InterfaceAddressSnapshot? {
        try await requireSQL(db).raw(
            """
            SELECT \(unsafeRaw: columns)
            FROM \(unsafeRaw: addressTable(for: kind))
            WHERE id = \(bind: id)
            LIMIT 1
            """
        ).first(decoding: Record.self)?.snapshot
    }

    @discardableResult
    static func insert(
        kind: InterfaceWorkloadKind,
        id: UUID = UUID(),
        interfaceID: UUID,
        logicalNetworkID: UUID,
        family: IPFamily,
        address: String,
        prefixLength: Int,
        gateway: String? = nil,
        on db: any Database
    ) async throws -> InterfaceAddressSnapshot {
        guard let row = try await requireSQL(db).raw(
            """
            INSERT INTO \(unsafeRaw: addressTable(for: kind)) (
                id, interface_id, logical_network_id, family, address,
                prefix_length, gateway, created_at, updated_at
            ) VALUES (
                \(bind: id), \(bind: interfaceID), \(bind: logicalNetworkID),
                \(bind: family.rawValue), \(bind: address), \(bind: prefixLength),
                \(bind: gateway), CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
            )
            RETURNING \(unsafeRaw: columns)
            """
        ).first(decoding: Record.self) else {
            throw Abort(.internalServerError, reason: "Could not create interface address")
        }
        return row.snapshot
    }

    static func count(
        kind: InterfaceWorkloadKind,
        interfaceIDs: [UUID]? = nil,
        logicalNetworkID: UUID? = nil,
        family: IPFamily? = nil,
        on db: any Database
    ) async throws -> Int {
        if let interfaceIDs, interfaceIDs.isEmpty { return 0 }
        struct Count: Decodable { let count: Int }
        let sql = try requireSQL(db)
        var query: SQLQueryString =
            "SELECT count(*)::bigint AS count FROM \(unsafeRaw: addressTable(for: kind)) WHERE TRUE"
        if let interfaceIDs { query += " AND interface_id = ANY(\(bind: interfaceIDs))" }
        if let logicalNetworkID { query += " AND logical_network_id = \(bind: logicalNetworkID)" }
        if let family { query += " AND family = \(bind: family.rawValue)" }
        return try await sql.raw(query).first(decoding: Count.self)?.count ?? 0
    }

    static func addressesByInterface(
        kind: InterfaceWorkloadKind,
        interfaceIDs: [UUID],
        on db: any Database
    ) async throws -> [UUID: [InterfaceAddressSnapshot]] {
        Dictionary(grouping: try await addresses(
            kind: kind, interfaceIDs: interfaceIDs, on: db), by: \.interfaceID)
    }

    static func loading(
        _ interfaces: [VMNetworkInterface],
        on db: any Database
    ) async throws -> [VMNetworkInterface] {
        let byInterface = try await addressesByInterface(
            kind: .vm, interfaceIDs: interfaces.compactMap(\.id), on: db)
        return interfaces.map { interface in
            interface.loading(addresses: interface.id.flatMap { byInterface[$0] } ?? [])
        }
    }

    static func loading(
        _ interfaces: [SandboxNetworkInterface],
        on db: any Database
    ) async throws -> [SandboxNetworkInterface] {
        let byInterface = try await addressesByInterface(
            kind: .sandbox, interfaceIDs: interfaces.compactMap(\.id), on: db)
        return interfaces.map { interface in
            interface.loading(addresses: interface.id.flatMap { byInterface[$0] } ?? [])
        }
    }

    private struct Record: Decodable, Sendable {
        let id: UUID
        let interfaceID: UUID
        let logicalNetworkID: UUID
        let family: String
        let address: String
        let prefixLength: Int
        let gateway: String?
        let createdAt: Date?
        let updatedAt: Date?

        var snapshot: InterfaceAddressSnapshot {
            InterfaceAddressSnapshot(
                id: id,
                interfaceID: interfaceID,
                logicalNetworkID: logicalNetworkID,
                family: family,
                address: address,
                prefixLength: prefixLength,
                gateway: gateway,
                createdAt: createdAt,
                updatedAt: updatedAt)
        }
    }

    private static let columns = """
        id,
        interface_id AS "interfaceID",
        logical_network_id AS "logicalNetworkID",
        family,
        address,
        prefix_length AS "prefixLength",
        gateway,
        created_at AS "createdAt",
        updated_at AS "updatedAt"
        """

    private static func addressTable(for kind: InterfaceWorkloadKind) -> String {
        switch kind {
        case .vm: "vm_interface_addresses"
        case .sandbox: "sandbox_interface_addresses"
        }
    }

    private static func requireSQL(_ db: any Database) throws -> any SQLDatabase {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Interface addresses require PostgreSQL")
        }
        return sql
    }
}
