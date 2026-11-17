import Foundation
import SwiftProtobuf

/// Small, level-triggered guest intent (STR-90), guarded by DesiredVMState.generation.
/// Omission withdraws management; it never deletes files, removes packages, or resets settings.
/// Consumers must validate before acting and must never log this value or file contents.
public typealias GuestConfig = Strato_Agent_V1_GuestConfig
extension Strato_Agent_V1_GuestConfig: Codable {
    public static var empty: Self { .init(packages: [], files: [], services: [], sysctls: []) }

    public static let maxEntriesPerSection = 128
    public static let maxFileBytes = 65_536
    public static let maxTotalFileBytes = 262_144

    public init(
        packages: [GuestPackage] = [], files: [GuestFile] = [],
        services: [GuestService] = [], sysctls: [GuestSysctl] = []
    ) {
        self.init()
        self._jsonPackages = packages
        self._jsonFiles = files
        self._jsonServices = services
        self._jsonSysctls = sysctls
    }

    /// Shared API and wire boundary validation. Errors contain rules, never caller values.
    public func validate() throws {
        for (section, count) in [
            ("packages", _jsonPackages.count), ("files", _jsonFiles.count),
            ("services", _jsonServices.count), ("sysctls", _jsonSysctls.count),
        ] {
            guard count <= Self.maxEntriesPerSection else {
                throw GuestConfigValidationError(field: section, rule: "at most 128 entries")
            }
        }
        try unique(_jsonPackages.map(\._jsonName), field: "packages")
        try unique(_jsonFiles.map(\._jsonPath), field: "files")
        try unique(_jsonServices.map(\._jsonName), field: "services")
        try unique(_jsonSysctls.map(\._jsonKey), field: "sysctls")
        for entry in _jsonPackages { try entry.validate() }
        for entry in _jsonFiles { try entry.validate() }
        for entry in _jsonServices { try entry.validate() }
        for entry in _jsonSysctls { try entry.validate() }
        guard _jsonFiles.reduce(0, { $0 + $1._jsonContent.utf8.count }) <= Self.maxTotalFileBytes else {
            throw GuestConfigValidationError(field: "files", rule: "at most 262144 total content bytes")
        }
    }

    private func unique(_ values: [String], field: String) throws {
        guard Set(values).count == values.count else {
            throw GuestConfigValidationError(field: field, rule: "identities must be unique")
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case packages, files, services, sysctls }
    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        try rejectGuestConfigUnknownKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonPackages = try container.decode([GuestPackage].self, forKey: .packages)
        self._jsonFiles = try container.decode([GuestFile].self, forKey: .files)
        self._jsonServices = try container.decode([GuestService].self, forKey: .services)
        self._jsonSysctls = try container.decode([GuestSysctl].self, forKey: .sysctls)
        try validate()
    }
    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonPackages, forKey: .packages)
        try container.encode(_jsonFiles, forKey: .files)
        try container.encode(_jsonServices, forKey: .services)
        try container.encode(_jsonSysctls, forKey: .sysctls)
    }

}

public typealias GuestPackageState = Strato_Agent_V1_GuestPackageState
extension Strato_Agent_V1_GuestPackageState: Codable {

    public init(from decoder: any Swift.Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let state = Self(rawValue: try container.decode(String.self)) else {
            throw GuestConfigValidationError(field: "packages.state", rule: "present or absent required")
        }
        self = state
    }

    public var protocolValue: String {
        switch self {
        case .present: return "present"
        case .absent: return "absent"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "present": self = .present
        case "absent": self = .absent
        default: return nil
        }
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

public typealias GuestPackage = Strato_Agent_V1_GuestPackage
extension Strato_Agent_V1_GuestPackage: Codable {

    public init(name: String, state: GuestPackageState) {
        self.init()
        self._jsonName = name
        self._jsonState = state
    }

    public func validate() throws {
        try guestName(_jsonName, field: "packages.name", extra: ".+_:-")
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case name, state }
    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        try rejectGuestConfigUnknownKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonName = try container.decode(String.self, forKey: .name)
        self._jsonState = try container.decode(GuestPackageState.self, forKey: .state)
        try validate()
    }
    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonName, forKey: .name)
        try container.encode(_jsonState, forKey: .state)
    }

}

public typealias GuestFile = Strato_Agent_V1_GuestFile
extension Strato_Agent_V1_GuestFile: Codable {

