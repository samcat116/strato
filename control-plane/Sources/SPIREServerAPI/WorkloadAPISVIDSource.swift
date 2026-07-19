import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import GRPCProtobuf
import Logging
import SwiftProtobuf
import X509

// MARK: - Client identity

/// The control plane's own SPIFFE identity materials, used as the client
/// certificate when dialing the SPIRE server's TCP endpoint with mTLS.
public struct SPIREClientIdentity: Sendable {
    public let spiffeID: String
    /// Leaf-first X.509 certificate chain, PEM-encoded.
    public let certificateChainPEM: [String]
    /// PKCS#8 private key for the leaf certificate, PEM-encoded.
    public let privateKeyPEM: String
    /// The trust domain's X.509 authorities, PEM-encoded. Used both to verify
    /// the SPIRE server's TLS certificate and (server-side) to verify ours.
    public let trustBundlePEM: [String]
    /// When the leaf certificate expires.
    public let expiresAt: Date

    public init(
        spiffeID: String,
        certificateChainPEM: [String],
        privateKeyPEM: String,
        trustBundlePEM: [String],
        expiresAt: Date
    ) {
        self.spiffeID = spiffeID
        self.certificateChainPEM = certificateChainPEM
        self.privateKeyPEM = privateKeyPEM
        self.trustBundlePEM = trustBundlePEM
        self.expiresAt = expiresAt
    }
}

/// Supplies the current client identity for the mTLS admin path. A protocol
/// so tests can substitute a fixed identity for the Workload API socket.
public protocol SPIREClientIdentityProvider: Sendable {
    func currentIdentity() async throws -> SPIREClientIdentity
}

// MARK: - Workload API SVID source

