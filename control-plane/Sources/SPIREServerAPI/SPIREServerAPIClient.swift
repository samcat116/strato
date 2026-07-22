import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import GRPCProtobuf
import Logging
import NIOCore
import NIOSSL
import SPIFFEVerification
import SwiftProtobuf
import X509

// MARK: - Protocol

/// The subset of the SPIRE Server registration API the control plane uses to
/// provision hypervisor nodes: minting one-time join tokens for node
/// attestation and managing the workload registration entries that entitle a
/// node's strato-agent to its SVID.
///
/// A protocol so the registration flow can be tested against a fake without a
/// SPIRE server.
public protocol SPIREServerAPI: Sendable {
    /// Mint a one-time join token for node attestation.
    ///
    /// - Parameters:
    ///   - ttlSeconds: How long the token stays redeemable.
    ///   - agentID: Optional SPIFFE ID to assign to the attested node instead
    ///     of the default `.../spire/agent/join_token/<token>` identity. Using
    ///     a stable per-node ID here means re-provisioning a node with a fresh
    ///     token preserves the parentage of its workload entries.
    func createJoinToken(ttlSeconds: Int32, agentID: String?) async throws -> SPIREJoinToken

    /// Create a workload registration entry. Returns the entry ID; creating an
    /// entry identical to an existing one reports `alreadyExists` with the
    /// existing entry's ID rather than failing.
    ///
    /// - Parameters:
    ///   - federatesWith: Trust domains the identity federates with, so its
    ///     workloads receive those domains' bundles alongside their SVID.
    ///   - admin: Whether the identity may call the server's managerial APIs
    ///     (the entitlement the control plane's own admin SVID carries).
    func createEntry(
        spiffeID: String,
        parentID: String,
        selectors: [SPIRESelector],
        x509SVIDTTLSeconds: Int32,
        federatesWith: [String],
        admin: Bool
    ) async throws -> SPIREEntryCreationResult

    /// Update existing registration entries in one batch. Each update carries
    /// the entry ID plus only the fields to change; unset fields are left
    /// alone (they are excluded from the request's field mask). Returns the
    /// updated entries in request order; any per-entry failure throws.
    func updateEntries(_ updates: [SPIREEntryUpdate]) async throws -> [SPIREEntry]

    /// Delete all registration entries whose SPIFFE ID matches. Returns the
    /// number of entries deleted (0 when none matched).
    func deleteEntries(spiffeID: String) async throws -> Int

    /// Evict an attested agent, forcing it to re-attest (which, for join-token
    /// nodes, requires a fresh join token). Returns false when no agent with
    /// that ID is currently attested — eviction is idempotent.
    func evictAgent(spiffeID: String) async throws -> Bool

    /// List every workload registration entry known to the SPIRE server.
    /// Read-only; used to surface the trust domain's identities in the UI.
    func listEntries() async throws -> [SPIREEntry]

    /// List every agent node that has attested to the SPIRE server. Read-only;
    /// used to surface node attestation state in the UI.
    func listAgents() async throws -> [SPIREAgent]

    /// List the trust domain's federation relationships — the peer trust
    /// domains this server federates with — including the peer bundle SPIRE
    /// currently holds for each. Read-only; backs the Federation panel of the
    /// Workload Identity view.
    func listFederationRelationships() async throws -> [SPIREFederationRelationship]

    /// Fetch this server's own trust bundle — the authorities a peer trust
    /// domain must hold to verify identities issued here. Seeding federation
    /// in both directions is a matter of reading each side's bundle and
    /// handing it to the other.
    func getBundle() async throws -> SPIREBundle

    /// Create federation relationships with foreign trust domains. A
    /// relationship for a trust domain that already has one reports
    /// `alreadyExists` rather than failing, so provisioning can be replayed.
    func createFederationRelationships(
        _ relationships: [SPIREFederationRelationshipInput]
    ) async throws -> [SPIREFederationRelationshipCreationResult]

    /// Replace existing federation relationships. The endpoint URL and profile
    /// are always updated; the peer bundle is only touched for inputs that
    /// carry one, so an update without a bundle leaves the bundle SPIRE
    /// already holds intact. Any per-relationship failure throws.
    func updateFederationRelationships(
        _ relationships: [SPIREFederationRelationshipInput]
    ) async throws -> [SPIREFederationRelationship]

    /// Delete federation relationships by peer trust domain name. Returns the
    /// trust domains actually deleted — a name with no relationship is not an
    /// error, so teardown is idempotent.
    func deleteFederationRelationships(trustDomains: [String]) async throws -> [String]
}

extension SPIREServerAPI {
    /// Create an entry that neither federates nor carries admin rights — the
    /// shape the node/agent registration flow provisions.
    public func createEntry(
        spiffeID: String,
        parentID: String,
        selectors: [SPIRESelector],
        x509SVIDTTLSeconds: Int32
    ) async throws -> SPIREEntryCreationResult {
        try await createEntry(
            spiffeID: spiffeID,
            parentID: parentID,
            selectors: selectors,
            x509SVIDTTLSeconds: x509SVIDTTLSeconds,
            federatesWith: [],
            admin: false
        )
    }
}

// MARK: - Data types

public struct SPIREJoinToken: Sendable {
    public let value: String
    public let expiresAt: Date

    public init(value: String, expiresAt: Date) {
        self.value = value
        self.expiresAt = expiresAt
    }
}

public struct SPIRESelector: Sendable, Equatable {
    public let type: String
    public let value: String

    public init(type: String, value: String) {
        self.type = type
        self.value = value
    }

    /// Parse a `type:value` string (e.g. `unix:uid:0` → type `unix`,
    /// value `uid:0`). Returns nil when there is no `:` separator.
    public init?(string: String) {
        guard let separator = string.firstIndex(of: ":"), separator != string.startIndex else { return nil }
        let value = String(string[string.index(after: separator)...])
        guard !value.isEmpty else { return nil }
        self.type = String(string[..<separator])
        self.value = value
    }
}

public enum SPIREEntryCreationResult: Sendable, Equatable {
    case created(entryID: String)
    case alreadyExists(entryID: String)

    public var entryID: String {
        switch self {
        case .created(let id), .alreadyExists(let id):
            return id
        }
    }
}

/// A workload registration entry as reported by the SPIRE server's read API.
/// A read-only projection of `spire.api.types.Entry` carrying the fields the
/// control plane surfaces (the write path uses the proto types directly).
public struct SPIREEntry: Sendable, Equatable {
    public let id: String
    public let spiffeID: String
    /// Parent identity: the SPIRE server (for node entries) or a node ID.
    public let parentID: String
    public let selectors: [SPIRESelector]
    public let x509SVIDTTLSeconds: Int32
    /// TTL for JWT-SVIDs; `0` when the entry issues no JWT-SVIDs.
    public let jwtSVIDTTLSeconds: Int32
    /// Trust domains this identity federates with.
    public let federatesWith: [String]
    public let admin: Bool
    public let downstream: Bool
    public let hint: String
    /// When the entry's issued identity expires, if the server set an expiry.
    public let expiresAt: Date?
    /// When the entry was created, if reported.
    public let createdAt: Date?

