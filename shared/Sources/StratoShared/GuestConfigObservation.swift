import Foundation

/// Guest facts for only the currently managed STR-90 identities. Null facts
/// mean unavailable/absent; file contents and command output are never returned.
public struct GuestConfigObservation: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case converged, failed }
    public let generation: Int64
    public let status: Status
    public let error: String?
    public let packages: [Package]
    public let files: [File]
    public let services: [Service]
    public let sysctls: [Sysctl]

    public struct Package: Codable, Equatable, Sendable {
        public let name: String
        public let version: String?
    }
    public struct File: Codable, Equatable, Sendable {
        public let path: String
        public let sha256: String?
        public let mode: String?
    }
    public struct Service: Codable, Equatable, Sendable {
        public let name: String
        public let enabled: Bool?
        public let activeState: String?
    }
    public struct Sysctl: Codable, Equatable, Sendable {
        public let key: String
        public let value: String?
    }

    /// Validate hostile guest facts before retaining or forwarding them. A
    /// failed attempt may have only partial observations, but never foreign
    /// identities or duplicate entries. Successful reports must be complete.
    public func validate(for config: GuestConfig, generation: Int64) throws {
        guard self.generation == generation, generation >= 0,
            (status == .failed) == (error != nil),
            error.map({ !$0.isEmpty && $0.utf8.count <= 4096 }) ?? true
        else { throw GuestConfigObservationError.invalid }
        func identities(_ observed: [String], _ desired: [String]) -> Bool {
            let seen = Set(observed)
            let wanted = Set(desired)
            return observed.count <= 128 && seen.count == observed.count
                && seen.isSubset(of: wanted) && (status != .converged || seen == wanted)
        }
        guard identities(packages.map(\.name), config.packages.map(\.name)),
            identities(files.map(\.path), config.files.map(\.path)),
            identities(services.map(\.name), config.services.map(\.name)),
            identities(sysctls.map(\.key), config.sysctls.map(\.key)),
            packages.allSatisfy({ $0.version.map({ !$0.isEmpty && $0.utf8.count <= 255 }) ?? true }),
            files.allSatisfy({
                ($0.sha256.map({
                    $0.utf8.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
                }) ?? true)
                    && ($0.mode.map({ $0.utf8.count == 4 && $0.utf8.allSatisfy { (48...55).contains($0) } }) ?? true)
            }),
            services.allSatisfy({ $0.activeState.map({ !$0.isEmpty && $0.utf8.count <= 64 }) ?? true }),
            sysctls.allSatisfy({ $0.value.map({ $0.utf8.count <= 1024 }) ?? true })
        else { throw GuestConfigObservationError.invalid }
        if status == .converged {
            guard
                config.packages.allSatisfy({ desired in
                    packages.first(where: { $0.name == desired.name }).map {
                        ($0.version != nil) == (desired.state == .present)
                    } == true
                }),
                config.files.allSatisfy({ desired in
                    files.first(where: { $0.path == desired.path }).map { $0.sha256 != nil && $0.mode == desired.mode }
                        == true
                }),
                config.services.allSatisfy({ desired in
                    services.first(where: { $0.name == desired.name })?.enabled == desired.enabled
                }),
                config.sysctls.allSatisfy({ desired in
                    sysctls.first(where: { $0.key == desired.key })?.value?.split(whereSeparator: { $0.isWhitespace })
                        .joined(separator: " ")
                        == desired.value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                })
            else { throw GuestConfigObservationError.invalid }
        }

    }
}

public enum GuestConfigObservationError: Error, LocalizedError, Sendable {
    case invalid
    public var errorDescription: String? { "Invalid guest configuration observation" }
}
