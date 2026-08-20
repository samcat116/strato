import Fluent
import Foundation
import SQLKit
import Vapor

/// Immutable persistence snapshot for one VM network interface.
struct VMNetworkInterface: Equatable, Sendable {
    static let schema = "vm_network_interfaces"
    static let maxInterfacesPerVM = 8

    let id: UUID?
    let vmID: UUID
    let logicalNetworkID: UUID
    let logicalNetworkName: String?
    let macAddress: String
    let loadedAddresses: [InterfaceAddressSnapshot]?
    let mtu: Int?
    let deviceName: String
    let orderIndex: Int
    let attachGeneration: Int64?
    let detachGeneration: Int64?
    let createdAt: Date?
    let updatedAt: Date?

    init(
        id: UUID? = nil,
        vmID: UUID,
        logicalNetworkID: UUID,
        logicalNetworkName: String? = nil,
        macAddress: String,
        loadedAddresses: [InterfaceAddressSnapshot]? = nil,
        mtu: Int? = nil,
        deviceName: String = "net0",
        orderIndex: Int = 0,
        attachGeneration: Int64? = nil,
        detachGeneration: Int64? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id ?? UUID()
        self.vmID = vmID
        self.logicalNetworkID = logicalNetworkID
        self.logicalNetworkName = logicalNetworkName
        self.macAddress = macAddress
        self.loadedAddresses = loadedAddresses
        self.mtu = mtu
        self.deviceName = deviceName
        self.orderIndex = orderIndex
        self.attachGeneration = attachGeneration
        self.detachGeneration = detachGeneration
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func requireID() throws -> UUID {
        guard let id else {
            throw Abort(.internalServerError, reason: "VM interface has no identifier")
        }
        return id
    }

    func loading(addresses: [InterfaceAddressSnapshot]) -> Self {
        Self(
            id: id,
            vmID: vmID,
            logicalNetworkID: logicalNetworkID,
            logicalNetworkName: logicalNetworkName,
            macAddress: macAddress,
            loadedAddresses: addresses,
            mtu: mtu,
            deviceName: deviceName,
            orderIndex: orderIndex,
            attachGeneration: attachGeneration,
            detachGeneration: detachGeneration,
            createdAt: createdAt,
            updatedAt: updatedAt)
    }

    static func generateMACAddress() -> String {
        let randomBytes = (0..<3).map { _ in String(format: "%02x", Int.random(in: 0...255)) }
        return "00:0c:29:\(randomBytes.joined(separator: ":"))"
    }

    /// Transitional test-builder convenience. Production uses the store's
    /// insert operation and consumes its returned snapshot.
    @discardableResult
    func save(on db: any Database) async throws -> Self {
        try await LegacyVMNetworkInterfaceStore.insert(self, on: db)
    }
}

extension Sequence where Element == VMNetworkInterface {
    var inDeviceOrder: [VMNetworkInterface] {
        sorted { ($0.orderIndex, $0.deviceName) < ($1.orderIndex, $1.deviceName) }
    }
}

/// Explicit SQL bridge for VM NICs while the VM aggregate is moved to the
/// native PostgresNIO workload module.
enum LegacyVMNetworkInterfaceStore {
    static func interfaces(
        vmIDs: [UUID]? = nil,
        ids: [UUID]? = nil,
        logicalNetworkID: UUID? = nil,
        logicalNetworkIDs: [UUID]? = nil,
        on db: any Database
    ) async throws -> [VMNetworkInterface] {
        if let vmIDs, vmIDs.isEmpty { return [] }
        if let ids, ids.isEmpty { return [] }
        if let logicalNetworkIDs, logicalNetworkIDs.isEmpty { return [] }
        let sql = try requireSQL(db)
        var query: SQLQueryString =
            "SELECT \(unsafeRaw: columns) FROM vm_network_interfaces AS vni LEFT JOIN logical_networks AS ln ON ln.id = vni.logical_network_id WHERE TRUE"
        if let vmIDs { query += " AND vni.vm_id = ANY(\(bind: vmIDs))" }
        if let ids { query += " AND vni.id = ANY(\(bind: ids))" }
        if let logicalNetworkID { query += " AND vni.logical_network_id = \(bind: logicalNetworkID)" }
        if let logicalNetworkIDs {
            query += " AND vni.logical_network_id = ANY(\(bind: logicalNetworkIDs))"
        }
        query += " ORDER BY vni.order_index, vni.device_name, vni.id"
        return try await sql.raw(query).all(decoding: Record.self).map(\.snapshot)
    }