    public init(
        id: String,
        spiffeID: String,
        parentID: String,
        selectors: [SPIRESelector],
        x509SVIDTTLSeconds: Int32,
        jwtSVIDTTLSeconds: Int32,
        federatesWith: [String],
        admin: Bool,
        downstream: Bool,
        hint: String,
        expiresAt: Date?,
        createdAt: Date?
    ) {
        self.id = id
        self.spiffeID = spiffeID
        self.parentID = parentID
        self.selectors = selectors
        self.x509SVIDTTLSeconds = x509SVIDTTLSeconds
        self.jwtSVIDTTLSeconds = jwtSVIDTTLSeconds
        self.federatesWith = federatesWith
        self.admin = admin
        self.downstream = downstream
        self.hint = hint
        self.expiresAt = expiresAt
        self.createdAt = createdAt
    }
}

/// An attested agent node as reported by the SPIRE server's read API.
/// A read-only projection of `spire.api.types.Agent`.
public struct SPIREAgent: Sendable, Equatable {
    public let spiffeID: String
    public let attestationType: String
    public let x509SVIDSerialNumber: String
    /// When the node's current agent SVID expires, if reported.
    public let x509SVIDExpiresAt: Date?
    public let selectors: [SPIRESelector]
    public let banned: Bool
    public let canReattest: Bool
    public let agentVersion: String

    public init(
        spiffeID: String,
        attestationType: String,
        x509SVIDSerialNumber: String,
        x509SVIDExpiresAt: Date?,
        selectors: [SPIRESelector],
        banned: Bool,
        canReattest: Bool,
        agentVersion: String
    ) {
        self.spiffeID = spiffeID
        self.attestationType = attestationType
        self.x509SVIDSerialNumber = x509SVIDSerialNumber
        self.x509SVIDExpiresAt = x509SVIDExpiresAt
        self.selectors = selectors
        self.banned = banned
        self.canReattest = canReattest
        self.agentVersion = agentVersion
    }
}

/// A federation relationship as reported by the SPIRE server's trustdomain
/// read API: a peer trust domain this server federates with, plus a summary of
/// the peer bundle SPIRE currently holds for it. A read-only projection of
/// `spire.api.types.FederationRelationship`.
///
/// SPIRE does not expose an explicit per-relationship health field, so callers
/// infer sync state from the presence of authorities in the held bundle: SPIRE
/// only holds a peer bundle once it has successfully fetched (or been
/// bootstrapped with) one. Use `bundleAuthorityCount` (X.509 *or* JWT) rather
/// than X.509 alone, since a JWT-only trust domain has a valid bundle with zero
/// X.509 authorities.
public struct SPIREFederationRelationship: Sendable, Equatable {
    /// The peer trust domain name (e.g. `partner.example`), without scheme.
    public let trustDomain: String
    /// URL of the peer's SPIFFE bundle endpoint.
    public let bundleEndpointURL: String
    /// Endpoint profile: `https_spiffe`, `https_web`, or `unknown`.
    public let bundleEndpointProfile: String
    /// Expected SPIFFE ID of the bundle endpoint (`https_spiffe` profile only).
    public let endpointSPIFFEID: String?
    /// X.509 authorities in the peer bundle SPIRE currently holds; `0` when no
    /// bundle has been fetched or bootstrapped yet.
    public let bundleX509AuthorityCount: Int
    /// JWT authorities in the peer bundle SPIRE currently holds; `0` when none.
    public let bundleJWTAuthorityCount: Int
    /// Sequence number of the held peer bundle; `0` when absent.
    public let bundleSequenceNumber: UInt64

    /// Total authorities (X.509 + JWT) in the held peer bundle. Zero means
    /// SPIRE holds no usable bundle yet — the "not synced" signal.
    public var bundleAuthorityCount: Int { bundleX509AuthorityCount + bundleJWTAuthorityCount }

    public init(
        trustDomain: String,
        bundleEndpointURL: String,
        bundleEndpointProfile: String,
        endpointSPIFFEID: String?,
        bundleX509AuthorityCount: Int,
        bundleJWTAuthorityCount: Int = 0,
        bundleSequenceNumber: UInt64
    ) {
        self.trustDomain = trustDomain
        self.bundleEndpointURL = bundleEndpointURL
        self.bundleEndpointProfile = bundleEndpointProfile
        self.endpointSPIFFEID = endpointSPIFFEID
        self.bundleX509AuthorityCount = bundleX509AuthorityCount
        self.bundleJWTAuthorityCount = bundleJWTAuthorityCount
        self.bundleSequenceNumber = bundleSequenceNumber
    }
}

/// An X.509 authority in a trust bundle: a CA certificate SVIDs of that trust
/// domain chain to.
public struct SPIREX509Authority: Sendable, Equatable {
    /// The ASN.1 DER encoding of the CA certificate.
    public let der: Data
    /// SPIRE has marked this authority compromised; it must not be used.
    public let tainted: Bool

    public init(der: Data, tainted: Bool = false) {
        self.der = der
        self.tainted = tainted
    }
}

/// A JWT signing authority in a trust bundle.
public struct SPIREJWTAuthority: Sendable, Equatable {
    public let keyID: String
    /// The PKIX-encoded public key.
    public let publicKey: Data
    /// When the key expires; nil when it does not.
    public let expiresAt: Date?
    /// SPIRE has marked this authority compromised; it must not be used.
    public let tainted: Bool

    public init(keyID: String, publicKey: Data, expiresAt: Date?, tainted: Bool = false) {
        self.keyID = keyID
        self.publicKey = publicKey
        self.expiresAt = expiresAt
        self.tainted = tainted
    }
}

/// A trust domain's bundle: the authorities that verify identities issued in
/// that domain. A projection of `spire.api.types.Bundle`. Federating two trust
/// domains means giving each one the other's bundle.
public struct SPIREBundle: Sendable, Equatable {
    public let trustDomain: String
    public let x509Authorities: [SPIREX509Authority]
    public let jwtAuthorities: [SPIREJWTAuthority]
    /// How often SPIRE suggests refetching this bundle, in seconds; `0` when
    /// the server offers no hint.
    public let refreshHintSeconds: Int64
    /// Bumped by SPIRE every time the bundle's contents change.
    public let sequenceNumber: UInt64

