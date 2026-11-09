import Foundation
import SwiftProtobuf

/// Guest facts for only the currently managed STR-90 identities. Null facts
/// mean unavailable/absent; file contents and command output are never returned.
public typealias GuestConfigObservation = Strato_Agent_V1_GuestConfigObservation
extension Strato_Agent_V1_GuestConfigObservation: Codable {
    public typealias Status = Strato_Agent_V1_GuestConfigObservationStatus

    public typealias ItemFailure = Strato_Agent_V1_GuestConfigItemFailure

    public typealias Package = Strato_Agent_V1_GuestConfigPackageObservation
    public typealias File = Strato_Agent_V1_GuestConfigFileObservation
    public typealias Service = Strato_Agent_V1_GuestConfigServiceObservation
    public typealias Sysctl = Strato_Agent_V1_GuestConfigSysctlObservation

    /// Validate hostile guest facts before retaining or forwarding them. A
    /// failed attempt may have only partial observations, but never foreign
    /// identities or duplicate entries. Successful reports must be complete.
    /// The caller computes file hashes from desired UTF-8 bytes with its crypto
    /// implementation; missing expected hashes fail closed for successful files.
    public func validate(
        for config: GuestConfig, generation: Int64, expectedFileSHA256: [String: String] = [:]
    ) throws {
        guard self._jsonGeneration == generation, generation >= 0,
            (_jsonStatus == .failed) == (_jsonError != nil),
            _jsonError.map({ !$0.isEmpty && $0.utf8.count <= 4096 }) ?? true
        else { throw GuestConfigObservationError.invalid }
        func identities(_ observed: [String], _ desired: [String]) -> Bool {
            let seen = Set(observed)
            let wanted = Set(desired)
            return observed.count <= 128 && seen.count == observed.count
                && seen.isSubset(of: wanted) && (_jsonStatus != .converged || seen == wanted)
        }
        guard identities(_jsonPackages.map(\._jsonName), config._jsonPackages.map(\._jsonName)),
            identities(_jsonFiles.map(\._jsonPath), config._jsonFiles.map(\._jsonPath)),
            identities(_jsonServices.map(\._jsonName), config._jsonServices.map(\._jsonName)),
            identities(_jsonSysctls.map(\._jsonKey), config._jsonSysctls.map(\._jsonKey)),
            _jsonPackages.allSatisfy({ $0._jsonVersion.map({ !$0.isEmpty && $0.utf8.count <= 255 }) ?? true }),
            _jsonFiles.allSatisfy({
                ($0._jsonSha256.map({
                    $0.utf8.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
                }) ?? true)
                    && ($0._jsonMode.map({ $0.utf8.count == 4 && $0.utf8.allSatisfy { (48...55).contains($0) } })
                        ?? true)
            }),
            _jsonServices.allSatisfy({ $0._jsonActiveState.map({ !$0.isEmpty && $0.utf8.count <= 64 }) ?? true }),
            _jsonSysctls.allSatisfy({ $0._jsonValue.map({ $0.utf8.count <= 1024 }) ?? true })
        else { throw GuestConfigObservationError.invalid }
        if let failedItem = _jsonFailedItem {
            let identities: Set<String>
            switch failedItem._jsonSection {
            case .packages: identities = Set(config._jsonPackages.map(\._jsonName))
            case .files: identities = Set(config._jsonFiles.map(\._jsonPath))
            case .services: identities = Set(config._jsonServices.map(\._jsonName))
            case .sysctls: identities = Set(config._jsonSysctls.map(\._jsonKey))
            case .unspecified, .UNRECOGNIZED: throw GuestConfigObservationError.invalid
            }
            guard _jsonStatus == .failed, identities.contains(failedItem._jsonIdentity),
                failedItem._jsonReason == _jsonError
            else { throw GuestConfigObservationError.invalid }
        }
        if _jsonStatus == .converged {
            guard
                config._jsonPackages.allSatisfy({ desired in
                    _jsonPackages.first(where: { $0._jsonName == desired._jsonName }).map {
                        ($0._jsonVersion != nil) == (desired._jsonState == .present)
                    } == true
                }),
                config._jsonFiles.allSatisfy({ desired in
                    guard let expected = expectedFileSHA256[desired._jsonPath] else { return false }
                    return _jsonFiles.first(where: { $0._jsonPath == desired._jsonPath }).map {
                        $0._jsonSha256 == expected && $0._jsonMode == desired._jsonMode
                    } == true
                }),
                config._jsonServices.allSatisfy({ desired in
                    _jsonServices.first(where: { $0._jsonName == desired._jsonName })?._jsonEnabled
                        == desired._jsonEnabled
                }),
                config._jsonSysctls.allSatisfy({ desired in
                    _jsonSysctls.first(where: { $0._jsonKey == desired._jsonKey })?._jsonValue?.split(whereSeparator: {
                        $0.isWhitespace
                    })
                    .joined(separator: " ")
                        == desired._jsonValue.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                })
            else { throw GuestConfigObservationError.invalid }
        }

    }