    static func interfaces(vmID: UUID, on db: any Database) async throws -> [VMNetworkInterface] {
        try await interfaces(vmIDs: [vmID], on: db)
    }

    static func interface(id: UUID, vmID: UUID? = nil, on db: any Database) async throws
        -> VMNetworkInterface?
    {
        let matches = try await interfaces(vmIDs: vmID.map { [$0] }, ids: [id], on: db)
        guard matches.count <= 1 else {
            throw Abort(.internalServerError, reason: "VM interface lookup returned duplicate rows")
        }
        return matches.first
    }

    static func interface(vmID: UUID, orderIndex: Int, on db: any Database) async throws
        -> VMNetworkInterface?
    {
        try await interfaces(vmID: vmID, on: db).first { $0.orderIndex == orderIndex }
    }

    static func loading(_ vms: [VM], on db: any Database) async throws -> [VM] {
        let byVM = Dictionary(
            grouping: try await interfaces(vmIDs: vms.compactMap(\.id), on: db),
            by: \.vmID)
        return vms.map { vm in
            vm.loadingNetworkInterfaces(vm.id.flatMap { byVM[$0] } ?? [])
        }
    }

    static func loadingWithAddresses(_ vms: [VM], on db: any Database) async throws -> [VM] {
        let loaded = try await loading(vms, on: db)
        let detailed = try await LegacyInterfaceAddressStore.loading(
            loaded.flatMap(\.networkInterfaces), on: db)
        let byVM = Dictionary(grouping: detailed, by: \.vmID)
        return loaded.map { vm in
            vm.loadingNetworkInterfaces(vm.id.flatMap { byVM[$0] } ?? [])
        }
    }

    @discardableResult
    static func insert(_ interface: VMNetworkInterface, on db: any Database) async throws
        -> VMNetworkInterface
    {
        let id = try interface.requireID()
        guard let row = try await requireSQL(db).raw(
            """
            INSERT INTO vm_network_interfaces (
                id, vm_id, logical_network_id, mac_address, mtu, device_name,
                order_index, attach_generation, detach_generation,
                created_at, updated_at
            ) VALUES (
                \(bind: id), \(bind: interface.vmID), \(bind: interface.logicalNetworkID),
                \(bind: interface.macAddress), \(bind: interface.mtu),
                \(bind: interface.deviceName), \(bind: interface.orderIndex),
                \(bind: interface.attachGeneration), \(bind: interface.detachGeneration),
                CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
            )
            RETURNING
                id, vm_id AS "vmID", logical_network_id AS "logicalNetworkID",
                NULL::text AS "logicalNetworkName", mac_address AS "macAddress",
                mtu, device_name AS "deviceName", order_index AS "orderIndex",
                attach_generation AS "attachGeneration",
                detach_generation AS "detachGeneration",
                created_at AS "createdAt", updated_at AS "updatedAt"
            """
        ).first(decoding: Record.self) else {
            throw Abort(.internalServerError, reason: "Could not create VM network interface")
        }
        return row.snapshot
    }