    public init(
        trustDomain: String,
        x509Authorities: [SPIREX509Authority],
        jwtAuthorities: [SPIREJWTAuthority] = [],
        refreshHintSeconds: Int64 = 0,
        sequenceNumber: UInt64 = 0
    ) {
        self.trustDomain = trustDomain
        self.x509Authorities = x509Authorities
        self.jwtAuthorities = jwtAuthorities
        self.refreshHintSeconds = refreshHintSeconds
        self.sequenceNumber = sequenceNumber
    }
}

/// How a peer trust domain's bundle endpoint authenticates itself.
public enum SPIREBundleEndpointProfile: Sendable, Equatable {
    /// The endpoint presents a Web PKI certificate.
    case httpsWeb
    /// The endpoint presents an SVID with this SPIFFE ID — verifying it needs
    /// a bundle for that domain to already be in place, which is what the
    /// `trustDomainBundle` on a relationship input supplies.
    case httpsSPIFFE(endpointSPIFFEID: String)
}

/// A federation relationship to create or replace: which peer trust domain,
/// where to fetch its bundle, how to authenticate that endpoint, and
/// optionally the peer bundle to seed so the first fetch can be verified.
public struct SPIREFederationRelationshipInput: Sendable, Equatable {
    public let trustDomain: String
    public let bundleEndpointURL: String
    public let bundleEndpointProfile: SPIREBundleEndpointProfile
    /// The peer's bundle to store alongside the relationship. Required to
    /// bootstrap an `https_spiffe` relationship (SPIRE cannot verify the
    /// endpoint's SVID without it); omit to leave a stored bundle untouched.
    public let trustDomainBundle: SPIREBundle?

    public init(
        trustDomain: String,
        bundleEndpointURL: String,
        bundleEndpointProfile: SPIREBundleEndpointProfile,
        trustDomainBundle: SPIREBundle? = nil
    ) {
        self.trustDomain = trustDomain
        self.bundleEndpointURL = bundleEndpointURL
        self.bundleEndpointProfile = bundleEndpointProfile
        self.trustDomainBundle = trustDomainBundle
    }
}

public enum SPIREFederationRelationshipCreationResult: Sendable, Equatable {
    case created(trustDomain: String)
    case alreadyExists(trustDomain: String)

    public var trustDomain: String {
        switch self {
        case .created(let trustDomain), .alreadyExists(let trustDomain):
            return trustDomain
        }
    }
}

/// A change to an existing registration entry: the entry ID plus the fields to
/// set. Every field is optional — only those provided are sent (and named in
/// the request's field mask), so an update never disturbs the rest of the
/// entry.
public struct SPIREEntryUpdate: Sendable, Equatable {
    public let id: String
    public let spiffeID: String?
    public let parentID: String?
    public let selectors: [SPIRESelector]?
    public let x509SVIDTTLSeconds: Int32?
    public let federatesWith: [String]?
    public let admin: Bool?

    public init(
        id: String,
        spiffeID: String? = nil,
        parentID: String? = nil,
        selectors: [SPIRESelector]? = nil,
        x509SVIDTTLSeconds: Int32? = nil,
        federatesWith: [String]? = nil,
        admin: Bool? = nil
    ) {
        self.id = id
        self.spiffeID = spiffeID
        self.parentID = parentID
        self.selectors = selectors
        self.x509SVIDTTLSeconds = x509SVIDTTLSeconds
        self.federatesWith = federatesWith
        self.admin = admin
    }
}

public enum SPIREServerAPIError: Error, LocalizedError {
    case invalidAddress(String)
    case unreachable(String)
    case requestFailed(String)
    case notFound(String)
    case invalidArgument(String)
    case invalidSPIFFEID(String)
    /// The control plane could not obtain its own SVID from the SPIFFE
    /// Workload API, so the mTLS admin connection cannot be established.
    /// Distinct from `unreachable` so operators can tell "the SPIRE server is
    /// down" from "this pod has no workload identity".
    case workloadIdentityUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAddress(let details):
            return "Invalid SPIRE server API address: \(details)"
        case .unreachable(let details):
            return "SPIRE server unreachable: \(details)"
        case .requestFailed(let details):
            return "SPIRE server request failed: \(details)"
        case .notFound(let details):
            return "SPIRE server reports no such resource: \(details)"
        case .invalidArgument(let details):
            return "SPIRE server rejected the argument: \(details)"
        case .invalidSPIFFEID(let id):
            return "Invalid SPIFFE ID: \(id)"
        case .workloadIdentityUnavailable(let details):
            return "SPIFFE Workload API identity unavailable: \(details)"
        }
    }
}

// MARK: - Address

/// Where to reach the SPIRE server's registration API.
///
/// SPIRE serves this API as gRPC on a local Unix socket (callers on that
/// socket are implicitly admin). The canonical single-host deployment shares
/// the socket directory with the control plane container (`unix:///run/spire/
/// server/api.sock`), or bridges it to loopback TCP (socat) where a Unix
/// socket cannot cross the Docker VM boundary. Plaintext TCP carries no
/// authentication, so it must never be exposed beyond loopback.
///
/// SPIRE also serves the same RPCs on its network-facing TCP endpoint, but
/// only over TLS and only for clients whose registration entry carries
/// `admin = true` — that is the Kubernetes path, where the control plane and
/// SPIRE server are separate pods. Reaching it requires the mTLS transport
/// security mode (`SPIREServerAPITransportSecurity.mtls`).
public enum SPIREServerAPIAddress: Sendable, Equatable {
    case unixSocket(path: String)
    case tcp(host: String, port: Int)

    /// Parse `unix:///path/to/api.sock`, `tcp://host:port`, or bare `host:port`.
    public init(parsing string: String) throws {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("unix://") {
            let path = String(trimmed.dropFirst("unix://".count))
            guard path.hasPrefix("/") else {
                throw SPIREServerAPIError.invalidAddress("Unix socket path must be absolute: \(string)")
            }
            self = .unixSocket(path: path)
            return
        }

        var hostPort = trimmed
        if hostPort.hasPrefix("tcp://") {
            hostPort = String(hostPort.dropFirst("tcp://".count))
        }
        guard let colon = hostPort.lastIndex(of: ":"),
            let port = Int(hostPort[hostPort.index(after: colon)...]),
            port > 0, port <= 65535, colon != hostPort.startIndex
        else {
            throw SPIREServerAPIError.invalidAddress(
                "Expected unix:///path or host:port, got: \(string)")
        }
        self = .tcp(host: String(hostPort[..<colon]), port: port)
    }
}

// MARK: - Transport security

