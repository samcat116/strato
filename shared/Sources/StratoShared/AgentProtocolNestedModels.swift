import Foundation
import SwiftProtobuf

extension Strato_Agent_V1_GuestConfigFileObservation: Codable {

    public init(path: String, sha256: String? = nil, mode: String? = nil) {
        self.init()
        self._jsonPath = path
        self._jsonSha256 = sha256
        self._jsonMode = mode
    }

    private enum CodingKeys: String, CodingKey { case path; case sha256; case mode }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonPath = try container.decode(String.self, forKey: .path)
        self._jsonSha256 = try container.decodeIfPresent(String.self, forKey: .sha256)
        self._jsonMode = try container.decodeIfPresent(String.self, forKey: .mode)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonPath, forKey: .path)
        try container.encodeIfPresent(_jsonSha256, forKey: .sha256)
        try container.encodeIfPresent(_jsonMode, forKey: .mode)
    }

}

extension Strato_Agent_V1_GuestConfigItemFailure: Codable {
    public typealias Section = Strato_Agent_V1_GuestConfigObservationSection

    public init(section: Section, identity: String, reason: String) {
        self.init()
        self._jsonSection = section
        self._jsonIdentity = identity
        self._jsonReason = reason
    }

    private enum CodingKeys: String, CodingKey { case section; case identity; case reason }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonSection = try container.decode(Section.self, forKey: .section)
        self._jsonIdentity = try container.decode(String.self, forKey: .identity)
        self._jsonReason = try container.decode(String.self, forKey: .reason)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonSection, forKey: .section)
        try container.encode(_jsonIdentity, forKey: .identity)
        try container.encode(_jsonReason, forKey: .reason)
    }

}

extension Strato_Agent_V1_GuestConfigPackageObservation: Codable {

    public init(name: String, version: String? = nil) {
        self.init()
        self._jsonName = name
        self._jsonVersion = version
    }

    private enum CodingKeys: String, CodingKey { case name; case version }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonName = try container.decode(String.self, forKey: .name)
        self._jsonVersion = try container.decodeIfPresent(String.self, forKey: .version)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonName, forKey: .name)
        try container.encodeIfPresent(_jsonVersion, forKey: .version)
    }

}

extension Strato_Agent_V1_GuestConfigObservationSection: Codable {
    public var protocolValue: String {
        switch self {
        case .packages: return "packages"
        case .files: return "files"
        case .services: return "services"
        case .sysctls: return "sysctls"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "packages": self = .packages
        case "files": self = .files
        case "services": self = .services
        case "sysctls": self = .sysctls
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

extension Strato_Agent_V1_GuestConfigServiceObservation: Codable {

    public init(name: String, enabled: Bool? = nil, activeState: String? = nil) {
        self.init()
        self._jsonName = name
        self._jsonEnabled = enabled
        self._jsonActiveState = activeState
    }

    private enum CodingKeys: String, CodingKey { case name; case enabled; case activeState }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonName = try container.decode(String.self, forKey: .name)
        self._jsonEnabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        self._jsonActiveState = try container.decodeIfPresent(String.self, forKey: .activeState)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonName, forKey: .name)
        try container.encodeIfPresent(_jsonEnabled, forKey: .enabled)
        try container.encodeIfPresent(_jsonActiveState, forKey: .activeState)
    }

}

extension Strato_Agent_V1_GuestConfigObservationStatus: Codable {
    public var protocolValue: String {
        switch self {
        case .converged: return "converged"
        case .failed: return "failed"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "converged": self = .converged
        case "failed": self = .failed
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

extension Strato_Agent_V1_GuestConfigSysctlObservation: Codable {

    public init(key: String, value: String? = nil) {
        self.init()
        self._jsonKey = key
        self._jsonValue = value
    }

    private enum CodingKeys: String, CodingKey { case key; case value }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonKey = try container.decode(String.self, forKey: .key)
        self._jsonValue = try container.decodeIfPresent(String.self, forKey: .value)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonKey, forKey: .key)
        try container.encodeIfPresent(_jsonValue, forKey: .value)
    }

}

extension Strato_Agent_V1_HostMemoryTenantClass: Codable {
    public var protocolValue: String {
        switch self {
        case .single: return "single"
        case .multi: return "multi"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "single": self = .single
        case "multi": self = .multi
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

extension Strato_Agent_V1_HostMemoryTier: Codable {
    public var protocolValue: String {
        switch self {
        case .zswap: return "zswap"
        case .zram: return "zram"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "zswap": self = .zswap
        case "zram": self = .zram
        default: return nil
        }
    }

    public static var knownCases: [Self] { [.zswap, .zram] }

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

extension Strato_Agent_V1_SandboxGuestIdleCoverage: Codable {
    public var protocolValue: String {
        switch self {
        case .complete: return "complete"
        case .unknown: return "unknown"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "complete": self = .complete
        case "unknown": self = .unknown
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
