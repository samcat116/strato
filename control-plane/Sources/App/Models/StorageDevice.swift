import Fluent
import Foundation
import StratoShared
import Vapor

/// The only operator-controlled storage decision in STR-156. `osd` means the
/// disk is eligible for a later Ceph orchestration phase; it does not mutate or
/// format the device here.
enum StorageDeviceRole: String, Codable, CaseIterable, Sendable {
    case unassigned
    case osd
    case excluded
}

/// Durable inventory for one whole physical disk observed by one agent.
/// Device paths are display data. Only the optional kind/value pair is stable
/// identity, so role and OSD intent must never follow a path between rows.
final class StorageDevice: Model, @unchecked Sendable {
    static let schema = "storage_devices"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "agent_id")
    var agent: Agent

    @OptionalField(key: "identity_kind")
    var identityKind: String?

    @OptionalField(key: "identity_value")
    var identityValue: String?

    @Field(key: "device_path")
    var devicePath: String

    @Field(key: "size_bytes")
    var sizeBytes: Int64

    @OptionalField(key: "model")
    var model: String?

    @OptionalField(key: "serial")
    var serial: String?

    @OptionalField(key: "wwn")
    var wwn: String?

    @Field(key: "rotational")
    var rotational: Bool

    @Field(key: "uses")
    var uses: [StorageDeviceUse]

    @Enum(key: "role")
    var role: StorageDeviceRole

    @Enum(key: "state")
    var state: StorageDeviceState

    @OptionalField(key: "osd_id")
    var osdId: Int?

    @Field(key: "present")
    var present: Bool

    @Timestamp(key: "last_seen_at", on: .none)
    var lastSeenAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
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
        osdId: Int? = nil,
        present: Bool,
        lastSeenAt: Date
    ) {
        self.id = id
        self.$agent.id = agentID
        self.identityKind = identityKind?.rawValue
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
        self.osdId = osdId
        self.present = present
        self.lastSeenAt = lastSeenAt
    }

    var identity: StorageDeviceIdentity? {
        guard let identityKind, let kind = StorageDeviceIdentityKind(rawValue: identityKind),
            let identityValue
        else { return nil }
        return StorageDeviceIdentity(kind: kind, value: identityValue)
    }
}