/// Which SPIRE server the mTLS path expects to find at the far end, and what
/// to verify its certificate against.
///
/// The default (`own`) is the single-trust-domain case: the server must be
/// `spiffe://<own-td>/spire/server`, chaining to the client's own bundle.
/// Dialing a server in a *different* trust domain — a per-organization SPIRE
/// instance federated with the platform domain — means presenting the same
/// platform SVID but pinning and verifying against that domain instead, which
/// is what `trustDomain(_:bundlePEM:)` expresses.
public struct SPIREServerPeer: Sendable, Equatable {
    /// SPIFFE ID the server must present, or nil to derive
    /// `spiffe://<td>/spire/server` from the client's own SVID.
    public let expectedServerSPIFFEID: String?
    /// PEM X.509 authorities to verify the server chain against, or nil to use
    /// the client's own trust bundle.
    public let trustRootsPEM: [String]?

    /// The SPIRE server of the client's own trust domain.
    public static let own = SPIREServerPeer(expectedServerSPIFFEID: nil, trustRootsPEM: nil)

    /// The SPIRE server of `trustDomain`, verified against that domain's own
    /// bundle. A union with the client's bundle would let either domain's CA
    /// vouch for the peer, so the peer's roots are used alone.
    public static func trustDomain(_ trustDomain: String, bundlePEM: [String]) -> SPIREServerPeer {
        SPIREServerPeer(
            expectedServerSPIFFEID: "spiffe://\(trustDomain)/spire/server",
            trustRootsPEM: bundlePEM
        )
    }

    public init(expectedServerSPIFFEID: String?, trustRootsPEM: [String]?) {
        self.expectedServerSPIFFEID = expectedServerSPIFFEID
        self.trustRootsPEM = trustRootsPEM
    }
}

/// How the client secures its connection to the SPIRE server API.
public enum SPIREServerAPITransportSecurity: Sendable {
    /// Plaintext gRPC: the admin Unix socket (callers are implicitly admin)
    /// or a loopback TCP bridge in front of it. Must never cross a network.
    case plaintext

    /// Mutual TLS for the SPIRE server's network TCP endpoint: the client
    /// presents its own SVID (whose registration entry must carry
    /// `admin = true`) from `identityProvider` and verifies the server against
    /// `peer`. Hostname verification is skipped — SPIRE server TLS
    /// certificates carry a SPIFFE URI SAN, not the DNS name of a Kubernetes
    /// Service — so trust rests on the chain to a trust domain's CA plus the
    /// pinned server SPIFFE ID.
    case mtls(identityProvider: any SPIREClientIdentityProvider, peer: SPIREServerPeer)

    /// mTLS to the SPIRE server of the client's own trust domain.
    public static func mtls(identityProvider: any SPIREClientIdentityProvider) -> Self {
        .mtls(identityProvider: identityProvider, peer: .own)
    }
}

// MARK: - gRPC client

/// gRPC client for the SPIRE Server registration API using manual method
/// descriptors (see Generated/README.md — no gRPC codegen plugin required).
/// Connections are scoped per call: registration-token minting is a rare,
/// admin-driven operation, so holding a connection open buys nothing.
public struct SPIREServerAPIClient: SPIREServerAPI {
    private let address: SPIREServerAPIAddress
    private let transportSecurity: SPIREServerAPITransportSecurity
    private let logger: Logger
    private let timeout: Duration

    private static let createJoinTokenDescriptor = MethodDescriptor(
        service: ServiceDescriptor(fullyQualifiedService: "spire.api.server.agent.v1.Agent"),
        method: "CreateJoinToken"
    )

    private static let batchCreateEntryDescriptor = MethodDescriptor(
        service: ServiceDescriptor(fullyQualifiedService: "spire.api.server.entry.v1.Entry"),
        method: "BatchCreateEntry"
    )

    private static let listEntriesDescriptor = MethodDescriptor(
        service: ServiceDescriptor(fullyQualifiedService: "spire.api.server.entry.v1.Entry"),
        method: "ListEntries"
    )

    private static let batchDeleteEntryDescriptor = MethodDescriptor(
        service: ServiceDescriptor(fullyQualifiedService: "spire.api.server.entry.v1.Entry"),
        method: "BatchDeleteEntry"
    )

    private static let deleteAgentDescriptor = MethodDescriptor(
        service: ServiceDescriptor(fullyQualifiedService: "spire.api.server.agent.v1.Agent"),
        method: "DeleteAgent"
    )

    private static let listAgentsDescriptor = MethodDescriptor(
        service: ServiceDescriptor(fullyQualifiedService: "spire.api.server.agent.v1.Agent"),
        method: "ListAgents"
    )

    private static let listFederationRelationshipsDescriptor = MethodDescriptor(
        service: ServiceDescriptor(fullyQualifiedService: "spire.api.server.trustdomain.v1.TrustDomain"),
        method: "ListFederationRelationships"
    )

    private static let batchUpdateEntryDescriptor = MethodDescriptor(
        service: ServiceDescriptor(fullyQualifiedService: "spire.api.server.entry.v1.Entry"),
        method: "BatchUpdateEntry"
    )

    private static let getBundleDescriptor = MethodDescriptor(
        service: ServiceDescriptor(fullyQualifiedService: "spire.api.server.bundle.v1.Bundle"),
        method: "GetBundle"
    )

    private static let batchCreateFederationRelationshipDescriptor = MethodDescriptor(
        service: ServiceDescriptor(fullyQualifiedService: "spire.api.server.trustdomain.v1.TrustDomain"),
        method: "BatchCreateFederationRelationship"
    )

    private static let batchUpdateFederationRelationshipDescriptor = MethodDescriptor(
        service: ServiceDescriptor(fullyQualifiedService: "spire.api.server.trustdomain.v1.TrustDomain"),
        method: "BatchUpdateFederationRelationship"
    )

    private static let batchDeleteFederationRelationshipDescriptor = MethodDescriptor(
        service: ServiceDescriptor(fullyQualifiedService: "spire.api.server.trustdomain.v1.TrustDomain"),
        method: "BatchDeleteFederationRelationship"
    )

    /// google.rpc.Code values SPIRE reports in per-entry batch results.
    private enum RPCCode {
        static let ok: Int32 = 0
        static let notFound: Int32 = 5
        static let alreadyExists: Int32 = 6
    }

    public init(
        address: SPIREServerAPIAddress,
        transportSecurity: SPIREServerAPITransportSecurity = .plaintext,
        logger: Logger,
        timeout: Duration = .seconds(10)
    ) {
        self.address = address
        self.transportSecurity = transportSecurity
        self.logger = logger
        self.timeout = timeout
    }

    // MARK: SPIREServerAPI

    public func createJoinToken(ttlSeconds: Int32, agentID: String?) async throws -> SPIREJoinToken {
        var request = Spire_Api_Server_Agent_V1_CreateJoinTokenRequest()
        request.ttl = ttlSeconds
        if let agentID {
            request.agentID = try Self.spiffeIDPayload(agentID)
        }

        let token: Spire_Api_Types_JoinToken = try await unary(
            request, descriptor: Self.createJoinTokenDescriptor)

        guard !token.value.isEmpty else {
            throw SPIREServerAPIError.requestFailed("SPIRE returned an empty join token")
        }

        return SPIREJoinToken(
            value: token.value,
            expiresAt: Date(timeIntervalSince1970: TimeInterval(token.expiresAt))
        )
    }

