import ControlPlanePostgres
import Foundation
import Vapor

/// Immutable persistence snapshot for one sandbox NIC.
///
/// Address rows are loaded explicitly. `nil` means the caller did not request
/// them, while an empty array means the NIC has no allocated addresses.
struct SandboxNetworkInterface: Equatable, Sendable {
    static let schema = "sandbox_network_interfaces"

    let id: UUID?
    let sandboxID: UUID
    let logicalNetworkID: UUID
    let logicalNetworkName: String?
    let macAddress: String
    let loadedAddresses: [InterfaceAddressSnapshot]?
    let mtu: Int?
    let deviceName: String
    let createdAt: Date?
    let updatedAt: Date?

    init(
        id: UUID? = nil,
        sandboxID: UUID,
        logicalNetworkID: UUID,
        logicalNetworkName: String? = nil,
        macAddress: String,
        loadedAddresses: [InterfaceAddressSnapshot]? = nil,
        mtu: Int? = nil,
        deviceName: String = "net0",
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id ?? UUID()
        self.sandboxID = sandboxID
        self.logicalNetworkID = logicalNetworkID
        self.logicalNetworkName = logicalNetworkName
        self.macAddress = macAddress
        self.loadedAddresses = loadedAddresses
        self.mtu = mtu
        self.deviceName = deviceName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func requireID() throws -> UUID {
        guard let id else {
            throw Abort(.internalServerError, reason: "Sandbox interface has no identifier")
        }
        return id
    }

    func loading(addresses: [InterfaceAddressSnapshot]) -> Self {
        Self(
            id: id,
            sandboxID: sandboxID,
            logicalNetworkID: logicalNetworkID,
            logicalNetworkName: logicalNetworkName,
            macAddress: macAddress,
            loadedAddresses: addresses,
            mtu: mtu,
            deviceName: deviceName,
            createdAt: createdAt,
            updatedAt: updatedAt)
    }

    /// Transitional test-builder convenience. Production uses the intent-
    /// oriented insert operation below and receives the returned snapshot.
    @discardableResult
    func save(on db: PostgresStoreContext) async throws -> Self {
        try await LegacySandboxNetworkInterfaceStore.insert(self, on: db)
    }
}

/// Explicit SQL bridge for sandbox NIC rows while the surrounding sandbox
/// aggregate is moved to PostgresNIO. Query structure is fixed and every
/// caller-controlled value remains bound.
enum LegacySandboxNetworkInterfaceStore {
    static func interfaces(
        sandboxIDs: [UUID]? = nil,
        logicalNetworkID: UUID? = nil,
        on db: PostgresStoreContext
    ) async throws -> [SandboxNetworkInterface] {
        if let sandboxIDs, sandboxIDs.isEmpty { return [] }
        let sql = try requireSQL(db)
        var query: PostgresSQLQuery =
            "SELECT \(unsafeRaw: columns) FROM sandbox_network_interfaces AS sni LEFT JOIN logical_networks AS ln ON ln.id = sni.logical_network_id WHERE TRUE"
        if let sandboxIDs { query += " AND sni.sandbox_id = ANY(\(bind: sandboxIDs))" }
        if let logicalNetworkID { query += " AND sni.logical_network_id = \(bind: logicalNetworkID)" }
        query += " ORDER BY sni.device_name, sni.id"
        return try await sql.raw(query).all(decoding: Record.self).map(\.snapshot)
    }

    static func interfaces(sandboxID: UUID, on db: PostgresStoreContext) async throws
        -> [SandboxNetworkInterface]
    {
        try await interfaces(sandboxIDs: [sandboxID], on: db)
    }

    static func loading(_ sandboxes: [Sandbox], on db: PostgresStoreContext) async throws -> [Sandbox] {
        let sandboxIDs = sandboxes.compactMap(\.id)
        let bySandbox = Dictionary(
            grouping: try await interfaces(sandboxIDs: sandboxIDs, on: db),
            by: \.sandboxID)
        return sandboxes.map { sandbox in
            sandbox.loadingNetworkInterfaces(sandbox.id.flatMap { bySandbox[$0] } ?? [])
        }
    }

    static func loadingWithAddresses(_ sandboxes: [Sandbox], on db: PostgresStoreContext) async throws
        -> [Sandbox]
    {
        let loaded = try await loading(sandboxes, on: db)
        let detailed = try await LegacyInterfaceAddressStore.loading(
            loaded.flatMap(\.networkInterfaces), on: db)
        let bySandbox = Dictionary(grouping: detailed, by: \.sandboxID)
        return loaded.map { sandbox in
            sandbox.loadingNetworkInterfaces(sandbox.id.flatMap { bySandbox[$0] } ?? [])
        }
    }

    @discardableResult
    static func insert(_ interface: SandboxNetworkInterface, on db: PostgresStoreContext) async throws
        -> SandboxNetworkInterface
    {
        let id = try interface.requireID()
        guard let record = try await requireSQL(db).raw(
            """
            INSERT INTO sandbox_network_interfaces (
                id, sandbox_id, logical_network_id, mac_address, mtu,
                device_name, created_at, updated_at
            ) VALUES (
                \(bind: id), \(bind: interface.sandboxID),
                \(bind: interface.logicalNetworkID), \(bind: interface.macAddress),
                \(bind: interface.mtu), \(bind: interface.deviceName),
                CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
            )
            RETURNING
                id, sandbox_id AS "sandboxID",
                logical_network_id AS "logicalNetworkID",
                NULL::text AS "logicalNetworkName", mac_address AS "macAddress",
                mtu, device_name AS "deviceName",
                created_at AS "createdAt", updated_at AS "updatedAt"
            """
        ).first(decoding: Record.self) else {
            throw Abort(.internalServerError, reason: "Could not create sandbox network interface")
        }
        return record.snapshot
    }

    static func count(logicalNetworkID: UUID, on db: PostgresStoreContext) async throws -> Int {
        struct Count: Decodable { let count: Int }
        return try await requireSQL(db).raw(
            """
            SELECT count(*)::bigint AS count
            FROM sandbox_network_interfaces
            WHERE logical_network_id = \(bind: logicalNetworkID)
            """
        ).first(decoding: Count.self)?.count ?? 0
    }

    private struct Record: Decodable, Sendable {
        let id: UUID
        let sandboxID: UUID
        let logicalNetworkID: UUID
        let logicalNetworkName: String?
        let macAddress: String
        let mtu: Int?
        let deviceName: String
        let createdAt: Date?
        let updatedAt: Date?

        var snapshot: SandboxNetworkInterface {
            SandboxNetworkInterface(
                id: id,
                sandboxID: sandboxID,
                logicalNetworkID: logicalNetworkID,
                logicalNetworkName: logicalNetworkName,
                macAddress: macAddress,
                mtu: mtu,
                deviceName: deviceName,
                createdAt: createdAt,
                updatedAt: updatedAt)
        }
    }

    private static let columns = """
        sni.id,
        sni.sandbox_id AS "sandboxID",
        sni.logical_network_id AS "logicalNetworkID",
        ln.name AS "logicalNetworkName",
        sni.mac_address AS "macAddress",
        sni.mtu,
        sni.device_name AS "deviceName",
        sni.created_at AS "createdAt",
        sni.updated_at AS "updatedAt"
        """

    private static func requireSQL(_ db: PostgresStoreContext) throws -> PostgresStoreContext {
        guard let sql = db as? PostgresStoreContext else {
            throw Abort(.internalServerError, reason: "Sandbox interfaces require PostgreSQL")
        }
        return sql
    }
}
