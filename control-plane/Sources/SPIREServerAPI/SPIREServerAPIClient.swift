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

public enum SPIREServerAPIError: Error, LocalizedError {
    case invalidAddress(String)
    case unreachable(String)
    case requestFailed(String)
    case invalidSPIFFEID(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAddress(let details):
            return "Invalid SPIRE server API address: \(details)"
        case .unreachable(let details):
            return "SPIRE server unreachable: \(details)"
        case .requestFailed(let details):
            return "SPIRE server request failed: \(details)"
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
        var listRequest = Spire_Api_Server_Entry_V1_ListEntriesRequest()
        listRequest.filter.bySpiffeID = try Self.spiffeIDPayload(spiffeID)

        let listResponse: Spire_Api_Server_Entry_V1_ListEntriesResponse = try await unary(
            listRequest, descriptor: Self.listEntriesDescriptor)

        let entryIDs = listResponse.entries.map(\.id)
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