    public func createEntry(
        spiffeID: String,
        parentID: String,
        selectors: [SPIRESelector],
        x509SVIDTTLSeconds: Int32,
        federatesWith: [String],
        admin: Bool
    ) async throws -> SPIREEntryCreationResult {
        var entry = Spire_Api_Types_Entry()
        entry.spiffeID = try Self.spiffeIDPayload(spiffeID)
        entry.parentID = try Self.spiffeIDPayload(parentID)
        entry.selectors = selectors.map(Self.selectorPayload(_:))
        entry.x509SvidTtl = x509SVIDTTLSeconds
        entry.federatesWith = federatesWith
        entry.admin = admin

        var request = Spire_Api_Server_Entry_V1_BatchCreateEntryRequest()
        request.entries = [entry]

        let response: Spire_Api_Server_Entry_V1_BatchCreateEntryResponse = try await unary(
            request, descriptor: Self.batchCreateEntryDescriptor)

        guard let result = response.results.first else {
            throw SPIREServerAPIError.requestFailed("BatchCreateEntry returned no results")
        }

        switch result.status.code {
        case RPCCode.ok:
            return .created(entryID: result.entry.id)
        case RPCCode.alreadyExists:
            // SPIRE returns the existing (similar) entry alongside the status.
            return .alreadyExists(entryID: result.entry.id)
        default:
            throw SPIREServerAPIError.requestFailed(
                "BatchCreateEntry failed for \(spiffeID): \(result.status.code) \(result.status.message)")
        }
    }

    public func updateEntries(_ updates: [SPIREEntryUpdate]) async throws -> [SPIREEntry] {
        guard !updates.isEmpty else { return [] }

        // SPIRE applies one input mask to the whole batch, so the mask is the
        // union of the fields any update touches. An update that leaves a
        // masked field unset would therefore clear it — reject mixed batches
        // rather than silently wiping fields off the other entries.
        var mask = Spire_Api_Types_EntryMask()
        mask.spiffeID = updates.contains { $0.spiffeID != nil }
        mask.parentID = updates.contains { $0.parentID != nil }
        mask.selectors = updates.contains { $0.selectors != nil }
        mask.x509SvidTtl = updates.contains { $0.x509SVIDTTLSeconds != nil }
        mask.federatesWith = updates.contains { $0.federatesWith != nil }
        mask.admin = updates.contains { $0.admin != nil }

        for update in updates {
            let inconsistent =
                (mask.spiffeID && update.spiffeID == nil)
                || (mask.parentID && update.parentID == nil)
                || (mask.selectors && update.selectors == nil)
                || (mask.x509SvidTtl && update.x509SVIDTTLSeconds == nil)
                || (mask.federatesWith && update.federatesWith == nil)
                || (mask.admin && update.admin == nil)
            guard !inconsistent else {
                throw SPIREServerAPIError.invalidArgument(
                    "BatchUpdateEntry: every update in a batch must set the same fields; entry \(update.id) does not"
                )
            }
        }

        var request = Spire_Api_Server_Entry_V1_BatchUpdateEntryRequest()
        request.inputMask = mask
        request.entries = try updates.map { update in
            var entry = Spire_Api_Types_Entry()
            entry.id = update.id
            if let spiffeID = update.spiffeID {
                entry.spiffeID = try Self.spiffeIDPayload(spiffeID)
            }
            if let parentID = update.parentID {
                entry.parentID = try Self.spiffeIDPayload(parentID)
            }
            if let selectors = update.selectors {
                entry.selectors = selectors.map(Self.selectorPayload(_:))
            }
            if let ttl = update.x509SVIDTTLSeconds {
                entry.x509SvidTtl = ttl
            }
            if let federatesWith = update.federatesWith {
                entry.federatesWith = federatesWith
            }
            if let admin = update.admin {
                entry.admin = admin
            }
            return entry
        }

        let response: Spire_Api_Server_Entry_V1_BatchUpdateEntryResponse = try await unary(
            request, descriptor: Self.batchUpdateEntryDescriptor)
        try Self.expectResultCount(response.results.count, requested: updates.count, rpc: "BatchUpdateEntry")

        return try response.results.map { result in
            guard result.status.code == RPCCode.ok else {
                throw SPIREServerAPIError.requestFailed(
                    "BatchUpdateEntry failed for entry \(result.entry.id): \(result.status.code) \(result.status.message)"
                )
            }
            return Self.entry(from: result.entry)
        }
    }

    public func deleteEntries(spiffeID: String) async throws -> Int {
        // Page through the full result set: the server may impose its own page
        // size even when none is requested, and deleting only the first page
        // would silently leave later entries (and thus SVID issuance) intact.
        var entryIDs: [String] = []
        var pageToken = ""
        repeat {
            var listRequest = Spire_Api_Server_Entry_V1_ListEntriesRequest()
            listRequest.filter.bySpiffeID = try Self.spiffeIDPayload(spiffeID)
            listRequest.pageToken = pageToken

            let listResponse: Spire_Api_Server_Entry_V1_ListEntriesResponse = try await unary(
                listRequest, descriptor: Self.listEntriesDescriptor)

            entryIDs.append(contentsOf: listResponse.entries.map(\.id))
            pageToken = listResponse.nextPageToken
        } while !pageToken.isEmpty

        guard !entryIDs.isEmpty else { return 0 }

        var deleteRequest = Spire_Api_Server_Entry_V1_BatchDeleteEntryRequest()
        deleteRequest.ids = entryIDs

        let deleteResponse: Spire_Api_Server_Entry_V1_BatchDeleteEntryResponse = try await unary(
            deleteRequest, descriptor: Self.batchDeleteEntryDescriptor)

        for result in deleteResponse.results where result.status.code != RPCCode.ok {
            throw SPIREServerAPIError.requestFailed(
                "BatchDeleteEntry failed for entry \(result.id): \(result.status.code) \(result.status.message)")
        }

        return entryIDs.count
    }

    public func evictAgent(spiffeID: String) async throws -> Bool {
        var request = Spire_Api_Server_Agent_V1_DeleteAgentRequest()
        request.id = try Self.spiffeIDPayload(spiffeID)

        do {
            let _: Google_Protobuf_Empty = try await unary(request, descriptor: Self.deleteAgentDescriptor)
            return true
        } catch SPIREServerAPIError.notFound {
            // The node never attested (or was already evicted): nothing to do.
            return false
        }
    }

    /// Page size requested from the SPIRE server's list APIs. SPIRE only engages
    /// datastore pagination when `page_size > 0` (leaving it 0 makes it return
    /// the entire result set in a single response), so an explicit bound is what
    /// keeps these reads paging in chunks rather than loading a whole trust
    /// domain at once.
    private static let listPageSize: Int32 = 100

