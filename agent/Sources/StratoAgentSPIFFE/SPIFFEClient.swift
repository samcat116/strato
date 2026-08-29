import Foundation
import Logging
import X509

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

    /// Mint a JWT-SVID for the given audiences (issue #495).
    ///
    /// JWT-SVIDs are audience-scoped by construction: the token is only valid
    /// for the relying parties named here, so a token captured by one service
    /// cannot be replayed against another. Sources that cannot mint tokens
    /// throw `SPIFFEError.unsupportedOperation`.
    ///
    /// - Parameters:
    ///   - audience: the relying parties the token is for. Must be non-empty.
    ///   - spiffeID: the identity to mint for, when the workload is entitled
    ///     to several; nil takes the default identity.
    func fetchJWTSVID(audience: [String], spiffeID: SPIFFEIdentity?) async throws -> JWTSVID

    /// Fetch the JWT signing keys (JWKS) for every trust domain the workload
    /// knows, keyed by the trust domain's SPIFFE ID. Relying parties verify
    /// JWT-SVIDs against these.
    func fetchJWTBundles() async throws -> [String: JWTBundle]

    /// Ask the Workload API to validate a JWT-SVID against an audience,
    /// returning the identity it names.
    ///
    /// This delegates verification to the local SPIRE agent, which holds the
    /// trust domain's current JWT authorities. The returned claims name the
    /// principal; they never carry authorization.
    func validateJWTSVID(token: String, audience: String) async throws -> ValidatedJWTSVID

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
        logger.debug(
            "Fetching X.509 SVID from files",
            metadata: [
                "certificatePath": .string(certificatePath),
                "privateKeyPath": .string(privateKeyPath),
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

        // Rotation timing keys off the leaf certificate's real expiry
        let expiresAt: Date
        do {
            let leaf = try Certificate(pemEncoded: certificates[0])
            expiresAt = leaf.notValidAfter
        } catch {
            throw SPIFFEError.parseError("Failed to parse certificate in \(certificatePath): \(error)")
        }

        let svid = X509SVID(
            spiffeID: spiffeID,
            certificateChain: certificates,
            privateKey: keyPEM,
            trustBundle: trustCerts,
            expiresAt: expiresAt
        )

        logger.info(
            "Loaded X.509 SVID",
            metadata: [
                "spiffeID": .string(svid.spiffeID.uri),
                "expiresAt": .string(svid.expiresAt.description),
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

    // JWT-SVIDs cannot come from files: minting one needs the private signing
    // key held by the SPIRE server, and validating one needs the trust
    // domain's current JWT authorities. A spiffe-helper deployment writes
    // neither, so these fail loudly rather than pretending an empty answer is
    // a valid one.

    public func fetchJWTSVID(audience: [String], spiffeID: SPIFFEIdentity?) async throws -> JWTSVID {
        throw SPIFFEError.unsupportedOperation(
            "File-based SVIDs cannot mint JWT-SVIDs; configure the SPIRE Workload API socket instead")
    }

    public func fetchJWTBundles() async throws -> [String: JWTBundle] {
        throw SPIFFEError.unsupportedOperation(
            "File-based SVIDs carry no JWT authorities; configure the SPIRE Workload API socket instead")
    }

    public func validateJWTSVID(token: String, audience: String) async throws -> ValidatedJWTSVID {
        throw SPIFFEError.unsupportedOperation(
            "File-based SVIDs cannot validate JWT-SVIDs; configure the SPIRE Workload API socket instead")
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

                            logger.info(
                                "SVID rotated, notified watchers",
                                metadata: [
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
