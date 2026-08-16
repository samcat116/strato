import Foundation

public enum StorageDeviceIdentityKind: String, Codable, Sendable {
    case wwn
    case serial
}

public struct StorageDeviceIdentity: Codable, Equatable, Hashable, Sendable {
    public let kind: StorageDeviceIdentityKind
    public let value: String

    public init(kind: StorageDeviceIdentityKind, value: String) {
        self.kind = kind
        self.value = value
    }

    public static func preferred(wwn: String?, serial: String?) -> Self? {
        if let wwn = normalizedWWN(wwn) {
            return Self(kind: .wwn, value: wwn)
        }
        if let serial = normalizedSerial(serial) {
            return Self(kind: .serial, value: serial)
        }
        return nil
    }

    public static func normalizedWWN(_ value: String?) -> String? {
        guard var normalized = trimmedNonempty(value)?.lowercased() else { return nil }
        if normalized.hasPrefix("0x") {
            normalized.removeFirst(2)
        }
        return normalized.isEmpty ? nil : normalized
    }

    public static func normalizedSerial(_ value: String?) -> String? {
        trimmedNonempty(value)
    }

    private static func trimmedNonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}

public enum StorageDeviceUse: String, Codable, CaseIterable, Sendable {
    case childDevice
    case partitionTable
    case filesystem
    case mounted
    case swap
    case lvmPhysicalVolume
    case readOnly
}

public enum StorageDeviceState: String, Codable, CaseIterable, Sendable {
    case available
    case inUse
    case draining
    case faulted
}

public struct ObservedStorageDevice: Codable, Equatable, Sendable {
    public let identity: StorageDeviceIdentity?
    public let devicePath: String
    public let sizeBytes: Int64
    public let model: String?
    public let serial: String?
    public let wwn: String?
    public let rotational: Bool
    public let state: StorageDeviceState
    public let uses: [StorageDeviceUse]

    public init(
        identity: StorageDeviceIdentity?,
        devicePath: String,
        sizeBytes: Int64,
        model: String? = nil,
        serial: String? = nil,
        wwn: String? = nil,
        rotational: Bool,
        state: StorageDeviceState,
        uses: [StorageDeviceUse]
    ) {
        self.identity = identity
        self.devicePath = devicePath
        self.sizeBytes = sizeBytes
        self.model = model
        self.serial = serial
        self.wwn = wwn
        self.rotational = rotational
        self.state = state
        self.uses = uses
    }
}
