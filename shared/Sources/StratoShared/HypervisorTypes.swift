import Foundation
import SwiftProtobuf

/// Identity of a VM backend *driver*, not of the accelerator behind it.
///
/// QEMU and Firecracker are Linux drivers. Apple Virtualization is a native
/// macOS driver; acceleration is reported separately from driver identity.
public typealias HypervisorType = Strato_Agent_V1_HypervisorType
extension Strato_Agent_V1_HypervisorType: Codable {

    /// Human-readable display name
    public var displayName: String {
        switch self {
        case .qemu:
            return "QEMU"
        case .firecracker:
            return "Firecracker"
        case .appleVirtualization:
            return "Apple Virtualization"
        case .unspecified, .UNRECOGNIZED:
            return "Unknown"
        }
    }

    public var protocolValue: String {
        switch self {
        case .qemu: return "qemu"
        case .firecracker: return "firecracker"
        case .appleVirtualization: return "apple_virtualization"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "qemu": self = .qemu
        case "firecracker": self = .firecracker
        case "apple_virtualization": self = .appleVirtualization
        default: return nil
        }
    }

    public static var knownCases: [Self] { [.qemu, .firecracker, .appleVirtualization] }

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

/// Networking capability of an agent host, as reported at registration.
public typealias NetworkCapability = Strato_Agent_V1_NetworkCapability
extension Strato_Agent_V1_NetworkCapability: Codable {

    public var protocolValue: String {
        switch self {
        case .overlay: return "overlay"
        case .userMode: return "user_mode"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "overlay": self = .overlay
        case "user_mode": self = .userMode
        default: return nil
        }
    }

    public static var knownCases: [Self] { [.overlay, .userMode] }

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

/// One hypervisor on an agent host: what it is, whether it can actually run
/// VMs right now (probed at agent startup, not assumed from the platform),
/// and what it supports.
public typealias HypervisorSupport = Strato_Agent_V1_HypervisorSupport
extension Strato_Agent_V1_HypervisorSupport: Codable {

    public func supportsMemorySize(_ bytes: Int64) -> Bool {
        guard HypervisorType.knownCases.contains(_jsonType) else { return false }
        guard _jsonType == .appleVirtualization else { return true }
        guard let minimumMemoryBytes = _jsonMinimumMemoryBytes, let maximumMemoryBytes = _jsonMaximumMemoryBytes,
            minimumMemoryBytes > 0, maximumMemoryBytes >= minimumMemoryBytes
        else { return false }
        return bytes >= minimumMemoryBytes && bytes <= maximumMemoryBytes && bytes % (1 << 20) == 0
    }

    public init(
        type: HypervisorType,
        available: Bool,
        accelerated: Bool,
        unavailabilityReason: String? = nil,
        supportsSnapshots: Bool? = nil,
        supportsVsock: Bool? = nil,
        supportsGuestExec: Bool? = nil,
        supportsVolumeIOLimits: Bool? = nil,
        version: String? = nil,
        minimumMemoryBytes: Int64? = nil,
        maximumMemoryBytes: Int64? = nil
    ) {
        self.init()
        self._jsonType = type
        self._jsonAvailable = available
        self._jsonAccelerated = accelerated
        self._jsonUnavailabilityReason = unavailabilityReason
        self._jsonSupportsSnapshots = supportsSnapshots ?? type.supportsSnapshots
        self._jsonSupportsVsock = supportsVsock
        self._jsonSupportsGuestExec = supportsGuestExec
        self._jsonSupportsVolumeIOLimits = supportsVolumeIOLimits
        self._jsonVersion = version
        self._jsonMinimumMemoryBytes = minimumMemoryBytes
        self._jsonMaximumMemoryBytes = maximumMemoryBytes
    }
    private enum CodingKeys: String, CodingKey {
        case type, available, accelerated, unavailabilityReason, supportsSnapshots
        case supportsVsock, supportsGuestExec, supportsVolumeIOLimits, version, minimumMemoryBytes, maximumMemoryBytes
    }

    public init(from decoder: Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _jsonType = try container.decode(HypervisorType.self, forKey: .type)
        _jsonAvailable = try container.decode(Bool.self, forKey: .available)
        _jsonAccelerated = try container.decode(Bool.self, forKey: .accelerated)
        _jsonUnavailabilityReason = try container.decodeIfPresent(String.self, forKey: .unavailabilityReason)
        _jsonSupportsSnapshots =
            try container.decodeIfPresent(Bool.self, forKey: .supportsSnapshots)
            ?? _jsonType.supportsSnapshots
        _jsonSupportsVsock = try container.decodeIfPresent(Bool.self, forKey: .supportsVsock)
        _jsonSupportsGuestExec = try container.decodeIfPresent(Bool.self, forKey: .supportsGuestExec)
        _jsonSupportsVolumeIOLimits = try container.decodeIfPresent(Bool.self, forKey: .supportsVolumeIOLimits)
        _jsonVersion = try container.decodeIfPresent(String.self, forKey: .version)
        _jsonMinimumMemoryBytes = try container.decodeIfPresent(Int64.self, forKey: .minimumMemoryBytes)
        _jsonMaximumMemoryBytes = try container.decodeIfPresent(Int64.self, forKey: .maximumMemoryBytes)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonType, forKey: .type)
        try container.encode(_jsonAvailable, forKey: .available)
        try container.encode(_jsonAccelerated, forKey: .accelerated)
        try container.encodeIfPresent(_jsonUnavailabilityReason, forKey: .unavailabilityReason)
        try container.encode(_jsonSupportsSnapshots, forKey: .supportsSnapshots)
        try container.encodeIfPresent(_jsonSupportsVsock, forKey: .supportsVsock)
        try container.encodeIfPresent(_jsonSupportsGuestExec, forKey: .supportsGuestExec)
        try container.encodeIfPresent(_jsonSupportsVolumeIOLimits, forKey: .supportsVolumeIOLimits)
        try container.encodeIfPresent(_jsonVersion, forKey: .version)
        try container.encodeIfPresent(_jsonMinimumMemoryBytes, forKey: .minimumMemoryBytes)
        try container.encodeIfPresent(_jsonMaximumMemoryBytes, forKey: .maximumMemoryBytes)
    }

}

extension HypervisorType {
    fileprivate var supportsSnapshots: Bool {
        switch self {
        case .qemu, .firecracker:
            return true
        case .appleVirtualization, .unspecified, .UNRECOGNIZED:
            return false
        }
    }
}
