import Foundation
import PostgresNIO
import StratoShared

/// The operator-controlled storage intent. `osd` only marks a disk as eligible
/// for a later Ceph orchestration phase; it does not format the device.
public enum StorageDeviceRole: String, Codable, CaseIterable, Sendable {
    case unassigned
    case osd
    case excluded
}

/// Immutable durable state for one whole physical disk reported by an agent.
public struct StorageDeviceSnapshot: Equatable, Sendable {
    public let id: UUID
    public let agentID: UUID
    public let identityKind: StorageDeviceIdentityKind?
    public let identityValue: String?
    public let devicePath: String
    public let sizeBytes: Int64
    public let model: String?
    public let serial: String?
    public let wwn: String?
    public let rotational: Bool
    public let uses: [StorageDeviceUse]
    public let role: StorageDeviceRole
    public let state: StorageDeviceState
    public let osdID: Int?
    public let present: Bool
    public let lastSeenAt: Date?
    public let createdAt: Date?
    public let updatedAt: Date?

    public var identity: StorageDeviceIdentity? {
        guard let identityKind, let identityValue else { return nil }
        return StorageDeviceIdentity(kind: identityKind, value: identityValue)
    }

    public init(
        id: UUID,
        agentID: UUID,
        identityKind: StorageDeviceIdentityKind?,
        identityValue: String?,
        devicePath: String,
        sizeBytes: Int64,
        model: String? = nil,
        serial: String? = nil,
        wwn: String? = nil,
        rotational: Bool,
        uses: [StorageDeviceUse],
        role: StorageDeviceRole = .unassigned,
        state: StorageDeviceState,
        osdID: Int? = nil,
        present: Bool,
        lastSeenAt: Date?,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.agentID = agentID
        self.identityKind = identityKind
        self.identityValue = identityValue
        self.devicePath = devicePath
        self.sizeBytes = sizeBytes
        self.model = model
        self.serial = serial
        self.wwn = wwn
        self.rotational = rotational
        self.uses = uses
        self.role = role
        self.state = state
        self.osdID = osdID
        self.present = present
        self.lastSeenAt = lastSeenAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum StorageDeviceEligibilityBlocker: String, Codable, Sendable {
    case missingIdentity
    case notPresent
    case inUse
    case draining
    case faulted
    case agentOffline
    case staleObservation
}

public struct StorageDeviceEligibility: Equatable, Sendable {
    public let osdEligible: Bool
    public let canMarkOSDEligible: Bool
    public let blocker: StorageDeviceEligibilityBlocker?
}

public struct StorageDeviceEligibilityMutation: Equatable, Sendable {
    public let device: StorageDeviceSnapshot
    public let agentLastHeartbeat: Date?
}

public enum StorageDeviceInventoryError: Error, Equatable, Sendable {
    case invalidObservation(String)
}

public enum StorageDevicePersistenceError: Error, Equatable, Sendable {
    case notFound(UUID)
    case agentNotFound(UUID)
    case ineligible(StorageDeviceEligibilityBlocker)
    case invalidIdentityKind(String)
    case invalidRole(String)
    case invalidState(String)
}

/// Owns durable storage inventory and the OSD-eligibility invariant.
///
/// Device paths are display facts. Reconciliation correlates only by WWN,
/// then serial, and retains missing rows. Anonymous devices may correlate by
/// path only while continuously present and can never retain operator intent.
public struct StorageDevicesPersistence: Sendable {
    private let database: PostgresDatabase

    init(database: PostgresDatabase) {
        self.database = database
    }

    public func devices(forAgentIDs agentIDs: [UUID]) async throws -> [StorageDeviceSnapshot] {
        guard !agentIDs.isEmpty else { return [] }
        return try await database.withSession(operation: "storage_devices.list") { session in
            try await session.execute(
                ListStorageDevices(agentIDs: agentIDs),
                operation: "storage_devices.list.query"
            ).map(\.snapshot)
        }
    }

    public func device(id: UUID) async throws -> StorageDeviceSnapshot? {
        try await database.withSession(operation: "storage_devices.lookup") { session in
            try await session.execute(
                LookupStorageDevice(id: id),
                operation: "storage_devices.lookup.query"
            ).first?.snapshot
        }
    }

    public static func eligibility(
        for device: StorageDeviceSnapshot,
        agentLastHeartbeat: Date?,
        now: Date = Date()
    ) -> StorageDeviceEligibility {
        let blocker: StorageDeviceEligibilityBlocker?
        if device.identity == nil {
            blocker = .missingIdentity
        } else if !device.present {
            blocker = .notPresent
        } else {
            switch device.state {
            case .inUse:
                blocker = .inUse
            case .draining:
                blocker = .draining
            case .faulted:
                blocker = .faulted
            case .available:
                let agentOnline = agentLastHeartbeat.map { now.timeIntervalSince($0) < 60 } ?? false
                if !agentOnline {
                    blocker = .agentOffline
                } else if device.lastSeenAt.map({ now.timeIntervalSince($0) > 60 }) ?? true {
                    blocker = .staleObservation
                } else {
                    blocker = nil
                }
            }
        }
        return StorageDeviceEligibility(
            osdEligible: device.role == .osd,
            canMarkOSDEligible: blocker == nil,
            blocker: blocker
        )
    }

    /// Apply one authoritative, successfully enumerated whole-disk snapshot.
    /// Validation completes before a transaction starts, so one malformed row
    /// cannot turn omitted rows into disappearances.
    public func reconcileInventory(
        _ observations: [ObservedStorageDevice],
        forAgentID agentID: UUID,
        receivedAt: Date
    ) async throws {
        let validated = try Self.validate(observations)

        try await database.withTransaction(operation: "storage_devices.reconcile") { session in
            let existing = try await session.execute(
                LockAgentStorageDevices(agentID: agentID),
                operation: "storage_devices.reconcile.lock"
            )
            var stableByIdentity: [StorageDeviceIdentity: StorageDeviceRecord] = [:]
            var presentAnonymousByPath: [String: StorageDeviceRecord] = [:]
            for device in existing {
                if let identity = device.snapshot.identity {
                    stableByIdentity[identity] = device
                } else if device.present, presentAnonymousByPath[device.devicePath] == nil {
                    presentAnonymousByPath[device.devicePath] = device
                }
            }

            var seen = Set<UUID>()
            for item in validated {
                let stored: StorageDeviceRecord?
                if let identity = item.observation.identity {
                    stored = stableByIdentity[identity]
                } else {
                    stored = presentAnonymousByPath[item.observation.devicePath]
                }

                let record: StorageDeviceRecord
                if let stored {
                    record = try await session.execute(
                        UpdateObservedStorageDevice(
                            id: stored.id,
                            observation: item.observation,
                            uses: item.uses,
                            receivedAt: receivedAt,
                            clearIntent: item.observation.identity == nil
                        ),
                        operation: "storage_devices.reconcile.update"
                    ).onlyRow()
                } else {
                    record = try await session.execute(
                        InsertObservedStorageDevice(
                            id: UUID(),
                            agentID: agentID,
                            observation: item.observation,
                            uses: item.uses,
                            receivedAt: receivedAt
                        ),
                        operation: "storage_devices.reconcile.insert"
                    ).onlyRow()
                }
                seen.insert(record.id)
            }

            for device in existing where device.present && !seen.contains(device.id) {
                _ = try await session.execute(
                    MarkStorageDeviceMissing(id: device.id),
                    operation: "storage_devices.reconcile.mark_missing"
                ).onlyRow()
            }
        }
    }

    /// Change OSD eligibility under the same row lock as inventory merges.
    /// Disabling is always allowed; enabling revalidates every live fact in the
    /// transaction that commits the intent.
    public func setOSDEligibility(
        forDeviceID deviceID: UUID,
        eligible: Bool,
        now: Date = Date()
    ) async throws -> StorageDeviceEligibilityMutation {
        try await database.withTransaction(operation: "storage_devices.set_osd_eligibility") { session in
            guard let locked = try await session.execute(
                LockStorageDeviceAndAgent(id: deviceID),
                operation: "storage_devices.set_osd_eligibility.lock"
            ).first else {
                throw StorageDevicePersistenceError.notFound(deviceID)
            }

            let current = locked.device.snapshot
            let nextRole: StorageDeviceRole
            if !eligible {
                nextRole = .unassigned
            } else if current.role == .osd {
                nextRole = .osd
            } else {
                let status = Self.eligibility(
                    for: current,
                    agentLastHeartbeat: locked.agentLastHeartbeat,
                    now: now
                )
                if let blocker = status.blocker {
                    throw StorageDevicePersistenceError.ineligible(blocker)
                }
                nextRole = .osd
            }

            let updated = try await session.execute(
                UpdateStorageDeviceRole(id: deviceID, role: nextRole),
                operation: "storage_devices.set_osd_eligibility.update"
            ).onlyRow()
            return StorageDeviceEligibilityMutation(
                device: updated.snapshot,
                agentLastHeartbeat: locked.agentLastHeartbeat
            )
        }
    }

    private static func validate(
        _ observations: [ObservedStorageDevice]
    ) throws -> [ValidatedStorageDeviceObservation] {
        var identities = Set<StorageDeviceIdentity>()
        var paths = Set<String>()
        var result: [ValidatedStorageDeviceObservation] = []
        result.reserveCapacity(observations.count)

        for observation in observations {
            guard observation.devicePath.hasPrefix("/dev/"), observation.devicePath.count > 5 else {
                throw StorageDeviceInventoryError.invalidObservation("invalid device path")
            }
            guard paths.insert(observation.devicePath).inserted else {
                throw StorageDeviceInventoryError.invalidObservation("duplicate device path")
            }
            guard observation.sizeBytes >= 0 else {
                throw StorageDeviceInventoryError.invalidObservation("negative device size")
            }

            let preferredIdentity = StorageDeviceIdentity.preferred(
                wwn: observation.wwn,
                serial: observation.serial
            )
            guard observation.identity == preferredIdentity else {
                throw StorageDeviceInventoryError.invalidObservation(
                    "identity does not match raw facts")
            }
            if let identity = observation.identity, !identities.insert(identity).inserted {
                throw StorageDeviceInventoryError.invalidObservation("duplicate stable identity")
            }

            let uniqueUses = Set(observation.uses)
            guard uniqueUses.count == observation.uses.count else {
                throw StorageDeviceInventoryError.invalidObservation("duplicate device use")
            }
            switch observation.state {
            case .available:
                guard observation.sizeBytes > 0, uniqueUses.isEmpty else {
                    throw StorageDeviceInventoryError.invalidObservation(
                        "available device has use or zero size")
                }
            case .inUse:
                guard observation.sizeBytes > 0, !uniqueUses.isEmpty else {
                    throw StorageDeviceInventoryError.invalidObservation(
                        "in-use device has no use or zero size")
                }
            case .faulted:
                break
            case .draining:
                throw StorageDeviceInventoryError.invalidObservation("agent cannot report draining")
            }

            result.append(ValidatedStorageDeviceObservation(
                observation: observation,
                uses: uniqueUses.sorted { $0.rawValue < $1.rawValue }
            ))
        }
        return result
    }
}

private struct ValidatedStorageDeviceObservation: Sendable {
    let observation: ObservedStorageDevice
    let uses: [StorageDeviceUse]
}

private struct StorageDeviceRecord: Sendable {
    let id: UUID
    let agentID: UUID
    let identityKind: StorageDeviceIdentityKind?
    let identityValue: String?
    let devicePath: String
    let sizeBytes: Int64
    let model: String?
    let serial: String?
    let wwn: String?
    let rotational: Bool
    let uses: [StorageDeviceUseJSON]
    let role: StorageDeviceRole
    let state: StorageDeviceState
    let osdID: Int?
    let present: Bool
    let lastSeenAt: Date?
    let createdAt: Date?
    let updatedAt: Date?

    init(row: PostgresRow) throws {
        let values = try row.decode((
            UUID, UUID, String?, String?, String, Int64,
            String?, String?, String?, Bool, [StorageDeviceUseJSON], String, String, Int?, Bool,
            Date?, Date?, Date?
        ).self)
        try self.init(values: values)
    }

    var snapshot: StorageDeviceSnapshot {
        StorageDeviceSnapshot(
            id: id,
            agentID: agentID,
            identityKind: identityKind,
            identityValue: identityValue,
            devicePath: devicePath,
            sizeBytes: sizeBytes,
            model: model,
            serial: serial,
            wwn: wwn,
            rotational: rotational,
            uses: uses.map(\.value),
            role: role,
            state: state,
            osdID: osdID,
            present: present,
            lastSeenAt: lastSeenAt,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

private struct LockedStorageDevice: Sendable {
    let device: StorageDeviceRecord
    let agentLastHeartbeat: Date?

    init(row: PostgresRow) throws {
        let decoded = try row.decode((
            UUID, UUID, String?, String?, String, Int64,
            String?, String?, String?, Bool, [StorageDeviceUseJSON], String, String, Int?, Bool,
            Date?, Date?, Date?, Date?
        ).self)
        device = try StorageDeviceRecord(values: (
            decoded.0, decoded.1, decoded.2, decoded.3, decoded.4, decoded.5,
            decoded.6, decoded.7, decoded.8, decoded.9, decoded.10, decoded.11,
            decoded.12, decoded.13, decoded.14, decoded.15, decoded.16, decoded.17
        ))
        agentLastHeartbeat = decoded.18
    }
}

private extension StorageDeviceRecord {
    init(values: (
        UUID, UUID, String?, String?, String, Int64,
        String?, String?, String?, Bool, [StorageDeviceUseJSON], String, String, Int?, Bool,
        Date?, Date?, Date?
    )) throws {
        id = values.0
        agentID = values.1
        if let rawIdentityKind = values.2 {
            guard let decodedIdentityKind = StorageDeviceIdentityKind(rawValue: rawIdentityKind) else {
                throw StorageDevicePersistenceError.invalidIdentityKind(rawIdentityKind)
            }
            identityKind = decodedIdentityKind
        } else {
            identityKind = nil
        }
        identityValue = values.3
        devicePath = values.4
        sizeBytes = values.5
        model = values.6
        serial = values.7
        wwn = values.8
        rotational = values.9
        uses = values.10
        guard let decodedRole = StorageDeviceRole(rawValue: values.11) else {
            throw StorageDevicePersistenceError.invalidRole(values.11)
        }
        role = decodedRole
        guard let decodedState = StorageDeviceState(rawValue: values.12) else {
            throw StorageDevicePersistenceError.invalidState(values.12)
        }
        state = decodedState
        osdID = values.13
        present = values.14
        lastSeenAt = values.15
        createdAt = values.16
        updatedAt = values.17
    }
}

/// Fluent encoded each enum case as a standalone JSON string inside JSONB[].
private struct StorageDeviceUseJSON: Codable, PostgresEncodable, PostgresDecodable,
    PostgresArrayEncodable, PostgresArrayDecodable, Sendable
{
    static let psqlArrayType: PostgresDataType = .jsonbArray
    let value: StorageDeviceUse

    init(_ value: StorageDeviceUse) {
        self.value = value
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try container.decode(StorageDeviceUse.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

private extension Array {
    func onlyRow(file: StaticString = #fileID, line: UInt = #line) throws -> Element {
        guard count == 1, let row = first else {
            throw StorageDeviceRowCountError(expected: 1, actual: count, file: file, line: line)
        }
        return row
    }
}

private struct StorageDeviceRowCountError: Error, Sendable {
    let expected: Int
    let actual: Int
    let file: StaticString
    let line: UInt
}

private let storageDeviceColumns = """
    id, agent_id, identity_kind, identity_value, device_path, size_bytes,
    model, serial, wwn, rotational, uses, role, state, osd_id, present,
    last_seen_at, created_at, updated_at
    """

private let qualifiedStorageDeviceColumns = """
    storage_devices.id, storage_devices.agent_id, storage_devices.identity_kind,
    storage_devices.identity_value, storage_devices.device_path, storage_devices.size_bytes,
    storage_devices.model, storage_devices.serial, storage_devices.wwn,
    storage_devices.rotational, storage_devices.uses, storage_devices.role,
    storage_devices.state, storage_devices.osd_id, storage_devices.present,
    storage_devices.last_seen_at, storage_devices.created_at, storage_devices.updated_at
    """

private protocol StorageDeviceStatement: PostgresPreparedStatement where Row == StorageDeviceRecord {}

private extension StorageDeviceStatement {
    func decodeRow(_ row: PostgresRow) throws -> StorageDeviceRecord {
        try StorageDeviceRecord(row: row)
    }
}

private struct ListStorageDevices: StorageDeviceStatement {
    static let sql = "SELECT \(storageDeviceColumns) FROM storage_devices WHERE agent_id = ANY($1)"
    let agentIDs: [UUID]

    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(agentIDs)
        return bindings
    }
}

private struct LookupStorageDevice: StorageDeviceStatement {
    static let sql = "SELECT \(storageDeviceColumns) FROM storage_devices WHERE id = $1 LIMIT 1"
    let id: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
}

private struct LockAgentStorageDevices: StorageDeviceStatement {
    static let sql = "SELECT \(storageDeviceColumns) FROM storage_devices WHERE agent_id = $1 FOR UPDATE"
    let agentID: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(agentID)
        return bindings
    }
}

private struct InsertObservedStorageDevice: StorageDeviceStatement {
    static let sql = """
        INSERT INTO storage_devices (
            id, agent_id, identity_kind, identity_value, device_path, size_bytes,
            model, serial, wwn, rotational, uses, role, state, osd_id, present,
            last_seen_at, created_at, updated_at
        ) VALUES (
            $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11,
            'unassigned', $12, NULL, true, $13, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
        )
        RETURNING \(storageDeviceColumns)
        """

    let id: UUID
    let agentID: UUID
    let observation: ObservedStorageDevice
    let uses: [StorageDeviceUse]
    let receivedAt: Date

    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 13)
        bindings.append(id)
        bindings.append(agentID)
        bindings.append(observation.identity?.kind.rawValue)
        bindings.append(observation.identity?.value)
        bindings.append(observation.devicePath)
        bindings.append(observation.sizeBytes)
        bindings.append(observation.model)
        bindings.append(observation.serial)
        bindings.append(observation.wwn)
        bindings.append(observation.rotational)
        try bindings.append(uses.map { StorageDeviceUseJSON($0) })
        bindings.append(observation.state.rawValue)
        bindings.append(receivedAt)
        return bindings
    }
}

private struct UpdateObservedStorageDevice: StorageDeviceStatement {
    static let sql = """
        UPDATE storage_devices
        SET identity_kind = $2,
            identity_value = $3,
            device_path = $4,
            size_bytes = $5,
            model = $6,
            serial = $7,
            wwn = $8,
            rotational = $9,
            uses = $10,
            state = $11,
            present = true,
            last_seen_at = $12,
            role = CASE WHEN $13 THEN 'unassigned' ELSE role END,
            osd_id = CASE WHEN $13 THEN NULL ELSE osd_id END,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = $1
        RETURNING \(storageDeviceColumns)
        """

    let id: UUID
    let observation: ObservedStorageDevice
    let uses: [StorageDeviceUse]
    let receivedAt: Date
    let clearIntent: Bool

    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 13)
        bindings.append(id)
        bindings.append(observation.identity?.kind.rawValue)
        bindings.append(observation.identity?.value)
        bindings.append(observation.devicePath)
        bindings.append(observation.sizeBytes)
        bindings.append(observation.model)
        bindings.append(observation.serial)
        bindings.append(observation.wwn)
        bindings.append(observation.rotational)
        try bindings.append(uses.map { StorageDeviceUseJSON($0) })
        bindings.append(observation.state.rawValue)
        bindings.append(receivedAt)
        bindings.append(clearIntent)
        return bindings
    }
}

private struct MarkStorageDeviceMissing: StorageDeviceStatement {
    static let sql = """
        UPDATE storage_devices
        SET present = false, updated_at = CURRENT_TIMESTAMP
        WHERE id = $1
        RETURNING \(storageDeviceColumns)
        """
    let id: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
}

private struct LockStorageDeviceAndAgent: PostgresPreparedStatement {
    static let sql = """
        SELECT \(qualifiedStorageDeviceColumns), agents.last_heartbeat
        FROM storage_devices
        JOIN agents ON agents.id = storage_devices.agent_id
        WHERE storage_devices.id = $1
        FOR UPDATE OF storage_devices
        """

    typealias Row = LockedStorageDevice
    let id: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> LockedStorageDevice {
        try LockedStorageDevice(row: row)
    }
}

private struct UpdateStorageDeviceRole: StorageDeviceStatement {
    static let sql = """
        UPDATE storage_devices
        SET role = $2, updated_at = CURRENT_TIMESTAMP
        WHERE id = $1
        RETURNING \(storageDeviceColumns)
        """
    let id: UUID
    let role: StorageDeviceRole

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append(role.rawValue)
        return bindings
    }
}