    public func listEntries() async throws -> [SPIREEntry] {
        var entries: [SPIREEntry] = []
        var pageToken = ""
        repeat {
            var request = Spire_Api_Server_Entry_V1_ListEntriesRequest()
            request.pageSize = Self.listPageSize
            request.pageToken = pageToken

            let response: Spire_Api_Server_Entry_V1_ListEntriesResponse = try await unary(
                request, descriptor: Self.listEntriesDescriptor)

            entries.append(contentsOf: response.entries.map(Self.entry(from:)))
            pageToken = response.nextPageToken
        } while !pageToken.isEmpty
        return entries
    }

    public func listAgents() async throws -> [SPIREAgent] {
        var agents: [SPIREAgent] = []
        var pageToken = ""
        repeat {
            var request = Spire_Api_Server_Agent_V1_ListAgentsRequest()
            request.pageSize = Self.listPageSize
            request.pageToken = pageToken

            let response: Spire_Api_Server_Agent_V1_ListAgentsResponse = try await unary(
                request, descriptor: Self.listAgentsDescriptor)

            agents.append(contentsOf: response.agents.map(Self.agent(from:)))
            pageToken = response.nextPageToken
        } while !pageToken.isEmpty
        return agents
    }

    public func listFederationRelationships() async throws -> [SPIREFederationRelationship] {
        var relationships: [SPIREFederationRelationship] = []
        var pageToken = ""
        repeat {
            var request = Spire_Api_Server_Trustdomain_V1_ListFederationRelationshipsRequest()
            request.pageSize = Self.listPageSize
            request.pageToken = pageToken
            // Ask for the stored peer bundle (and the other maskable fields) so
            // the read model can report sync state; an unset mask would let the
            // server omit the bundle.
            var mask = Spire_Api_Types_FederationRelationshipMask()
            mask.bundleEndpointURL = true
            mask.bundleEndpointProfile = true
            mask.trustDomainBundle = true
            request.outputMask = mask

            let response: Spire_Api_Server_Trustdomain_V1_ListFederationRelationshipsResponse =
                try await unary(request, descriptor: Self.listFederationRelationshipsDescriptor)

            relationships.append(
                contentsOf: response.federationRelationships.map(Self.federationRelationship(from:)))
            pageToken = response.nextPageToken
        } while !pageToken.isEmpty
        return relationships
    }

    public func getBundle() async throws -> SPIREBundle {
        // No output mask: the caller wants the whole bundle (an unset mask
        // means "all fields" for this RPC).
        let bundle: Spire_Api_Types_Bundle = try await unary(
            Spire_Api_Server_Bundle_V1_GetBundleRequest(), descriptor: Self.getBundleDescriptor)
        return Self.bundle(from: bundle)
    }

    public func createFederationRelationships(
        _ relationships: [SPIREFederationRelationshipInput]
    ) async throws -> [SPIREFederationRelationshipCreationResult] {
        guard !relationships.isEmpty else { return [] }

        var request = Spire_Api_Server_Trustdomain_V1_BatchCreateFederationRelationshipRequest()
        request.federationRelationships = relationships.map(Self.federationRelationshipPayload(from:))

        let response: Spire_Api_Server_Trustdomain_V1_BatchCreateFederationRelationshipResponse =
            try await unary(request, descriptor: Self.batchCreateFederationRelationshipDescriptor)
        try Self.expectResultCount(
            response.results.count, requested: relationships.count,
            rpc: "BatchCreateFederationRelationship")

        return try zip(relationships, response.results).map { input, result in
            switch result.status.code {
            case RPCCode.ok:
                return .created(trustDomain: input.trustDomain)
            case RPCCode.alreadyExists:
                return .alreadyExists(trustDomain: input.trustDomain)
            default:
                throw SPIREServerAPIError.requestFailed(
                    "BatchCreateFederationRelationship failed for \(input.trustDomain): \(result.status.code) \(result.status.message)"
                )
            }
        }
    }

    public func updateFederationRelationships(
        _ relationships: [SPIREFederationRelationshipInput]
    ) async throws -> [SPIREFederationRelationship] {
        guard !relationships.isEmpty else { return [] }

        var request = Spire_Api_Server_Trustdomain_V1_BatchUpdateFederationRelationshipRequest()
        request.federationRelationships = relationships.map(Self.federationRelationshipPayload(from:))

        // The endpoint URL and profile always move; the bundle is only masked
        // in when every input carries one, since a masked-but-absent bundle
        // would replace the peer bundle SPIRE holds with an empty one.
        var inputMask = Spire_Api_Types_FederationRelationshipMask()
        inputMask.bundleEndpointURL = true
        inputMask.bundleEndpointProfile = true
        inputMask.trustDomainBundle = relationships.allSatisfy { $0.trustDomainBundle != nil }
        request.inputMask = inputMask

        // Ask for the stored bundle back so callers can confirm what landed.
        var outputMask = Spire_Api_Types_FederationRelationshipMask()
        outputMask.bundleEndpointURL = true
        outputMask.bundleEndpointProfile = true
        outputMask.trustDomainBundle = true
        request.outputMask = outputMask

        let response: Spire_Api_Server_Trustdomain_V1_BatchUpdateFederationRelationshipResponse =
            try await unary(request, descriptor: Self.batchUpdateFederationRelationshipDescriptor)
        try Self.expectResultCount(
            response.results.count, requested: relationships.count,
            rpc: "BatchUpdateFederationRelationship")

        return try zip(relationships, response.results).map { input, result in
            guard result.status.code == RPCCode.ok else {
                throw SPIREServerAPIError.requestFailed(
                    "BatchUpdateFederationRelationship failed for \(input.trustDomain): \(result.status.code) \(result.status.message)"
                )
            }
            return Self.federationRelationship(from: result.federationRelationship)
        }
    }

    public func deleteFederationRelationships(trustDomains: [String]) async throws -> [String] {
        guard !trustDomains.isEmpty else { return [] }

        var request = Spire_Api_Server_Trustdomain_V1_BatchDeleteFederationRelationshipRequest()
        request.trustDomains = trustDomains

        let response: Spire_Api_Server_Trustdomain_V1_BatchDeleteFederationRelationshipResponse =
            try await unary(request, descriptor: Self.batchDeleteFederationRelationshipDescriptor)
        try Self.expectResultCount(
            response.results.count, requested: trustDomains.count,
            rpc: "BatchDeleteFederationRelationship")

        var deleted: [String] = []
        for (trustDomain, result) in zip(trustDomains, response.results) {
            switch result.status.code {
            case RPCCode.ok:
                deleted.append(trustDomain)
            case RPCCode.notFound:
                // Already gone: teardown replays without failing.
                continue
            default:
                throw SPIREServerAPIError.requestFailed(
                    "BatchDeleteFederationRelationship failed for \(trustDomain): \(result.status.code) \(result.status.message)"
                )
            }
        }
        return deleted
    }