    @discardableResult
    static func updateGenerations(
        id: UUID,
        attachGeneration: Int64?,
        detachGeneration: Int64?,
        on db: any Database
    ) async throws -> VMNetworkInterface? {
        try await requireSQL(db).raw(
            """
            UPDATE vm_network_interfaces
            SET attach_generation = \(bind: attachGeneration),
                detach_generation = \(bind: detachGeneration),
                updated_at = CURRENT_TIMESTAMP
            WHERE id = \(bind: id)
            RETURNING
                id, vm_id AS "vmID", logical_network_id AS "logicalNetworkID",
                NULL::text AS "logicalNetworkName", mac_address AS "macAddress",
                mtu, device_name AS "deviceName", order_index AS "orderIndex",
                attach_generation AS "attachGeneration",
                detach_generation AS "detachGeneration",
                created_at AS "createdAt", updated_at AS "updatedAt"
            """
        ).first(decoding: Record.self)?.snapshot
    }

    @discardableResult
    static func delete(id: UUID, on db: any Database) async throws -> UUID? {
        struct Deleted: Decodable { let id: UUID }
        return try await requireSQL(db).raw(
            "DELETE FROM vm_network_interfaces WHERE id = \(bind: id) RETURNING id"
        ).first(decoding: Deleted.self)?.id
    }

    static func count(logicalNetworkID: UUID, on db: any Database) async throws -> Int {
        struct Count: Decodable { let count: Int }
        return try await requireSQL(db).raw(
            """
            SELECT count(*)::bigint AS count
            FROM vm_network_interfaces
            WHERE logical_network_id = \(bind: logicalNetworkID)
            """
        ).first(decoding: Count.self)?.count ?? 0
    }

    static func hostnameExists(
        _ hostname: String,
        logicalNetworkIDs: [UUID],
        excludingVMID: UUID?,
        on db: any Database
    ) async throws -> Bool {
        if logicalNetworkIDs.isEmpty { return false }
        struct Exists: Decodable { let exists: Bool }
        var query: SQLQueryString = """
            SELECT EXISTS(
                SELECT 1
                FROM vms AS vm
                JOIN vm_network_interfaces AS vni ON vni.vm_id = vm.id
                WHERE vni.logical_network_id = ANY(\(bind: logicalNetworkIDs))
                  AND vm.hostname = \(bind: hostname)
            """
        if let excludingVMID { query += " AND vm.id <> \(bind: excludingVMID)" }
        query += ") AS exists"
        return try await requireSQL(db).raw(query).first(decoding: Exists.self)?.exists ?? false
    }

    private struct Record: Decodable, Sendable {
        let id: UUID
        let vmID: UUID
        let logicalNetworkID: UUID
        let logicalNetworkName: String?
        let macAddress: String
        let mtu: Int?
        let deviceName: String
        let orderIndex: Int
        let attachGeneration: Int64?
        let detachGeneration: Int64?
        let createdAt: Date?
        let updatedAt: Date?

        var snapshot: VMNetworkInterface {
            VMNetworkInterface(
                id: id,
                vmID: vmID,
                logicalNetworkID: logicalNetworkID,
                logicalNetworkName: logicalNetworkName,
                macAddress: macAddress,
                mtu: mtu,
                deviceName: deviceName,
                orderIndex: orderIndex,
                attachGeneration: attachGeneration,
                detachGeneration: detachGeneration,
                createdAt: createdAt,
                updatedAt: updatedAt)
        }
    }

    private static let columns = """
        vni.id,
        vni.vm_id AS "vmID",
        vni.logical_network_id AS "logicalNetworkID",
        ln.name AS "logicalNetworkName",
        vni.mac_address AS "macAddress",
        vni.mtu,
        vni.device_name AS "deviceName",
        vni.order_index AS "orderIndex",
        vni.attach_generation AS "attachGeneration",
        vni.detach_generation AS "detachGeneration",
        vni.created_at AS "createdAt",
        vni.updated_at AS "updatedAt"
        """

    private static func requireSQL(_ db: any Database) throws -> any SQLDatabase {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "VM interfaces require PostgreSQL")
        }
        return sql
    }
}
