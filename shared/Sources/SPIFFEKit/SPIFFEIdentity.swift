import Foundation

/// A SPIFFE workload identity in `spiffe://trust-domain/path` form.
public struct SPIFFEIdentity: Sendable, Equatable, Hashable, CustomStringConvertible {
    public let trustDomain: String
    public let path: String

    public var uri: String { "spiffe://\(trustDomain)\(path)" }
    public var description: String { uri }
    public var isAgent: Bool { path.hasPrefix("/agent/") }
    public var agentID: String? {
        guard isAgent else { return nil }
        return String(path.dropFirst("/agent/".count))
    }

    public init(trustDomain: String, path: String) {
        self.trustDomain = trustDomain
        self.path = path.hasPrefix("/") ? path : "/\(path)"
    }

    public init?(uri: String) {
        guard uri.hasPrefix("spiffe://") else { return nil }
        let value = String(uri.dropFirst("spiffe://".count))
        guard let slash = value.firstIndex(of: "/") else {
            self.trustDomain = value
            self.path = "/"
            return
        }
        self.trustDomain = String(value[..<slash])
        self.path = String(value[slash...])
    }
}

/// X.509 trust roots for one SPIFFE trust domain.
public struct SPIFFETrustBundle: Sendable {
    public let trustDomain: String
    public let x509Authorities: [String]
    public let refreshedAt: Date
    public let sequenceNumber: UInt64

    public init(
        trustDomain: String,
        x509Authorities: [String],
        refreshedAt: Date = Date(),
        sequenceNumber: UInt64 = 0
    ) {
        self.trustDomain = trustDomain
        self.x509Authorities = x509Authorities
        self.refreshedAt = refreshedAt
        self.sequenceNumber = sequenceNumber
    }
}
