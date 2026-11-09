import Foundation
import SwiftProtobuf

/// On-disk image formats a file-backed storage layer can produce.
///
/// This is part of the wire contract only for `.file` attachments. Block
/// devices and native network storage do not acquire a file format merely
/// because a hypervisor needs to choose a driver for them.
public typealias DiskFormat = Strato_Agent_V1_DiskFormat
extension Strato_Agent_V1_DiskFormat: Codable {

    /// File extension used by the filesystem backend's path layout.
    public var fileExtension: String { protocolValue }

    /// Best-effort inference for historical file attachments that carried only
    /// a path. Unknown extensions preserve the former qcow2 assumption.
    public init(volumePath: String) {
        self = DiskFormat(rawValue: (volumePath as NSString).pathExtension) ?? .qcow2
    }

    public var protocolValue: String {
        switch self {
        case .qcow2: return "qcow2"
        case .raw: return "raw"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "qcow2": self = .qcow2
        case "raw": self = .raw
        default: return nil
        }
    }

    public static var knownCases: [Self] { [.qcow2, .raw] }

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

/// The host-cache policy requested for a QEMU volume attachment.
///
/// Neither optimized mode is the default until representative benchmarks have
/// compared them. `conservative` preserves the historical libvirt/QEMU
/// defaults; `direct` asks the agent to use direct I/O only when its live
/// capability probe succeeds; and `cachedShared` explicitly retains the host
/// page cache for read-mostly images whose backing pages can be shared.
public typealias VolumeBlockMode = Strato_Agent_V1_VolumeBlockMode
extension Strato_Agent_V1_VolumeBlockMode: Codable {

    public var protocolValue: String {
        switch self {
        case .conservative: return "conservative"
        case .direct: return "direct"
        case .cachedShared: return "cachedShared"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "conservative": self = .conservative
        case "direct": self = .direct
        case "cachedShared": self = .cachedShared
        default: return nil
        }
    }

    public static var knownCases: [Self] { [.conservative, .direct, .cachedShared] }

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

/// A QEMU cache value that an agent has actually selected.
public typealias BlockDeviceCacheMode = Strato_Agent_V1_BlockDeviceCacheMode
extension Strato_Agent_V1_BlockDeviceCacheMode: Codable {

    public var protocolValue: String {
        switch self {
        case .none: return "none"
        case .writeback: return "writeback"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "none": self = .none
        case "writeback": self = .writeback
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

/// A QEMU asynchronous-I/O engine that an agent has actually selected.
public typealias BlockDeviceIOMode = Strato_Agent_V1_BlockDeviceIOMode
extension Strato_Agent_V1_BlockDeviceIOMode: Codable {

    public var protocolValue: String {
        switch self {
        case .ioUring: return "io_uring"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "io_uring": self = .ioUring
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

/// The complete block-device policy an agent selected for one attachment.
///
/// This is applied state, not a capability claim. Optional driver values mean
/// the corresponding libvirt XML attribute was deliberately omitted. An
/// inactive value is the explicit current-agent report for a detached volume;
/// absence of the whole structure means an older agent did not report policy.
public typealias AppliedBlockDevicePolicy = Strato_Agent_V1_AppliedBlockDevicePolicy
extension Strato_Agent_V1_AppliedBlockDevicePolicy: Codable {

    public init(
        active: Bool,
        requestedMode: VolumeBlockMode,
        cacheMode: BlockDeviceCacheMode? = nil,
        ioMode: BlockDeviceIOMode? = nil,
        discard: Bool = false,
        nonRotational: Bool = false,
        queueCount: Int? = nil,
        fallbackReason: String? = nil
    ) {
        self.init()
        self._jsonActive = active
        self._jsonRequestedMode = requestedMode
        self._jsonCacheMode = cacheMode
        self._jsonIoMode = ioMode
        self._jsonDiscard = discard
        self._jsonNonRotational = nonRotational
        self._jsonQueueCount = queueCount
        self._jsonFallbackReason = fallbackReason
    }

    public static func inactive(requestedMode: VolumeBlockMode) -> Self {
        Self(active: false, requestedMode: requestedMode)
    }

    private enum CodingKeys: String, CodingKey {
        case active; case requestedMode; case cacheMode; case ioMode; case discard; case nonRotational; case queueCount;
        case fallbackReason
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonActive = try container.decode(Bool.self, forKey: .active)
        self._jsonRequestedMode = try container.decode(VolumeBlockMode.self, forKey: .requestedMode)
        self._jsonCacheMode = try container.decodeIfPresent(BlockDeviceCacheMode.self, forKey: .cacheMode)
        self._jsonIoMode = try container.decodeIfPresent(BlockDeviceIOMode.self, forKey: .ioMode)
        self._jsonDiscard = try container.decode(Bool.self, forKey: .discard)
        self._jsonNonRotational = try container.decode(Bool.self, forKey: .nonRotational)
        self._jsonQueueCount = try container.decodeIfPresent(Int.self, forKey: .queueCount)
        self._jsonFallbackReason = try container.decodeIfPresent(String.self, forKey: .fallbackReason)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonActive, forKey: .active)
        try container.encode(_jsonRequestedMode, forKey: .requestedMode)
        try container.encodeIfPresent(_jsonCacheMode, forKey: .cacheMode)
        try container.encodeIfPresent(_jsonIoMode, forKey: .ioMode)
        try container.encode(_jsonDiscard, forKey: .discard)
        try container.encode(_jsonNonRotational, forKey: .nonRotational)
        try container.encodeIfPresent(_jsonQueueCount, forKey: .queueCount)
        try container.encodeIfPresent(_jsonFallbackReason, forKey: .fallbackReason)
    }

    var _jsonActive: Bool {
        get { active }
        set { let value = newValue; active = value }
    }
    var _jsonRequestedMode: VolumeBlockMode {
        get { requestedMode }
        set { let value = newValue; requestedMode = value }
    }
    var _jsonCacheMode: BlockDeviceCacheMode? {
        get { hasCacheMode ? (cacheMode) : nil }
        set { if let value = newValue { cacheMode = value } else { clearCacheMode() } }
    }
    var _jsonIoMode: BlockDeviceIOMode? {
        get { hasIoMode ? (ioMode) : nil }
        set { if let value = newValue { ioMode = value } else { clearIoMode() } }
    }
    var _jsonDiscard: Bool {
        get { discard }
        set { let value = newValue; discard = value }
    }
    var _jsonNonRotational: Bool {
        get { nonRotational }
        set { let value = newValue; nonRotational = value }
    }
    var _jsonQueueCount: Int? {
        get { hasQueueCount ? (Int(queueCount)) : nil }
        set { if let value = newValue { queueCount = Int64(value) } else { clearQueueCount() } }
    }
    var _jsonFallbackReason: String? {
        get { hasFallbackReason ? (fallbackReason) : nil }
        set { if let value = newValue { fallbackReason = value } else { clearFallbackReason() } }
    }
}

/// A storage-backend-owned disk reference that a hypervisor can realize.
///
/// The cases are intentionally exhaustive rather than a path plus optional
/// network coordinates. A caller must choose the correct realization instead
/// of interpreting one string differently according to pool configuration.
public typealias DiskAttachment = Strato_Agent_V1_DiskAttachment
