import Foundation
import SwiftProtobuf

public typealias StorageDeviceIdentityKind = Strato_Agent_V1_StorageDeviceIdentityKind
extension Strato_Agent_V1_StorageDeviceIdentityKind: Codable {

    public var protocolValue: String {
        switch self {
        case .wwn: return "wwn"
        case .serial: return "serial"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "wwn": self = .wwn
        case "serial": self = .serial
        default: return nil
        }
    }

    public init(from decoder: any Swift.Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let value = Self(rawValue: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown enum value")
        }
        self = value
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        guard !protocolValue.isEmpty else {
            throw EncodingError.invalidValue(
                self, .init(codingPath: encoder.codingPath, debugDescription: "Unknown enum value"))
        }
        var container = encoder.singleValueContainer()
        try container.encode(protocolValue)
    }
}

public typealias StorageDeviceIdentity = Strato_Agent_V1_StorageDeviceIdentity
extension Strato_Agent_V1_StorageDeviceIdentity: Codable {

    public init(kind: StorageDeviceIdentityKind, value: String) {
        self.init()
        self._jsonKind = kind
        self._jsonValue = value
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

    private enum CodingKeys: String, CodingKey { case kind; case value }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonKind = try container.decode(StorageDeviceIdentityKind.self, forKey: .kind)
        self._jsonValue = try container.decode(String.self, forKey: .value)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonKind, forKey: .kind)
        try container.encode(_jsonValue, forKey: .value)
    }

    var _jsonKind: StorageDeviceIdentityKind {
        get { kind }
        set { let value = newValue; kind = value }
    }
    var _jsonValue: String {
        get { value }
        set { let value = newValue; self.value = value }
    }
}

public typealias StorageDeviceUse = Strato_Agent_V1_StorageDeviceUse
extension Strato_Agent_V1_StorageDeviceUse: Codable {

    public var protocolValue: String {
        switch self {
        case .childDevice: return "childDevice"
        case .partitionTable: return "partitionTable"
        case .filesystem: return "filesystem"
        case .mounted: return "mounted"
        case .swap: return "swap"
        case .lvmPhysicalVolume: return "lvmPhysicalVolume"
        case .readOnly: return "readOnly"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "childDevice": self = .childDevice
        case "partitionTable": self = .partitionTable
        case "filesystem": self = .filesystem
        case "mounted": self = .mounted
        case "swap": self = .swap
        case "lvmPhysicalVolume": self = .lvmPhysicalVolume
        case "readOnly": self = .readOnly
        default: return nil
        }
    }

    public static var knownCases: [Self] {
        [.childDevice, .partitionTable, .filesystem, .mounted, .swap, .lvmPhysicalVolume, .readOnly]
    }

    public init(from decoder: any Swift.Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let value = Self(rawValue: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown enum value")
        }
        self = value
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        guard !protocolValue.isEmpty else {
            throw EncodingError.invalidValue(
                self, .init(codingPath: encoder.codingPath, debugDescription: "Unknown enum value"))
        }
        var container = encoder.singleValueContainer()
        try container.encode(protocolValue)
    }
}

public typealias StorageDeviceState = Strato_Agent_V1_StorageDeviceState
extension Strato_Agent_V1_StorageDeviceState: Codable {

    public var protocolValue: String {
        switch self {
        case .available: return "available"
        case .inUse: return "inUse"
        case .draining: return "draining"
        case .faulted: return "faulted"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "available": self = .available
        case "inUse": self = .inUse
        case "draining": self = .draining
        case "faulted": self = .faulted
        default: return nil
        }
    }

    public static var knownCases: [Self] { [.available, .inUse, .draining, .faulted] }

    public init(from decoder: any Swift.Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let value = Self(rawValue: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown enum value")
        }
        self = value
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        guard !protocolValue.isEmpty else {
            throw EncodingError.invalidValue(
                self, .init(codingPath: encoder.codingPath, debugDescription: "Unknown enum value"))
        }
        var container = encoder.singleValueContainer()
        try container.encode(protocolValue)
    }
}

public typealias ObservedStorageDevice = Strato_Agent_V1_ObservedStorageDevice
extension Strato_Agent_V1_ObservedStorageDevice: Codable {

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
        self.init()
        self._jsonIdentity = identity
        self._jsonDevicePath = devicePath
        self._jsonSizeBytes = sizeBytes
        self._jsonModel = model
        self._jsonSerial = serial
        self._jsonWwn = wwn
        self._jsonRotational = rotational
        self._jsonState = state
        self._jsonUses = uses
    }

    private enum CodingKeys: String, CodingKey {
        case identity; case devicePath; case sizeBytes; case model; case serial; case wwn; case rotational; case state;
        case uses
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonIdentity = try container.decodeIfPresent(StorageDeviceIdentity.self, forKey: .identity)
        self._jsonDevicePath = try container.decode(String.self, forKey: .devicePath)
        self._jsonSizeBytes = try container.decode(Int64.self, forKey: .sizeBytes)
        self._jsonModel = try container.decodeIfPresent(String.self, forKey: .model)
        self._jsonSerial = try container.decodeIfPresent(String.self, forKey: .serial)
        self._jsonWwn = try container.decodeIfPresent(String.self, forKey: .wwn)
        self._jsonRotational = try container.decode(Bool.self, forKey: .rotational)
        self._jsonState = try container.decode(StorageDeviceState.self, forKey: .state)
        self._jsonUses = try container.decode([StorageDeviceUse].self, forKey: .uses)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(_jsonIdentity, forKey: .identity)
        try container.encode(_jsonDevicePath, forKey: .devicePath)
        try container.encode(_jsonSizeBytes, forKey: .sizeBytes)
        try container.encodeIfPresent(_jsonModel, forKey: .model)
        try container.encodeIfPresent(_jsonSerial, forKey: .serial)
        try container.encodeIfPresent(_jsonWwn, forKey: .wwn)
        try container.encode(_jsonRotational, forKey: .rotational)
        try container.encode(_jsonState, forKey: .state)
        try container.encode(_jsonUses, forKey: .uses)
    }

    var _jsonIdentity: StorageDeviceIdentity? {
        get { hasIdentity ? (identity) : nil }
        set { if let value = newValue { identity = value } else { clearIdentity() } }
    }
    var _jsonDevicePath: String {
        get { devicePath }
        set { let value = newValue; devicePath = value }
    }
    var _jsonSizeBytes: Int64 {
        get { sizeBytes }
        set { let value = newValue; sizeBytes = value }
    }
    var _jsonModel: String? {
        get { hasModel ? (model) : nil }
        set { if let value = newValue { model = value } else { clearModel() } }
    }
    var _jsonSerial: String? {
        get { hasSerial ? (serial) : nil }
        set { if let value = newValue { serial = value } else { clearSerial() } }
    }
    var _jsonWwn: String? {
        get { hasWwn ? (wwn) : nil }
        set { if let value = newValue { wwn = value } else { clearWwn() } }
    }
    var _jsonRotational: Bool {
        get { rotational }
        set { let value = newValue; rotational = value }
    }
    var _jsonState: StorageDeviceState {
        get { state }
        set { let value = newValue; state = value }
    }
    var _jsonUses: [StorageDeviceUse] {
        get { uses.values }
        set { let value = newValue; uses = Strato_Agent_V1_ObservedStorageDeviceUsesSection.with { $0.values = value } }
    }
}