    // MARK: Read-model mapping

    /// SPIRE's batch RPCs return one result per request item, in order. A
    /// short result list would silently drop items from the zip below, so the
    /// pairing is checked rather than assumed.
    private static func expectResultCount(_ count: Int, requested: Int, rpc: String) throws {
        guard count == requested else {
            throw SPIREServerAPIError.requestFailed(
                "\(rpc) returned \(count) results for \(requested) requested items")
        }
    }

    private static func date(fromEpochSeconds seconds: Int64) -> Date? {
        seconds > 0 ? Date(timeIntervalSince1970: TimeInterval(seconds)) : nil
    }

    /// Reassemble `spiffe://<trust-domain>/<path>` from the API's structured form.
    static func spiffeIDString(from payload: Spire_Api_Types_SPIFFEID) -> String {
        "spiffe://\(payload.trustDomain)\(payload.path)"
    }

    private static func entry(from proto: Spire_Api_Types_Entry) -> SPIREEntry {
        SPIREEntry(
            id: proto.id,
            spiffeID: spiffeIDString(from: proto.spiffeID),
            parentID: spiffeIDString(from: proto.parentID),
            selectors: proto.selectors.map { SPIRESelector(type: $0.type, value: $0.value) },
            x509SVIDTTLSeconds: proto.x509SvidTtl,
            jwtSVIDTTLSeconds: proto.jwtSvidTtl,
            federatesWith: proto.federatesWith,
            admin: proto.admin,
            downstream: proto.downstream,
            hint: proto.hint,
            expiresAt: date(fromEpochSeconds: proto.expiresAt),
            createdAt: date(fromEpochSeconds: proto.createdAt)
        )
    }

    private static func federationRelationship(
        from proto: Spire_Api_Types_FederationRelationship
    ) -> SPIREFederationRelationship {
        let profile: String
        var endpointSPIFFEID: String?
        switch proto.bundleEndpointProfile {
        case .httpsSpiffe(let spiffe):
            profile = "https_spiffe"
            endpointSPIFFEID = spiffe.endpointSpiffeID.isEmpty ? nil : spiffe.endpointSpiffeID
        case .httpsWeb:
            profile = "https_web"
        case nil:
            profile = "unknown"
        }

        // `trust_domain_bundle` is only populated once SPIRE holds a bundle for
        // the peer; treat its absence as "no authorities" so callers read it as
        // not-yet-synced rather than crashing on the default-empty message.
        let x509Count = proto.hasTrustDomainBundle ? proto.trustDomainBundle.x509Authorities.count : 0
        let jwtCount = proto.hasTrustDomainBundle ? proto.trustDomainBundle.jwtAuthorities.count : 0
        let sequence = proto.hasTrustDomainBundle ? proto.trustDomainBundle.sequenceNumber : 0

        return SPIREFederationRelationship(
            trustDomain: proto.trustDomain,
            bundleEndpointURL: proto.bundleEndpointURL,
            bundleEndpointProfile: profile,
            endpointSPIFFEID: endpointSPIFFEID,
            bundleX509AuthorityCount: x509Count,
            bundleJWTAuthorityCount: jwtCount,
            bundleSequenceNumber: sequence
        )
    }

    static func bundle(from proto: Spire_Api_Types_Bundle) -> SPIREBundle {
        SPIREBundle(
            trustDomain: proto.trustDomain,
            x509Authorities: proto.x509Authorities.map {
                SPIREX509Authority(der: $0.asn1, tainted: $0.tainted)
            },
            jwtAuthorities: proto.jwtAuthorities.map {
                SPIREJWTAuthority(
                    keyID: $0.keyID,
                    publicKey: $0.publicKey,
                    expiresAt: date(fromEpochSeconds: $0.expiresAt),
                    tainted: $0.tainted
                )
            },
            refreshHintSeconds: proto.refreshHint,
            sequenceNumber: proto.sequenceNumber
        )
    }

    static func bundlePayload(from bundle: SPIREBundle) -> Spire_Api_Types_Bundle {
        var proto = Spire_Api_Types_Bundle()
        proto.trustDomain = bundle.trustDomain
        proto.x509Authorities = bundle.x509Authorities.map { authority in
            var payload = Spire_Api_Types_X509Certificate()
            payload.asn1 = authority.der
            payload.tainted = authority.tainted
            return payload
        }
        proto.jwtAuthorities = bundle.jwtAuthorities.map { authority in
            var payload = Spire_Api_Types_JWTKey()
            payload.keyID = authority.keyID
            payload.publicKey = authority.publicKey
            payload.expiresAt = Int64(authority.expiresAt?.timeIntervalSince1970 ?? 0)
            payload.tainted = authority.tainted
            return payload
        }
        proto.refreshHint = bundle.refreshHintSeconds
        proto.sequenceNumber = bundle.sequenceNumber
        return proto
    }

    static func federationRelationshipPayload(
        from input: SPIREFederationRelationshipInput
    ) -> Spire_Api_Types_FederationRelationship {
        var proto = Spire_Api_Types_FederationRelationship()
        proto.trustDomain = input.trustDomain
        proto.bundleEndpointURL = input.bundleEndpointURL
        switch input.bundleEndpointProfile {
        case .httpsWeb:
            proto.httpsWeb = Spire_Api_Types_HTTPSWebProfile()
        case .httpsSPIFFE(let endpointSPIFFEID):
            var profile = Spire_Api_Types_HTTPSSPIFFEProfile()
            profile.endpointSpiffeID = endpointSPIFFEID
            proto.httpsSpiffe = profile
        }
        if let bundle = input.trustDomainBundle {
            proto.trustDomainBundle = bundlePayload(from: bundle)
        }
        return proto
    }

    private static func selectorPayload(_ selector: SPIRESelector) -> Spire_Api_Types_Selector {
        var payload = Spire_Api_Types_Selector()
        payload.type = selector.type
        payload.value = selector.value
        return payload
    }

    private static func agent(from proto: Spire_Api_Types_Agent) -> SPIREAgent {
        SPIREAgent(
            spiffeID: spiffeIDString(from: proto.id),
            attestationType: proto.attestationType,
            x509SVIDSerialNumber: proto.x509SvidSerialNumber,
            x509SVIDExpiresAt: date(fromEpochSeconds: proto.x509SvidExpiresAt),
            selectors: proto.selectors.map { SPIRESelector(type: $0.type, value: $0.value) },
            banned: proto.banned,
            canReattest: proto.canReattest,
            agentVersion: proto.agentVersion
        )
    }

    // MARK: Transport