    public init(
        generation: Int64, status: Status, error: String? = nil, failedItem: ItemFailure? = nil, packages: [Package],
        files: [File], services: [Service], sysctls: [Sysctl]
    ) {
        self.init()
        self._jsonGeneration = generation
        self._jsonStatus = status
        self._jsonError = error
        self._jsonFailedItem = failedItem
        self._jsonPackages = packages
        self._jsonFiles = files
        self._jsonServices = services
        self._jsonSysctls = sysctls
    }

    private enum CodingKeys: String, CodingKey {
        case generation; case status; case error; case failedItem; case packages; case files; case services;
        case sysctls
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonGeneration = try container.decode(Int64.self, forKey: .generation)
        self._jsonStatus = try container.decode(Status.self, forKey: .status)
        self._jsonError = try container.decodeIfPresent(String.self, forKey: .error)
        self._jsonFailedItem = try container.decodeIfPresent(ItemFailure.self, forKey: .failedItem)
        self._jsonPackages = try container.decode([Package].self, forKey: .packages)
        self._jsonFiles = try container.decode([File].self, forKey: .files)
        self._jsonServices = try container.decode([Service].self, forKey: .services)
        self._jsonSysctls = try container.decode([Sysctl].self, forKey: .sysctls)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonGeneration, forKey: .generation)
        try container.encode(_jsonStatus, forKey: .status)
        try container.encodeIfPresent(_jsonError, forKey: .error)
        try container.encodeIfPresent(_jsonFailedItem, forKey: .failedItem)
        try container.encode(_jsonPackages, forKey: .packages)
        try container.encode(_jsonFiles, forKey: .files)
        try container.encode(_jsonServices, forKey: .services)
        try container.encode(_jsonSysctls, forKey: .sysctls)
    }

    var _jsonGeneration: Int64 {
        get { generation }
        set { let value = newValue; generation = value }
    }
    var _jsonStatus: Status {
        get { status }
        set { let value = newValue; status = value }
    }
    var _jsonError: String? {
        get { hasError ? (error) : nil }
        set { if let value = newValue { error = value } else { clearError() } }
    }
    var _jsonFailedItem: ItemFailure? {
        get { hasFailedItem ? (failedItem) : nil }
        set { if let value = newValue { failedItem = value } else { clearFailedItem() } }
    }
    var _jsonPackages: [Package] {
        get { packages.values }
        set {
            let value = newValue;
            packages = Strato_Agent_V1_GuestConfigObservationPackagesSection.with { $0.values = value }
        }
    }
    var _jsonFiles: [File] {
        get { files.values }
        set {
            let value = newValue; files = Strato_Agent_V1_GuestConfigObservationFilesSection.with { $0.values = value }
        }
    }
    var _jsonServices: [Service] {
        get { services.values }
        set {
            let value = newValue;
            services = Strato_Agent_V1_GuestConfigObservationServicesSection.with { $0.values = value }
        }
    }
    var _jsonSysctls: [Sysctl] {
        get { sysctls.values }
        set {
            let value = newValue;
            sysctls = Strato_Agent_V1_GuestConfigObservationSysctlsSection.with { $0.values = value }
        }
    }
}

public enum GuestConfigObservationError: Error, LocalizedError, Sendable {
    case invalid
    public var errorDescription: String? { "Invalid guest configuration observation" }
}

public extension GuestConfig {
    /// Empty intent withdraws management exactly as nil intent does.
    var isEmpty: Bool {
        packages.values.isEmpty && files.values.isEmpty && services.values.isEmpty && sysctls.values.isEmpty
    }
}
