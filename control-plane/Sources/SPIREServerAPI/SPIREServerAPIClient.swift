import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import GRPCProtobuf
import Logging
import SwiftProtobuf

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
    func createEntry(
        spiffeID: String,
        parentID: String,
        selectors: [SPIRESelector],
        x509SVIDTTLSeconds: Int32
    ) async throws -> SPIREEntryCreationResult

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

public enum SPIREServerAPIError: Error, LocalizedError {
    case invalidAddress(String)
    case unreachable(String)
    case requestFailed(String)
    case notFound(String)
    case invalidArgument(String)
    case invalidSPIFFEID(String)

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
        }
    }
}

// MARK: - Address

/// Where to reach the SPIRE server's registration API.
///
/// SPIRE serves this API as gRPC on a local Unix socket (callers on that
/// socket are implicitly admin). The canonical deployment shares the socket
/// directory with the control plane container (`unix:///run/spire/server/
/// api.sock`). For local development on macOS — where a Unix socket cannot
/// cross the Docker VM boundary — a loopback TCP bridge (socat) in front of
/// the socket is supported via plain `host:port`. TCP carries no
/// authentication, so it must never be exposed beyond loopback.
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

// MARK: - gRPC client

/// gRPC client for the SPIRE Server registration API using manual method
/// descriptors (see Generated/README.md — no gRPC codegen plugin required).
/// Connections are scoped per call: registration-token minting is a rare,
/// admin-driven operation, so holding a connection open buys nothing.
public struct SPIREServerAPIClient: SPIREServerAPI {
    private let address: SPIREServerAPIAddress
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

    /// google.rpc.Code values SPIRE reports in per-entry batch results.
    private enum RPCCode {
        static let ok: Int32 = 0
        static let alreadyExists: Int32 = 6
    }

    public init(address: SPIREServerAPIAddress, logger: Logger, timeout: Duration = .seconds(10)) {
        self.address = address
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
        x509SVIDTTLSeconds: Int32
    ) async throws -> SPIREEntryCreationResult {
        var entry = Spire_Api_Types_Entry()
        entry.spiffeID = try Self.spiffeIDPayload(spiffeID)
        entry.parentID = try Self.spiffeIDPayload(parentID)
        entry.selectors = selectors.map { selector in
            var payload = Spire_Api_Types_Selector()
            payload.type = selector.type
            payload.value = selector.value
            return payload
        }
        entry.x509SvidTtl = x509SVIDTTLSeconds

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

    // MARK: Read-model mapping

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
                transport = try HTTP2ClientTransport.Posix(
                    target: .unixDomainSocket(path: path),
                    transportSecurity: .plaintext
                )
            case .tcp(let host, let port):
                transport = try HTTP2ClientTransport.Posix(
                    target: .dns(host: host, port: port),
                    transportSecurity: .plaintext
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
