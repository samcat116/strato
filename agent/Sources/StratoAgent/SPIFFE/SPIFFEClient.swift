import Foundation
import Logging

// MARK: - SPIFFE Client Protocol

/// Protocol for fetching SVIDs from SPIRE
public protocol SPIFFEClientProtocol: Sendable {
    /// Fetch the current X.509 SVID for this workload
    func fetchX509SVID() async throws -> X509SVID

    /// Fetch trust bundles for validating peer certificates
    func fetchTrustBundles() async throws -> [String: SPIFFETrustBundle]

    /// Watch for SVID updates (rotation)
    /// Note: Returns a nonisolated stream that can be consumed by any actor
    nonisolated func watchX509SVID() -> AsyncStream<X509SVID>

    /// Close the client connection
    func close() async
}

// MARK: - File-Based SPIFFE Client

/// SPIFFE client that reads certificates from files
/// Works with spiffe-helper or manual certificate deployment
public actor FileSPIFFEClient: SPIFFEClientProtocol {
    private let certificatePath: String
    private let privateKeyPath: String
    private let trustBundlePath: String
    private let spiffeID: SPIFFEIdentity
    private let logger: Logger

    private var watchTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<X509SVID>.Continuation] = [:]

    /// Initialize with file paths
    /// - Parameters:
    ///   - certificatePath: Path to the X.509 certificate (PEM)
    ///   - privateKeyPath: Path to the private key (PEM)
    ///   - trustBundlePath: Path to the trust bundle (PEM)
    ///   - spiffeID: The SPIFFE ID for this workload
    ///   - logger: Logger instance
    public init(
        certificatePath: String,
        privateKeyPath: String,
        trustBundlePath: String,
        spiffeID: SPIFFEIdentity,
        logger: Logger
    ) {
        self.certificatePath = certificatePath
        self.privateKeyPath = privateKeyPath
        self.trustBundlePath = trustBundlePath
        self.spiffeID = spiffeID
        self.logger = logger
    }

    public func fetchX509SVID() async throws -> X509SVID {
        logger.debug("Fetching X.509 SVID from files", metadata: [
            "certificatePath": .string(certificatePath),
            "privateKeyPath": .string(privateKeyPath)
        ])

        // Read certificate chain
        let certPEM = try readFile(certificatePath)
        let certificates = parsePEMCertificates(certPEM)

        guard !certificates.isEmpty else {
            throw SPIFFEError.parseError("No certificates found in \(certificatePath)")
        }

        // Read private key
        let keyPEM = try readFile(privateKeyPath)

        // Read trust bundle
        let bundlePEM = try readFile(trustBundlePath)
        let trustCerts = parsePEMCertificates(bundlePEM)

        // Parse expiration from certificate (simplified - assume 1 hour from now)
        // In production, parse the actual certificate expiration
        let expiresAt = Date().addingTimeInterval(3600)

        let svid = X509SVID(
            spiffeID: spiffeID,
            certificateChain: certificates,
            privateKey: keyPEM,
            trustBundle: trustCerts,
            expiresAt: expiresAt
        )

        logger.info("Loaded X.509 SVID", metadata: [
            "spiffeID": .string(svid.spiffeID.uri),
            "expiresAt": .string(svid.expiresAt.description)
        ])

        return svid
    }

    public func fetchTrustBundles() async throws -> [String: SPIFFETrustBundle] {
        let bundlePEM = try readFile(trustBundlePath)
        let trustCerts = parsePEMCertificates(bundlePEM)

        let bundle = SPIFFETrustBundle(
            trustDomain: spiffeID.trustDomain,
            x509Authorities: trustCerts
        )

        return [spiffeID.trustDomain: bundle]
    }

    nonisolated public func watchX509SVID() -> AsyncStream<X509SVID> {
        let id = UUID()

        return AsyncStream { continuation in
            Task {
                await self.addContinuation(id: id, continuation: continuation)

                continuation.onTermination = { _ in
                    Task {
                        await self.removeContinuation(id: id)
                    }
                }
            }

            // Start file watcher if not already running
            Task {
                await self.startWatching()
            }
        }
    }

    public func close() async {
        watchTask?.cancel()
        watchTask = nil

        for (_, continuation) in continuations {
            continuation.finish()
        }
        continuations.removeAll()

        logger.info("File-based SPIFFE client closed")
    }

    // MARK: - Private Methods

    private func addContinuation(id: UUID, continuation: AsyncStream<X509SVID>.Continuation) {
        continuations[id] = continuation
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func startWatching() {
        guard watchTask == nil else { return }

        watchTask = Task {
            var lastModified: Date?

            while !Task.isCancelled {
                do {
                    // Check file modification time
                    let attrs = try FileManager.default.attributesOfItem(atPath: certificatePath)
                    if let modDate = attrs[.modificationDate] as? Date {
                        if lastModified != modDate {
                            lastModified = modDate

                            // File changed, fetch new SVID
                            let svid = try await fetchX509SVID()

                            // Notify all watchers
                            for (_, continuation) in continuations {
                                continuation.yield(svid)
                            }

                            logger.info("SVID rotated, notified watchers", metadata: [
                                "spiffeID": .string(svid.spiffeID.uri)
                            ])
                        }
                    }

                    // Check every 30 seconds
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    if !Task.isCancelled {
                        logger.error("Error watching SVID files: \(error)")
                        try? await Task.sleep(for: .seconds(5))
                    }
                }
            }
        }
    }

    private func readFile(_ path: String) throws -> String {
        guard FileManager.default.fileExists(atPath: path) else {
            throw SPIFFEError.workloadAPIUnavailable("File not found: \(path)")
        }

        do {
            return try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw SPIFFEError.parseError("Failed to read file \(path): \(error.localizedDescription)")
        }
    }

    private func parsePEMCertificates(_ pem: String) -> [String] {
        var certificates: [String] = []
        var current = ""
        var inCertificate = false

        for line in pem.components(separatedBy: .newlines) {
            if line.contains("-----BEGIN") {
                inCertificate = true
                current = line + "\n"
            } else if line.contains("-----END") {
                current += line + "\n"
                certificates.append(current)
                current = ""
                inCertificate = false
            } else if inCertificate {
                current += line + "\n"
            }
        }

        return certificates
    }
}

