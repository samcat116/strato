import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import GRPCProtobuf
import Logging
import X509

// MARK: - Selector

/// One SPIRE selector, in its canonical `type:value` form.
///
/// SPIRE splits a selector string on the **first** colon only — a value may
/// itself contain colons (`unix:path:/usr/bin/env`, `k8s:pod-label:app:web`) —
/// so this type parses the same way `api.SelectorsFromProto` does on the SPIRE
/// side. Getting it wrong here would silently produce a selector that matches
/// nothing.
public struct DelegatedSelector: Sendable, Equatable, Hashable, CustomStringConvertible {
    /// The selector type. For guest identities this is Strato's own synthetic
    /// `strato` type: the Delegated Identity API places no restriction on the
    /// type being a known attestor plugin name, because the delegate — not a
    /// plugin — is what vouched for the workload.
    public let type: String

    /// The selector value. May contain colons.
    public let value: String

    public var description: String { "\(type):\(value)" }

    public init(type: String, value: String) {
        self.type = type
        self.value = value
    }

    /// Parse `type:value`. Returns nil when there is no colon, or when either
    /// side of it is empty — SPIRE would reject such a selector anyway, and
    /// failing at the CLI boundary names the bad argument.
    public init?(_ text: String) {
        guard let separator = text.firstIndex(of: ":") else { return nil }
        let type = String(text[..<separator])
        let value = String(text[text.index(after: separator)...])
        guard !type.isEmpty, !value.isEmpty else { return nil }
        self.type = type
        self.value = value
    }
}

// MARK: - Delegated SVID

/// An X.509 SVID obtained on **another** workload's behalf through the SPIRE
/// agent's Delegated Identity API.
///
/// Deliberately not `X509SVID`: that type carries a non-optional `trustBundle`,
/// and the delegated stream does not deliver one. Trust roots arrive on the
/// separate `SubscribeToX509Bundles` stream, so the two must be joined by the
/// caller — `withBundles(_:)` is that join.
public struct DelegatedX509SVID: Sendable, Equatable {
    /// The SPIFFE ID of the workload this SVID was minted for — not this
    /// process's own identity.
    public let spiffeID: SPIFFEIdentity

    /// The certificate chain, leaf first, PEM-encoded.
    public let certificateChain: [String]

    /// The private key SPIRE minted alongside the certificate, PEM-encoded
    /// PKCS#8.
    public let privateKey: String

    /// Bare names of the trust domains this SVID's registration entry federates
    /// with. Unlike the Workload API, the delegated stream sends names only —
    /// the roots themselves must be looked up in the bundle stream.
    public let federatesWith: [String]

    /// Expiry, read from the leaf certificate.
    public let expiresAt: Date

    /// Operator-supplied hint from the registration entry, when set.
    public let hint: String?

    public init(
        spiffeID: SPIFFEIdentity,
        certificateChain: [String],
        privateKey: String,
        federatesWith: [String] = [],
        expiresAt: Date,
        hint: String? = nil
    ) {
        self.spiffeID = spiffeID
        self.certificateChain = certificateChain
        self.privateKey = privateKey
        self.federatesWith = federatesWith
        self.expiresAt = expiresAt
        self.hint = hint
    }

    /// Compose this SVID with a bundle set from `SubscribeToX509Bundles` into
    /// the module's ordinary `X509SVID`.
    ///
    /// `bundles` is keyed by bare trust domain name, as the delegated bundle
    /// stream delivers it. Only the domains named in `federatesWith` are
    /// carried over as federated roots: handing an SVID the full set the node
    /// happens to know about would let any federated domain's CA vouch for a
    /// peer in any other, which is exactly what `X509SVID.roots(forTrustDomain:)`
    /// exists to prevent.
    public func withBundles(_ bundles: [String: SPIFFETrustBundle]) throws -> X509SVID {
        guard let own = bundles[spiffeID.trustDomain] else {
            throw SPIFFEError.trustBundleUnavailable
        }
        var federated: [String: [String]] = [:]
        for domain in federatesWith {
            if let bundle = bundles[domain] {
                federated[domain] = bundle.x509Authorities
            }
        }
        return X509SVID(
            spiffeID: spiffeID,
            certificateChain: certificateChain,
            privateKey: privateKey,
            trustBundle: own.x509Authorities,
            federatedBundles: federated,
            expiresAt: expiresAt,
            hint: hint
        )
    }
}