    public init(path: String, content: String, mode: String) {
        self.init()
        self._jsonPath = path
        self._jsonContent = content
        self._jsonMode = mode
    }

    public func validate() throws {
        let components = _jsonPath.split(separator: "/", omittingEmptySubsequences: false)
        guard _jsonPath.utf8.count <= 4096, _jsonPath.hasPrefix("/"), _jsonPath != "/",
            !_jsonPath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
            !components.dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else {
            throw GuestConfigValidationError(
                field: "files.path", rule: "a canonical absolute non-root path is required")
        }
        guard _jsonMode.utf8.count == 4, _jsonMode.first == "0", _jsonMode.utf8.allSatisfy({ $0 >= 48 && $0 <= 55 })
        else {
            throw GuestConfigValidationError(
                field: "files.mode", rule: "four octal digits with no special permission bits")
        }
        guard _jsonContent.utf8.count <= GuestConfig.maxFileBytes, !_jsonContent.contains("\0") else {
            throw GuestConfigValidationError(
                field: "files.content", rule: "UTF-8 text without NUL, at most 65536 bytes")
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case path, content, mode }
    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        try rejectGuestConfigUnknownKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonPath = try container.decode(String.self, forKey: .path)
        self._jsonContent = try container.decode(String.self, forKey: .content)
        self._jsonMode = try container.decode(String.self, forKey: .mode)
        try validate()
    }
    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonPath, forKey: .path)
        try container.encode(_jsonContent, forKey: .content)
        try container.encode(_jsonMode, forKey: .mode)
    }

}

public typealias GuestService = Strato_Agent_V1_GuestService
extension Strato_Agent_V1_GuestService: Codable {

    public init(name: String, enabled: Bool) {
        self.init()
        self._jsonName = name
        self._jsonEnabled = enabled
    }

    public func validate() throws {
        try guestName(_jsonName, field: "services.name", extra: "._-@:")
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case name, enabled }
    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        try rejectGuestConfigUnknownKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonName = try container.decode(String.self, forKey: .name)
        self._jsonEnabled = try container.decode(Bool.self, forKey: .enabled)
        try validate()
    }
    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonName, forKey: .name)
        try container.encode(_jsonEnabled, forKey: .enabled)
    }

}

public typealias GuestSysctl = Strato_Agent_V1_GuestSysctl
extension Strato_Agent_V1_GuestSysctl: Codable {

    public init(key: String, value: String) {
        self.init()
        self._jsonKey = key
        self._jsonValue = value
    }

    public func validate() throws {
        try guestName(_jsonKey, field: "sysctls.key", extra: "._-")
        guard _jsonKey.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty }),
            _jsonKey.contains(".")
        else {
            throw GuestConfigValidationError(field: "sysctls.key", rule: "nonempty dot-separated components required")
        }
        guard !_jsonValue.isEmpty, _jsonValue.utf8.count <= 1024,
            !_jsonValue.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\t" })
        else {
            throw GuestConfigValidationError(field: "sysctls.value", rule: "one nonempty line, at most 1024 bytes")
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case key, value }
    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        try rejectGuestConfigUnknownKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonKey = try container.decode(String.self, forKey: .key)
        self._jsonValue = try container.decode(String.self, forKey: .value)
        try validate()
    }
    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonKey, forKey: .key)
        try container.encode(_jsonValue, forKey: .value)
    }

}

public struct GuestConfigValidationError: Error, Sendable, CustomStringConvertible {
    public let field: String
    public let rule: String
    public var description: String { "Invalid guestConfig.\(field): \(rule)" }
}

private func guestName(_ value: String, field: String, extra: String) throws {
    let bytes = Array(value.utf8)
    func alphanumeric(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
    }
    guard !bytes.isEmpty, bytes.count <= 255, alphanumeric(bytes[0]),
        bytes.allSatisfy({ alphanumeric($0) || extra.utf8.contains($0) })
    else {
        throw GuestConfigValidationError(field: field, rule: "bounded ASCII identifier starting with a letter or digit")
    }
}

private struct GuestConfigKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func rejectGuestConfigUnknownKeys(_ decoder: any Swift.Decoder, allowed: Set<String>) throws {
    let container = try decoder.container(keyedBy: GuestConfigKey.self)
    guard container.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
        throw GuestConfigValidationError(field: "schema", rule: "unknown fields are not accepted")
    }
}