// MARK: - Workload API SPIFFE Client

/// SPIFFE client that connects to SPIRE Workload API
/// Uses gRPC over Unix domain socket
public actor WorkloadAPISPIFFEClient: SPIFFEClientProtocol {
    private let socketPath: String
    private let logger: Logger

    private var watchTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<X509SVID>.Continuation] = [:]

    /// Default Workload API socket path
    public static let defaultSocketPath = "/var/run/spire/sockets/workload.sock"

    /// Initialize with socket path
    /// - Parameters:
    ///   - socketPath: Path to SPIRE Workload API Unix socket
    ///   - logger: Logger instance
    public init(
        socketPath: String = defaultSocketPath,
        logger: Logger
    ) {
        self.socketPath = socketPath
        self.logger = logger
    }

    public func fetchX509SVID() async throws -> X509SVID {
        logger.debug("Fetching X.509 SVID from Workload API", metadata: [
            "socketPath": .string(socketPath)
        ])

        // Check if socket exists
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw SPIFFEError.workloadAPIUnavailable("Socket not found: \(socketPath)")
        }

        // TODO: Implement actual gRPC call to Workload API
        // For now, this is a placeholder that throws an error
        // In production, use swift-grpc with the SPIFFE proto definitions:
        // https://github.com/spiffe/spiffe/blob/main/proto/spiffe/workload/workload.proto

        throw SPIFFEError.workloadAPIUnavailable(
            "gRPC Workload API not yet implemented. Use FileSPIFFEClient with spiffe-helper instead."
        )
    }

    public func fetchTrustBundles() async throws -> [String: SPIFFETrustBundle] {
        throw SPIFFEError.workloadAPIUnavailable(
            "gRPC Workload API not yet implemented. Use FileSPIFFEClient with spiffe-helper instead."
        )
    }

    nonisolated public func watchX509SVID() -> AsyncStream<X509SVID> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    public func close() async {
        watchTask?.cancel()
        watchTask = nil
        logger.info("Workload API SPIFFE client closed")
    }
}

// MARK: - SPIFFE Client Factory

/// Factory for creating SPIFFE clients
public enum SPIFFEClientFactory {
    /// Configuration for SPIFFE client
    public struct Config: Sendable {
        /// Source type for SVIDs
        public enum Source: Sendable {
            /// Read from files (works with spiffe-helper)
            case files(certificate: String, privateKey: String, trustBundle: String)

            /// Connect to SPIRE Workload API
            case workloadAPI(socketPath: String)
        }

        public let source: Source
        public let spiffeID: SPIFFEIdentity

        public init(source: Source, spiffeID: SPIFFEIdentity) {
            self.source = source
            self.spiffeID = spiffeID
        }

        /// Default configuration using Workload API
        public static func workloadAPI(
            spiffeID: SPIFFEIdentity,
            socketPath: String = WorkloadAPISPIFFEClient.defaultSocketPath
        ) -> Config {
            Config(source: .workloadAPI(socketPath: socketPath), spiffeID: spiffeID)
        }

        /// Configuration using file-based SVIDs
        public static func files(
            spiffeID: SPIFFEIdentity,
            certificatePath: String,
            privateKeyPath: String,
            trustBundlePath: String
        ) -> Config {
            Config(
                source: .files(
                    certificate: certificatePath,
                    privateKey: privateKeyPath,
                    trustBundle: trustBundlePath
                ),
                spiffeID: spiffeID
            )
        }
    }

    /// Create a SPIFFE client from configuration
    public static func create(config: Config, logger: Logger) -> any SPIFFEClientProtocol {
        switch config.source {
        case .files(let cert, let key, let bundle):
            return FileSPIFFEClient(
                certificatePath: cert,
                privateKeyPath: key,
                trustBundlePath: bundle,
                spiffeID: config.spiffeID,
                logger: logger
            )

        case .workloadAPI(let socketPath):
            return WorkloadAPISPIFFEClient(
                socketPath: socketPath,
                logger: logger
            )
        }
    }
}