    private func unary<Request: SwiftProtobuf.Message, Response: SwiftProtobuf.Message>(
        _ request: Request,
        descriptor: MethodDescriptor
    ) async throws -> Response {
        let transport: HTTP2ClientTransport.Posix
        do {
            switch address {
            case .unixSocket(let path):
                guard FileManager.default.fileExists(atPath: path) else {
                    throw SPIREServerAPIError.unreachable("SPIRE server API socket not found: \(path)")
                }
                // The admin Unix socket is always plaintext; callers on it are
                // implicitly admin, so an mTLS configuration is ignored here.
                transport = try HTTP2ClientTransport.Posix(
                    target: .unixDomainSocket(path: path),
                    transportSecurity: .plaintext
                )
            case .tcp(let host, let port):
                transport = try HTTP2ClientTransport.Posix(
                    target: .dns(host: host, port: port),
                    transportSecurity: try await tcpTransportSecurity()
                )
            }
        } catch let error as SPIREServerAPIError {
            throw error
        } catch {
            throw SPIREServerAPIError.unreachable("Failed to create SPIRE server API transport: \(error)")
        }

        var options = CallOptions.defaults
        options.timeout = timeout

        do {
            return try await withGRPCClient(transport: transport) { client in
                try await client.unary(
                    request: ClientRequest(message: request),
                    descriptor: descriptor,
                    serializer: ProtobufSerializer<Request>(),
                    deserializer: ProtobufDeserializer<Response>(),
                    options: options
                ) { response in
                    try response.message
                }
            }
        } catch let error as SPIREServerAPIError {
            throw error
        } catch let error as RPCError {
            switch error.code {
            case .unavailable, .deadlineExceeded:
                throw SPIREServerAPIError.unreachable("\(descriptor.method): \(error.message)")
            case .notFound:
                throw SPIREServerAPIError.notFound("\(descriptor.method): \(error.message)")
            case .invalidArgument:
                throw SPIREServerAPIError.invalidArgument("\(descriptor.method): \(error.message)")
            default:
                throw SPIREServerAPIError.requestFailed("\(descriptor.method): \(error.code) \(error.message)")
            }
        } catch {
            throw SPIREServerAPIError.unreachable("\(descriptor.method): \(error)")
        }
    }

    /// Resolve the gRPC transport security for a TCP target from the
    /// configured mode: plaintext for the loopback-bridge path, or mTLS with
    /// the current SVID from the identity provider. Fetching the identity per
    /// call matches the per-call connection scope and picks up rotated SVIDs
    /// without extra machinery (the provider caches between rotations).
    private func tcpTransportSecurity() async throws -> HTTP2ClientTransport.Posix.TransportSecurity {
        switch transportSecurity {
        case .plaintext:
            return .plaintext
        case .mtls(let identityProvider, let peer):
            let identity = try await identityProvider.currentIdentity()

            // SPIRE server TLS certificates carry a SPIFFE URI SAN, not the
            // Service DNS name, so hostname verification cannot apply. And
            // chaining to the trust domain's CA alone is not enough either:
            // every workload in the domain holds a bundle-signed SVID, so a
            // DNS/Service-routing compromise could put one of them in front
            // of the admin connection. Pin the server's well-known SPIFFE ID
            // (spiffe://<td>/spire/server — fixed in SPIRE, not configurable)
            // via a verification callback that chain-verifies against the
            // bundle and then requires that exact URI SAN on the leaf.
            //
            // For a peer in another trust domain both halves come from `peer`:
            // that domain's server ID, verified against that domain's roots.
            // The client certificate stays our own SVID — federation is what
            // makes the peer server accept it.
            let expectedServerID =
                try peer.expectedServerSPIFFEID
                ?? Self.spireServerSPIFFEID(fromMemberID: identity.spiffeID)
            let rootsPEM = peer.trustRootsPEM ?? identity.trustBundlePEM
            let roots: [Certificate]
            do {
                roots = try rootsPEM.map { try Certificate(pemEncoded: $0) }
            } catch {
                throw SPIREServerAPIError.workloadIdentityUnavailable(
                    "Failed to parse trust bundle certificate: \(error)")
            }
            let logger = self.logger

            return .tls(
                .mTLS(
                    certificateChain: identity.certificateChainPEM.map {
                        .bytes(Array($0.utf8), format: .pem)
                    },
                    privateKey: .bytes(Array(identity.privateKeyPEM.utf8), format: .pem)
                ) { config in
                    config.trustRoots = .certificates(
                        rootsPEM.map { .bytes(Array($0.utf8), format: .pem) })
                    config.serverCertificateVerification = .noHostnameVerification
                    config.customVerificationCallback = { presented, promise in
                        Self.verifySPIREServerChain(
                            presented, roots: roots, expectedSPIFFEID: expectedServerID,
                            logger: logger, promise: promise)
                    }
                })
        }
    }

    /// The SPIRE server's own SPIFFE ID in the trust domain of `memberID`
    /// (any identity issued in that domain, e.g. the control plane's SVID).
    static func spireServerSPIFFEID(fromMemberID memberID: String) throws -> String {
        let payload = try spiffeIDPayload(memberID)
        return "spiffe://\(payload.trustDomain)/spire/server"
    }

    /// Replacement server-certificate verification for the mTLS admin path:
    /// chain-verify the presented certificates against the trust bundle and
    /// require the leaf to carry exactly the pinned SPIRE server SPIFFE ID as
    /// a URI SAN. The chain walk + URI SAN check live in the shared
    /// `SPIFFEPeerVerifier` (the agent pins the control plane's identity the
    /// same way — issue #552).
    static func verifySPIREServerChain(
        _ presented: [NIOSSLCertificate],
        roots: [Certificate],
        expectedSPIFFEID: String,
        logger: Logger,
        promise: EventLoopPromise<NIOSSLVerificationResultWithMetadata>
    ) {
        SPIFFEPeerVerifier.verifyPeerChain(
            presented,
            roots: roots,
            expectedSPIFFEID: expectedSPIFFEID,
            peerDescription: "SPIRE server",
            logger: logger,
            promise: promise
        )
    }

    /// Split `spiffe://<trust-domain>/<path>` into the API's structured form.
    static func spiffeIDPayload(_ id: String) throws -> Spire_Api_Types_SPIFFEID {
        guard id.hasPrefix("spiffe://") else {
            throw SPIREServerAPIError.invalidSPIFFEID(id)
        }
        let withoutScheme = id.dropFirst("spiffe://".count)
        guard let slash = withoutScheme.firstIndex(of: "/"), slash != withoutScheme.startIndex else {
            throw SPIREServerAPIError.invalidSPIFFEID(id)
        }

        var payload = Spire_Api_Types_SPIFFEID()
        payload.trustDomain = String(withoutScheme[..<slash])
        payload.path = String(withoutScheme[slash...])
        return payload
    }
}