// MARK: - Delegated Identity client

/// Client for the SPIRE agent's **Delegated Identity API** — the admin-socket
/// RPC that lets an authorized delegate obtain SVIDs minted for workloads the
/// agent cannot attest directly.
///
/// This is the node-side half of guest identity (see
/// `docs/architecture/guest-identity.md`): a guest VM or sandbox is not a host
/// process, so no workload attestor can see it. Instead the control plane
/// registers an entry parented to this node with a synthetic
/// `strato:instance:<uuid>` selector, and strato-agent — listed in the SPIRE
/// agent's `authorized_delegates` — subscribes with exactly that selector.
///
/// Deliberately **not** a `SPIFFEClientProtocol` conformance: that protocol
/// models "my own identity" and its callers (`SVIDManager`, the WebSocket TLS
/// path) mean this process. Conflating the two would let a caller reach for a
/// guest's key where it wanted the agent's.
///
/// > Important: a SPIRE delegate is unconstrained — it may subscribe with any
/// > selectors and receives any SVID cached on this node. That cache holds only
/// > entries parented to this node, so the reach is exactly "the guests running
/// > here", which strato-agent already has by virtue of running them.
public actor DelegatedIdentitySPIFFEClient {
    private let socketPath: String
    private let logger: Logger

    /// Delay between reconnection attempts when a watch stream fails or ends.
    private let watchRetryDelay: Duration

    /// Default admin socket path.
    ///
    /// Note this is **not** under `/var/run/spire/sockets/`, where the Workload
    /// API socket lives: spire-agent refuses to bind an admin socket in (or
    /// under) the directory holding the Workload API socket. Moving this path
    /// into `sockets/` to "tidy up" makes the agent fail to start.
    public static let defaultAdminSocketPath = "/var/run/spire/admin.sock"

    /// The environment variable SPIRE's own tooling uses for this socket.
    public static let socketEnvironmentVariable = "SPIRE_ADMIN_ENDPOINT_SOCKET"

    /// Unlike the Workload API, the Delegated Identity API carries **no**
    /// `workload.spiffe.io` metadata: the SPIRE agent's `verifySecurityHeader`
    /// middleware only enforces that header for methods prefixed
    /// `/SpiffeWorkloadAPI/`.
    private static let subscribeToX509SVIDsDescriptor = MethodDescriptor(
        service: ServiceDescriptor(
            fullyQualifiedService: "spire.api.agent.delegatedidentity.v1.DelegatedIdentity"),
        method: "SubscribeToX509SVIDs"
    )

    private static let subscribeToX509BundlesDescriptor = MethodDescriptor(
        service: ServiceDescriptor(
            fullyQualifiedService: "spire.api.agent.delegatedidentity.v1.DelegatedIdentity"),
        method: "SubscribeToX509Bundles"
    )

    /// - Parameters:
    ///   - socketPath: the SPIRE agent's `admin_socket_path`
    ///   - logger: logger instance
    ///   - watchRetryDelay: delay before re-dialing after a broken watch stream
    public init(
        socketPath: String = defaultAdminSocketPath,
        logger: Logger,
        watchRetryDelay: Duration = .seconds(5)
    ) {
        self.socketPath = socketPath
        self.logger = logger
        self.watchRetryDelay = watchRetryDelay
    }

    /// Resolve the admin socket path from an explicit override, then
    /// `$SPIRE_ADMIN_ENDPOINT_SOCKET`, then the default.
    public static func resolveSocketPath(
        override: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let override, !override.isEmpty { return override }
        if let fromEnvironment = environment[socketEnvironmentVariable], !fromEnvironment.isEmpty {
            return fromEnvironment
        }
        return defaultAdminSocketPath
    }

    /// The socket this client dials.
    public var adminSocketPath: String { socketPath }

    /// The first SVID set SPIRE pushes for `selectors`, after which the stream
    /// is dropped.
    ///
    /// An empty set is returned as `[]`, not an error: "no registration entry
    /// with these selectors has reached this node" is a normal, meaningful
    /// answer from this API, and it is also how revocation is signalled.
    ///
    /// > Warning: SPIRE matches an entry when the entry's selectors are a
    /// > **subset** of the requested set, so requesting more selectors matches
    /// > more entries. Pass a guest's exact selector set — never a superset.
    public func fetchX509SVIDs(selectors: [DelegatedSelector]) async throws -> [DelegatedX509SVID] {
        logger.debug(
            "Fetching delegated X.509 SVIDs",
            metadata: [
                "socketPath": .string(socketPath),
                "selectors": .string(selectors.map(\.description).joined(separator: " ")),
            ])

        let svids = try await withDelegatedIdentityClient { client in
            try await client.serverStreaming(
                request: ClientRequest(message: Self.subscribeRequest(selectors: selectors)),
                descriptor: Self.subscribeToX509SVIDsDescriptor,
                serializer: ProtobufSerializer<
                    Spire_Api_Agent_Delegatedidentity_V1_SubscribeToX509SVIDsRequest
                >(),
                deserializer: ProtobufDeserializer<
                    Spire_Api_Agent_Delegatedidentity_V1_SubscribeToX509SVIDsResponse
                >(),
                options: .defaults
            ) { response in
                // A long-lived subscription whose first message carries the
                // current set. Convert it and drop the stream.
                for try await message in response.messages {
                    return try DelegatedIdentityConversion.makeSVIDs(from: message)
                }
                throw SPIFFEError.workloadAPIUnavailable(
                    "Delegated Identity stream ended without delivering a response")
            }
        }

        logger.info(
            "Fetched delegated X.509 SVIDs",
            metadata: [
                "count": .string("\(svids.count)"),
                "spiffeIDs": .string(svids.map(\.spiffeID.uri).joined(separator: " ")),
            ])

        return svids
    }

    /// Every update SPIRE pushes for `selectors`, for as long as the consumer
    /// keeps the stream.
    ///
    /// Includes revocation: deleting the registration entry makes SPIRE push an
    /// **empty** set, which arrives here as `[]` rather than as the stream
    /// ending. A consumer must treat that as "tear this identity down now"
    /// instead of waiting for the SVID's TTL to run out.
    nonisolated public func watchX509SVIDs(
        selectors: [DelegatedSelector]
    ) -> AsyncStream<[DelegatedX509SVID]> {
        AsyncStream { continuation in
            let task = Task {
                await self.runWatch(selectors: selectors, continuation: continuation)
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// The local and federated X.509 authorities this node is tracking, keyed
    /// by **bare** trust domain name (`strato.local`) — see
    /// `DelegatedIdentityConversion.makeTrustBundles` for why the wire keys are
    /// normalized rather than passed through.
    public func fetchTrustBundles() async throws -> [String: SPIFFETrustBundle] {
        try await withDelegatedIdentityClient { client in
            try await client.serverStreaming(
                request: ClientRequest(
                    message: Spire_Api_Agent_Delegatedidentity_V1_SubscribeToX509BundlesRequest()),
                descriptor: Self.subscribeToX509BundlesDescriptor,
                serializer: ProtobufSerializer<
                    Spire_Api_Agent_Delegatedidentity_V1_SubscribeToX509BundlesRequest
                >(),
                deserializer: ProtobufDeserializer<
                    Spire_Api_Agent_Delegatedidentity_V1_SubscribeToX509BundlesResponse
                >(),
                options: .defaults
            ) { response in
                for try await message in response.messages {
                    return try DelegatedIdentityConversion.makeTrustBundles(from: message)
                }
                throw SPIFFEError.trustBundleUnavailable
            }
        }
    }

    public func close() async {
        // Fetches and watches use per-call scoped connections torn down when
        // their task ends, so there is no persistent state to release.
        logger.info("Delegated Identity client closed")
    }

    // MARK: - Private

    private static func subscribeRequest(
        selectors: [DelegatedSelector]
    ) -> Spire_Api_Agent_Delegatedidentity_V1_SubscribeToX509SVIDsRequest {
        var request = Spire_Api_Agent_Delegatedidentity_V1_SubscribeToX509SVIDsRequest()
        request.selectors = selectors.map { selector in
            var proto = Spire_Api_Types_Selector()
            proto.type = selector.type
            proto.value = selector.value
            return proto
        }
        // `pid` is left at zero: the proto documents `selectors` and `pid` as
        // mutually exclusive (they are two plain fields rather than a `oneof`
        // only because `repeated` cannot live in a `oneof` without a wrapper
        // message), and SPIRE's handler rejects a request that sets both.
        return request
    }

    private func runWatch(
        selectors: [DelegatedSelector],
        continuation: AsyncStream<[DelegatedX509SVID]>.Continuation
    ) async {
        while !Task.isCancelled {
            do {
                try await withDelegatedIdentityClient { client in
                    try await client.serverStreaming(
                        request: ClientRequest(message: Self.subscribeRequest(selectors: selectors)),
                        descriptor: Self.subscribeToX509SVIDsDescriptor,
                        serializer: ProtobufSerializer<
                            Spire_Api_Agent_Delegatedidentity_V1_SubscribeToX509SVIDsRequest
                        >(),
                        deserializer: ProtobufDeserializer<
                            Spire_Api_Agent_Delegatedidentity_V1_SubscribeToX509SVIDsResponse
                        >(),
                        options: .defaults
                    ) { response in
                        for try await message in response.messages {
                            let svids = try DelegatedIdentityConversion.makeSVIDs(from: message)
                            self.logger.info(
                                "Received delegated SVID update",
                                metadata: [
                                    "count": .string("\(svids.count)"),
                                    "spiffeIDs": .string(
                                        svids.map(\.spiffeID.uri).joined(separator: " ")),
                                ])
                            continuation.yield(svids)
                        }
                    }
                }
                logger.warning("Delegated Identity stream ended; reconnecting")
            } catch let error as SPIFFEError {
                // A refused delegate will be refused again on every re-dial.
                // Surfacing it once and stopping beats a silent retry loop that
                // looks like "no entry matched" to whoever is watching.
                if case .delegateNotAuthorized = error {
                    logger.error("Delegated Identity stream refused: \(error.localizedDescription)")
                    break
                }
                if !Task.isCancelled {
                    logger.error("Error watching Delegated Identity stream: \(error)")
                }
            } catch {
                if !Task.isCancelled {
                    logger.error("Error watching Delegated Identity stream: \(error)")
                }
            }

            do {
                try await Task.sleep(for: watchRetryDelay)
            } catch {
                break  // cancelled
            }
        }
        continuation.finish()
    }

    private func withDelegatedIdentityClient<Result: Sendable>(
        _ body: @Sendable @escaping (GRPCClient<HTTP2ClientTransport.Posix>) async throws -> Result
    ) async throws -> Result {
        do {
            return try await SPIFFEUnixGRPC.withClient(socketPath: socketPath, body)
        } catch let error as RPCError {
            throw Self.mapRPCError(error)
        }
    }

    static func mapRPCError(_ error: RPCError) -> SPIFFEError {
        switch error.code {
        case .permissionDenied:
            return .delegateNotAuthorized(error.message)
        case .unavailable, .deadlineExceeded:
            return .workloadAPIUnavailable("\(error.code): \(error.message)")
        default:
            return .connectionFailed("\(error.code): \(error.message)")
        }
    }
}

// MARK: - Proto -> SPIFFE type conversion

/// Conversion from Delegated Identity protobuf messages to this module's SPIFFE
/// types.
///
/// The response shapes differ from the Workload API's in four ways, and every
/// one of them silently corrupts the output if the Workload API's conversion is
/// copied across:
///
/// 1. `cert_chain` is `repeated bytes` — already split, so it must **not** go
///    through `splitConcatenatedDER`.
/// 2. The SPIFFE ID is a `{trust_domain, path}` message, not a URI string.
/// 3. There is no inline trust bundle; roots come from the separate bundle
///    stream.
/// 4. `ca_certificates` keys need normalizing — see `makeTrustBundles`.
enum DelegatedIdentityConversion {
    static func makeSVIDs(
        from response: Spire_Api_Agent_Delegatedidentity_V1_SubscribeToX509SVIDsResponse
    ) throws -> [DelegatedX509SVID] {
        // `federates_with` lives on the response, not on each SVID, matching
        // how the Workload API reports federated bundles once per response.
        let federatesWith = response.federatesWith

        return try response.x509Svids.map { entry in
            let proto = entry.x509Svid

            guard !proto.id.trustDomain.isEmpty else {
                throw SPIFFEError.invalidSPIFFEID("delegated SVID carries an empty trust domain")
            }
            let spiffeID = SPIFFEIdentity(trustDomain: proto.id.trustDomain, path: proto.id.path)

            guard let leafDER = proto.certChain.first else {
                throw SPIFFEError.parseError("Delegated SVID contains no certificates")
            }

            // The leaf determines the SVID's lifetime, and thus rotation
            // timing. `expires_at` on the message should agree; the
            // certificate is the authority if they ever diverge.
            let leaf: Certificate
            do {
                leaf = try Certificate(derEncoded: Array(leafDER))
            } catch {
                throw SPIFFEError.parseError(
                    "Failed to parse delegated SVID leaf certificate: \(error)")
            }

            return DelegatedX509SVID(
                spiffeID: spiffeID,
                certificateChain: proto.certChain.map {
                    WorkloadAPIConversion.pemEncode(der: $0, label: "CERTIFICATE")
                },
                privateKey: WorkloadAPIConversion.pemEncode(
                    der: entry.x509SvidKey, label: "PRIVATE KEY"),
                federatesWith: federatesWith,
                expiresAt: leaf.notValidAfter,
                hint: proto.hint.isEmpty ? nil : proto.hint
            )
        }
    }

    /// Trust bundles keyed by **bare** trust domain name (`strato.local`), so a
    /// lookup can be keyed off a parsed `SPIFFEIdentity.trustDomain`.
    ///
    /// The keys need normalizing to get there. `delegatedidentity.proto`
    /// documents `ca_certificates` as "a map keyed by trust domain name", but
    /// SPIRE 1.9.6 actually writes `caCerts[td.IDString()]` — the trust domain's
    /// SPIFFE ID (`spiffe://strato.local`). Taking the proto comment at its word
    /// produced a map whose keys nothing could look up, which is how this was
    /// found. Both forms are accepted so a future SPIRE that honours its own
    /// comment does not break this.
    static func makeTrustBundles(
        from response: Spire_Api_Agent_Delegatedidentity_V1_SubscribeToX509BundlesResponse
    ) throws -> [String: SPIFFETrustBundle] {
        var bundles: [String: SPIFFETrustBundle] = [:]
        for (key, der) in response.caCertificates {
            let trustDomain = SPIFFEIdentity(uri: key)?.trustDomain ?? key
            // Unlike the SVID chain, this value *is* a concatenation of DER
            // certificates, so it does need splitting.
            let authorities = try WorkloadAPIConversion.splitConcatenatedDER(Array(der))
                .map { WorkloadAPIConversion.pemEncode(der: Data($0), label: "CERTIFICATE") }
            bundles[trustDomain] = SPIFFETrustBundle(
                trustDomain: trustDomain,
                x509Authorities: authorities
            )
        }
        return bundles
    }
}