/// Fetches the control plane's X.509 SVID and trust bundle from the SPIFFE
/// Workload API (gRPC over a Unix domain socket to a local SPIRE agent) and
/// caches it until half its remaining lifetime has elapsed, so rare admin
/// calls reuse a fresh-enough SVID without a persistent watch stream.
///
/// When a refresh fails but the cached SVID is still within its validity
/// window, the cached identity is served (the Workload API may be briefly
/// unavailable during agent restarts); once the SVID has expired, errors
/// propagate.
public actor WorkloadAPISVIDSource: SPIREClientIdentityProvider {
    private let socketPath: String
    private let logger: Logger

    /// Deadline for one `FetchX509SVID` fetch. Bounds the wait for the first
    /// stream message, so an agent that accepts the socket connection but
    /// stalls fails the fetch (and lets a still-valid cached SVID take over)
    /// instead of hanging the admin call indefinitely.
    private let fetchTimeout: Duration

    private var cached: (identity: SPIREClientIdentity, refreshAfter: Date)?

    /// Every Workload API call must carry this metadata per the SPIFFE spec;
    /// servers reject calls without it.
    private static let securityMetadata: Metadata = ["workload.spiffe.io": "true"]

    private static let fetchX509SVIDDescriptor = MethodDescriptor(
        service: ServiceDescriptor(fullyQualifiedService: "SpiffeWorkloadAPI"),
        method: "FetchX509SVID"
    )

    public init(socketPath: String, logger: Logger, fetchTimeout: Duration = .seconds(10)) {
        self.socketPath = socketPath
        self.logger = logger
        self.fetchTimeout = fetchTimeout
    }

    public func currentIdentity() async throws -> SPIREClientIdentity {
        let now = Date()
        if let cached, now < cached.refreshAfter {
            return cached.identity
        }

        do {
            let identity = try await fetchSVID()
            // Refresh once half the remaining lifetime has elapsed — the same
            // rotation point SPIRE agents use — so a rotated SVID is picked up
            // long before the old one expires.
            let refreshAfter = now.addingTimeInterval(identity.expiresAt.timeIntervalSince(now) / 2)
            cached = (identity, refreshAfter)
            return identity
        } catch {
            if let cached, now < cached.identity.expiresAt {
                logger.warning(
                    "SPIFFE Workload API refresh failed; reusing cached SVID",
                    metadata: [
                        "expiresAt": .string(cached.identity.expiresAt.description),
                        "error": .string("\(error)"),
                    ])
                return cached.identity
            }
            throw error
        }
    }

    /// Fetch the current SVID set. `FetchX509SVID` is a long-lived stream
    /// whose first message carries the current SVIDs; convert it and drop the
    /// stream — rotation is handled by re-fetching past the refresh point.
    private func fetchSVID() async throws -> SPIREClientIdentity {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw SPIREServerAPIError.workloadIdentityUnavailable(
                "Workload API socket not found: \(socketPath)")
        }

        let transport: HTTP2ClientTransport.Posix
        do {
            transport = try HTTP2ClientTransport.Posix(
                target: .unixDomainSocket(path: socketPath),
                transportSecurity: .plaintext
            )
        } catch {
            throw SPIREServerAPIError.workloadIdentityUnavailable(
                "Failed to create Workload API transport: \(error)")
        }

        // `FetchX509SVID` is a streaming RPC that normally stays open, but we
        // only consume the first message — the deadline turns a stalled agent
        // into a failed fetch rather than a hung admin call.
        var options = CallOptions.defaults
        options.timeout = fetchTimeout

        do {
            return try await withGRPCClient(transport: transport) { client in
                try await client.serverStreaming(
                    request: ClientRequest(
                        message: Workload_X509SVIDRequest(), metadata: Self.securityMetadata),
                    descriptor: Self.fetchX509SVIDDescriptor,
                    serializer: ProtobufSerializer<Workload_X509SVIDRequest>(),
                    deserializer: ProtobufDeserializer<Workload_X509SVIDResponse>(),
                    options: options
                ) { response in
                    for try await message in response.messages {
                        return try Self.makeIdentity(from: message)
                    }
                    throw SPIREServerAPIError.workloadIdentityUnavailable(
                        "Workload API stream ended without delivering an SVID")
                }
            }
        } catch let error as SPIREServerAPIError {
            throw error
        } catch {
            throw SPIREServerAPIError.workloadIdentityUnavailable("FetchX509SVID: \(error)")
        }
    }

    // MARK: Proto conversion

    /// Convert an X509SVIDResponse to identity materials. When the workload is
    /// entitled to multiple identities the first is used, matching the SPIFFE
    /// spec's definition of the default identity.
    static func makeIdentity(from response: Workload_X509SVIDResponse) throws -> SPIREClientIdentity {
        guard let proto = response.svids.first else {
            throw SPIREServerAPIError.workloadIdentityUnavailable(
                "Workload API response contains no SVIDs")
        }

        let certificateDERs = try splitConcatenatedDER(Array(proto.x509Svid))
        guard let leafDER = certificateDERs.first else {
            throw SPIREServerAPIError.workloadIdentityUnavailable(
                "SVID response contains no certificates")
        }

        // The leaf determines the SVID's lifetime (and thus refresh timing).
        let leaf: Certificate
        do {
            leaf = try Certificate(derEncoded: leafDER)
        } catch {
            throw SPIREServerAPIError.workloadIdentityUnavailable(
                "Failed to parse SVID leaf certificate: \(error)")
        }

        let bundleDERs = try splitConcatenatedDER(Array(proto.bundle))
        guard !bundleDERs.isEmpty else {
            throw SPIREServerAPIError.workloadIdentityUnavailable(
                "SVID response contains no trust bundle")
        }

        return SPIREClientIdentity(
            spiffeID: proto.spiffeID,
            certificateChainPEM: certificateDERs.map { pemEncode(der: Data($0), label: "CERTIFICATE") },
            privateKeyPEM: pemEncode(der: proto.x509SvidKey, label: "PRIVATE KEY"),
            trustBundlePEM: bundleDERs.map { pemEncode(der: Data($0), label: "CERTIFICATE") },
            expiresAt: leaf.notValidAfter
        )
    }

    /// Split a buffer of back-to-back DER-encoded values (as the Workload API
    /// delivers certificate chains and bundles) into the individual values by
    /// walking the outer SEQUENCE headers.
    static func splitConcatenatedDER(_ bytes: [UInt8]) throws -> [[UInt8]] {
        var values: [[UInt8]] = []
        var index = 0

        while index < bytes.count {
            guard bytes[index] == 0x30, index + 1 < bytes.count else {
                throw SPIREServerAPIError.workloadIdentityUnavailable(
                    "Malformed DER: expected SEQUENCE at offset \(index)")
            }

            let first = Int(bytes[index + 1])
            var headerLength = 2
            var contentLength = 0

            if first < 0x80 {
                contentLength = first
            } else {
                let lengthBytes = first & 0x7F
                guard lengthBytes >= 1, lengthBytes <= 4, index + 1 + lengthBytes < bytes.count else {
                    throw SPIREServerAPIError.workloadIdentityUnavailable(
                        "Malformed DER: invalid length at offset \(index)")
                }
                for offset in 0..<lengthBytes {
                    contentLength = (contentLength << 8) | Int(bytes[index + 2 + offset])
                }
                headerLength = 2 + lengthBytes
            }

            let totalLength = headerLength + contentLength
            guard index + totalLength <= bytes.count else {
                throw SPIREServerAPIError.workloadIdentityUnavailable(
                    "Malformed DER: value at offset \(index) exceeds buffer")
            }

            values.append(Array(bytes[index..<(index + totalLength)]))
            index += totalLength
        }

        return values
    }

    /// Wrap DER bytes in a PEM envelope.
    static func pemEncode(der: Data, label: String) -> String {
        let base64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN \(label)-----\n\(base64)\n-----END \(label)-----\n"
    }
}
