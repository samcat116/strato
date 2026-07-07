import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import GRPCProtobuf
import Logging
import X509

// MARK: - Workload API SPIFFE Client

/// SPIFFE client that speaks the SPIFFE Workload API (gRPC over a Unix domain
/// socket) to a local SPIRE agent. SVIDs and trust bundles are fetched from the
/// streaming `FetchX509SVID`/`FetchX509Bundles` RPCs; the stream also delivers
/// rotated SVIDs, which `watchX509SVID()` surfaces to the `SVIDManager`.
public actor WorkloadAPISPIFFEClient: SPIFFEClientProtocol {
    private let socketPath: String
    private let logger: Logger

    /// Delay between reconnection attempts when the watch stream fails or ends.
    private let watchRetryDelay: Duration

    /// Default Workload API socket path
    public static let defaultSocketPath = "/var/run/spire/sockets/workload.sock"

    /// Every Workload API call must carry this metadata per the SPIFFE spec;
    /// servers reject calls without it.
    private static let securityMetadata: Metadata = ["workload.spiffe.io": "true"]

    private static let fetchX509SVIDDescriptor = MethodDescriptor(
        service: ServiceDescriptor(fullyQualifiedService: "SpiffeWorkloadAPI"),
        method: "FetchX509SVID"
    )

    private static let fetchX509BundlesDescriptor = MethodDescriptor(
        service: ServiceDescriptor(fullyQualifiedService: "SpiffeWorkloadAPI"),
        method: "FetchX509Bundles"
    )

    /// Initialize with socket path
    /// - Parameters:
    ///   - socketPath: Path to SPIRE Workload API Unix socket
    ///   - logger: Logger instance
    ///   - watchRetryDelay: Delay before re-dialing after a broken watch stream
    public init(
        socketPath: String = defaultSocketPath,
        logger: Logger,
        watchRetryDelay: Duration = .seconds(5)
    ) {
        self.socketPath = socketPath
        self.logger = logger
        self.watchRetryDelay = watchRetryDelay
    }

    public func fetchX509SVID() async throws -> X509SVID {
        logger.debug(
            "Fetching X.509 SVID from Workload API",
            metadata: [
                "socketPath": .string(socketPath)
            ])

        let svid = try await withWorkloadAPIClient(socketPath: socketPath) { client in
            try await client.serverStreaming(
                request: ClientRequest(message: Workload_X509SVIDRequest(), metadata: Self.securityMetadata),
                descriptor: Self.fetchX509SVIDDescriptor,
                serializer: ProtobufSerializer<Workload_X509SVIDRequest>(),
                deserializer: ProtobufDeserializer<Workload_X509SVIDResponse>(),
                options: .defaults
            ) { response in
                // The RPC is a long-lived stream; the first message carries the
                // current SVID set. Convert it and drop the stream.
                for try await message in response.messages {
                    return try WorkloadAPIConversion.makeSVID(from: message)
                }
                throw SPIFFEError.workloadAPIUnavailable("Workload API stream ended without delivering an SVID")
            }
        }

        logger.info(
            "Fetched X.509 SVID from Workload API",
            metadata: [
                "spiffeID": .string(svid.spiffeID.uri),
                "expiresAt": .string(svid.expiresAt.description),
            ])

        return svid
    }

    public func fetchTrustBundles() async throws -> [String: SPIFFETrustBundle] {
        try await withWorkloadAPIClient(socketPath: socketPath) { client in
            try await client.serverStreaming(
                request: ClientRequest(message: Workload_X509BundlesRequest(), metadata: Self.securityMetadata),
                descriptor: Self.fetchX509BundlesDescriptor,
                serializer: ProtobufSerializer<Workload_X509BundlesRequest>(),
                deserializer: ProtobufDeserializer<Workload_X509BundlesResponse>(),
                options: .defaults
            ) { response in
                for try await message in response.messages {
                    return try WorkloadAPIConversion.makeTrustBundles(from: message)
                }
                throw SPIFFEError.trustBundleUnavailable
            }
        }
    }

    nonisolated public func watchX509SVID() -> AsyncStream<X509SVID> {
        AsyncStream { continuation in
            let task = Task {
                await self.runWatch(continuation: continuation)
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    public func close() async {
        // Fetches and watches use per-call scoped connections that are torn
        // down when their task ends (watch tasks via stream termination), so
        // there is no persistent connection state to release here.
        logger.info("Workload API SPIFFE client closed")
    }

    // MARK: - Private

    /// Consume the FetchX509SVID stream indefinitely, yielding every SVID update
    /// (including the initial one) and re-dialing with a delay whenever the
    /// stream ends or fails. Runs until the consumer cancels the stream.
    private func runWatch(continuation: AsyncStream<X509SVID>.Continuation) async {
        while !Task.isCancelled {
            do {
                try await withWorkloadAPIClient(socketPath: socketPath) { client in
                    try await client.serverStreaming(
                        request: ClientRequest(
                            message: Workload_X509SVIDRequest(), metadata: Self.securityMetadata),
                        descriptor: Self.fetchX509SVIDDescriptor,
                        serializer: ProtobufSerializer<Workload_X509SVIDRequest>(),
                        deserializer: ProtobufDeserializer<Workload_X509SVIDResponse>(),
                        options: .defaults
                    ) { response in
                        for try await message in response.messages {
                            let svid = try WorkloadAPIConversion.makeSVID(from: message)
                            self.logger.info(
                                "Received SVID update from Workload API",
                                metadata: [
                                    "spiffeID": .string(svid.spiffeID.uri),
                                    "expiresAt": .string(svid.expiresAt.description),
                                ])
                            continuation.yield(svid)
                        }
                    }
                }
                logger.warning("Workload API SVID stream ended; reconnecting")
            } catch {
                if !Task.isCancelled {
                    logger.error("Error watching Workload API SVID stream: \(error)")
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

    /// Run `body` against a gRPC client connected to the Workload API socket,
    /// tearing the connection down when it returns.
    private func withWorkloadAPIClient<Result: Sendable>(
        socketPath: String,
        _ body: @Sendable @escaping (GRPCClient<HTTP2ClientTransport.Posix>) async throws -> Result
    ) async throws -> Result {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw SPIFFEError.workloadAPIUnavailable("Socket not found: \(socketPath)")
        }

        let transport: HTTP2ClientTransport.Posix
        do {
            transport = try HTTP2ClientTransport.Posix(
                target: .unixDomainSocket(path: socketPath),
                transportSecurity: .plaintext
            )
        } catch {
            throw SPIFFEError.connectionFailed("Failed to create Workload API transport: \(error)")
        }

        return try await withGRPCClient(transport: transport) { client in
            try await body(client)
        }
    }
}

// MARK: - Proto -> SPIFFE type conversion

/// Conversion from Workload API protobuf messages (DER) to the PEM-based SPIFFE
/// types used by the rest of the agent.
enum WorkloadAPIConversion {
    /// Convert an X509SVIDResponse to the agent's X509SVID type. When the
    /// workload is entitled to multiple identities the first is used, matching
    /// the SPIFFE spec's definition of the default identity.
    static func makeSVID(from response: Workload_X509SVIDResponse) throws -> X509SVID {
        guard let proto = response.svids.first else {
            throw SPIFFEError.noSVIDAvailable
        }

        guard let spiffeID = SPIFFEIdentity(uri: proto.spiffeID) else {
            throw SPIFFEError.invalidSPIFFEID(proto.spiffeID)
        }

        let certificateDERs = try splitConcatenatedDER(Array(proto.x509Svid))
        guard let leafDER = certificateDERs.first else {
            throw SPIFFEError.parseError("SVID response contains no certificates")
        }

        // The leaf determines the SVID's lifetime (and thus rotation timing)
        let leaf: Certificate
        do {
            leaf = try Certificate(derEncoded: leafDER)
        } catch {
            throw SPIFFEError.parseError("Failed to parse SVID leaf certificate: \(error)")
        }

        let bundleDERs = try splitConcatenatedDER(Array(proto.bundle))

        return X509SVID(
            spiffeID: spiffeID,
            certificateChain: certificateDERs.map { pemEncode(der: Data($0), label: "CERTIFICATE") },
            privateKey: pemEncode(der: proto.x509SvidKey, label: "PRIVATE KEY"),
            trustBundle: bundleDERs.map { pemEncode(der: Data($0), label: "CERTIFICATE") },
            expiresAt: leaf.notValidAfter,
            hint: proto.hint.isEmpty ? nil : proto.hint
        )
    }

    /// Convert an X509BundlesResponse (bundles keyed by trust-domain SPIFFE ID)
    /// to the agent's trust bundle type.
    static func makeTrustBundles(from response: Workload_X509BundlesResponse) throws -> [String: SPIFFETrustBundle] {
        var bundles: [String: SPIFFETrustBundle] = [:]
        for (trustDomainID, der) in response.bundles {
            let trustDomain = SPIFFEIdentity(uri: trustDomainID)?.trustDomain ?? trustDomainID
            let authorities = try splitConcatenatedDER(Array(der))
                .map { pemEncode(der: Data($0), label: "CERTIFICATE") }
            bundles[trustDomainID] = SPIFFETrustBundle(
                trustDomain: trustDomain,
                x509Authorities: authorities
            )
        }
        return bundles
    }

    /// Split a buffer of back-to-back DER-encoded values (as the Workload API
    /// delivers certificate chains and bundles) into the individual values by
    /// walking the outer SEQUENCE headers.
    static func splitConcatenatedDER(_ bytes: [UInt8]) throws -> [[UInt8]] {
        var values: [[UInt8]] = []
        var index = 0

        while index < bytes.count {
            guard bytes[index] == 0x30, index + 1 < bytes.count else {
                throw SPIFFEError.parseError("Malformed DER: expected SEQUENCE at offset \(index)")
            }

            let first = Int(bytes[index + 1])
            var headerLength = 2
            var contentLength = 0

            if first < 0x80 {
                contentLength = first
            } else {
                let lengthBytes = first & 0x7F
                guard lengthBytes >= 1, lengthBytes <= 4, index + 1 + lengthBytes < bytes.count else {
                    throw SPIFFEError.parseError("Malformed DER: invalid length at offset \(index)")
                }
                for offset in 0..<lengthBytes {
                    contentLength = (contentLength << 8) | Int(bytes[index + 2 + offset])
                }
                headerLength = 2 + lengthBytes
            }

            let totalLength = headerLength + contentLength
            guard index + totalLength <= bytes.count else {
                throw SPIFFEError.parseError("Malformed DER: value at offset \(index) exceeds buffer")
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
