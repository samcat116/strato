import Foundation

/// Small, level-triggered guest intent (STR-90), guarded by DesiredVMState.generation.
/// Omission withdraws management; it never deletes files, removes packages, or resets settings.
/// Consumers must validate before acting and must never log this value or file contents.
public struct GuestConfig: Codable, Sendable, Equatable {
    public static let maxEntriesPerSection = 128
    public static let maxFileBytes = 65_536
    public static let maxTotalFileBytes = 262_144
    public let packages: [GuestPackage]
    public let files: [GuestFile]
    public let services: [GuestService]
    public let sysctls: [GuestSysctl]

    public init(
        packages: [GuestPackage] = [], files: [GuestFile] = [],
        services: [GuestService] = [], sysctls: [GuestSysctl] = []
    ) {
        self.packages = packages
        self.files = files
        self.services = services
        self.sysctls = sysctls
    }

    /// Shared API and wire boundary validation. Errors contain rules, never caller values.
    public func validate() throws {
        for (section, count) in [
            ("packages", packages.count), ("files", files.count),
            ("services", services.count), ("sysctls", sysctls.count),
        ] {
            guard count <= Self.maxEntriesPerSection else {
                throw GuestConfigValidationError(field: section, rule: "at most 128 entries")
            }
        }
        try unique(packages.map(\.name), field: "packages")
        try unique(files.map(\.path), field: "files")
        try unique(services.map(\.name), field: "services")
        try unique(sysctls.map(\.key), field: "sysctls")
        for entry in packages { try entry.validate() }
        for entry in files { try entry.validate() }
        for entry in services { try entry.validate() }
        for entry in sysctls { try entry.validate() }
        guard files.reduce(0, { $0 + $1.content.utf8.count }) <= Self.maxTotalFileBytes else {
            throw GuestConfigValidationError(field: "files", rule: "at most 262144 total content bytes")
        }
    }

    private func unique(_ values: [String], field: String) throws {
        guard Set(values).count == values.count else {
            throw GuestConfigValidationError(field: field, rule: "identities must be unique")
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case packages, files, services, sysctls }
    public init(from decoder: any Decoder) throws {
        try rejectGuestConfigUnknownKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.packages = try container.decode([GuestPackage].self, forKey: .packages)
        self.files = try container.decode([GuestFile].self, forKey: .files)
        self.services = try container.decode([GuestService].self, forKey: .services)
        self.sysctls = try container.decode([GuestSysctl].self, forKey: .sysctls)
        try validate()
    }
    public func encode(to encoder: any Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(packages, forKey: .packages)
        try container.encode(files, forKey: .files)
        try container.encode(services, forKey: .services)
        try container.encode(sysctls, forKey: .sysctls)
    }
}

public enum GuestPackageState: String, Codable, Sendable, Equatable {
    case present
    case absent

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let state = Self(rawValue: try container.decode(String.self)) else {
            throw GuestConfigValidationError(field: "packages.state", rule: "present or absent required")
        }
        self = state
    }
}

public struct GuestPackage: Codable, Sendable, Equatable {
    public let name: String
    public let state: GuestPackageState

    public init(name: String, state: GuestPackageState) {
        self.name = name
        self.state = state
    }

    public func validate() throws {
        try guestName(name, field: "packages.name", extra: ".+_:-")
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case name, state }
    public init(from decoder: any Decoder) throws {
        try rejectGuestConfigUnknownKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.state = try container.decode(GuestPackageState.self, forKey: .state)
        try validate()
    }
    public func encode(to encoder: any Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(state, forKey: .state)
    }
}

public struct GuestFile: Codable, Sendable, Equatable {
    public let path: String
    public let content: String
    public let mode: String

    public init(path: String, content: String, mode: String) {
        self.path = path
        self.content = content
        self.mode = mode
    }

    public func validate() throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.utf8.count <= 4096, path.hasPrefix("/"), path != "/",
            !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
            !components.dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else {
            throw GuestConfigValidationError(
                field: "files.path", rule: "a canonical absolute non-root path is required")
        }
        guard mode.utf8.count == 4, mode.first == "0", mode.utf8.allSatisfy({ $0 >= 48 && $0 <= 55 }) else {
            throw GuestConfigValidationError(
                field: "files.mode", rule: "four octal digits with no special permission bits")
        }
        guard content.utf8.count <= GuestConfig.maxFileBytes, !content.contains("\0") else {
            throw GuestConfigValidationError(
                field: "files.content", rule: "UTF-8 text without NUL, at most 65536 bytes")
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case path, content, mode }
    public init(from decoder: any Decoder) throws {
        try rejectGuestConfigUnknownKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.path = try container.decode(String.self, forKey: .path)
        self.content = try container.decode(String.self, forKey: .content)
        self.mode = try container.decode(String.self, forKey: .mode)
        try validate()
    }
    public func encode(to encoder: any Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(content, forKey: .content)
        try container.encode(mode, forKey: .mode)
    }
}

public struct GuestService: Codable, Sendable, Equatable {
    public let name: String
    public let enabled: Bool

    public init(name: String, enabled: Bool) {
        self.name = name
        self.enabled = enabled
    }

    public func validate() throws {
        try guestName(name, field: "services.name", extra: "._-@:")
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case name, enabled }
    public init(from decoder: any Decoder) throws {
        try rejectGuestConfigUnknownKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.enabled = try container.decode(Bool.self, forKey: .enabled)
        try validate()
    }
    public func encode(to encoder: any Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(enabled, forKey: .enabled)
    }
}

public struct GuestSysctl: Codable, Sendable, Equatable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }

    public func validate() throws {
        try guestName(key, field: "sysctls.key", extra: "._-")
        guard key.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty }),
            key.contains(".")
        else {
            throw GuestConfigValidationError(field: "sysctls.key", rule: "nonempty dot-separated components required")
        }
        guard !value.isEmpty, value.utf8.count <= 1024,
            !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\t" })
        else {
            throw GuestConfigValidationError(field: "sysctls.value", rule: "one nonempty line, at most 1024 bytes")
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case key, value }
    public init(from decoder: any Decoder) throws {
        try rejectGuestConfigUnknownKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.key = try container.decode(String.self, forKey: .key)
        self.value = try container.decode(String.self, forKey: .value)
        try validate()
    }
    public func encode(to encoder: any Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(value, forKey: .value)
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

private func rejectGuestConfigUnknownKeys(_ decoder: any Decoder, allowed: Set<String>) throws {
    let container = try decoder.container(keyedBy: GuestConfigKey.self)
    guard container.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
        throw GuestConfigValidationError(field: "schema", rule: "unknown fields are not accepted")
    }
}
