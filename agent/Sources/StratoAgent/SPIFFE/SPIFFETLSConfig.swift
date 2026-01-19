import Foundation
import NIOSSL
import Logging

// MARK: - SPIFFE TLS Configuration

/// Utilities for creating TLS configurations from SPIFFE SVIDs
public enum SPIFFETLSConfig {
    /// Create a client TLS configuration for mTLS using an SVID
    /// - Parameters:
    ///   - svid: The X.509 SVID to use for client authentication
    ///   - verifyPeer: Whether to verify the server certificate (default: true)
    /// - Returns: TLSConfiguration for client connections
    public static func makeClientConfiguration(
        svid: X509SVID,
        verifyPeer: Bool = true
    ) throws -> TLSConfiguration {
        // Parse certificate chain
        let certificates = try svid.certificateChain.map { pemString in
            try NIOSSLCertificate(bytes: [UInt8](pemString.utf8), format: .pem)
        }

        // Parse private key
        let privateKey = try NIOSSLPrivateKey(bytes: [UInt8](svid.privateKey.utf8), format: .pem)

        // Parse trust bundle for server verification
        let trustRoots: NIOSSLTrustRoots
        if verifyPeer {
            let trustedCerts = try svid.trustBundle.map { pemString in
                try NIOSSLCertificate(bytes: [UInt8](pemString.utf8), format: .pem)
            }
            trustRoots = .certificates(trustedCerts)
        } else {
            trustRoots = .default
        }

        var config = TLSConfiguration.makeClientConfiguration()
        config.certificateChain = certificates.map { .certificate($0) }
        config.privateKey = .privateKey(privateKey)
        config.trustRoots = trustRoots
        // For SPIFFE mTLS, we verify the certificate chain but not hostname
        // since SPIFFE uses URI SANs (spiffe://...) not DNS SANs
        // The SPIFFE ID in the URI SAN is verified separately by the application
        config.certificateVerification = verifyPeer ? .noHostnameVerification : .none

        return config
    }

    /// Create a server TLS configuration for mTLS using an SVID
    /// - Parameters:
    ///   - svid: The X.509 SVID to use for server identity
    ///   - requireClientCert: Whether to require client certificates (default: true for mTLS)
    /// - Returns: TLSConfiguration for server connections
    public static func makeServerConfiguration(
        svid: X509SVID,
        requireClientCert: Bool = true
    ) throws -> TLSConfiguration {
        // Parse certificate chain
        let certificates = try svid.certificateChain.map { pemString in
            try NIOSSLCertificate(bytes: [UInt8](pemString.utf8), format: .pem)
        }

        // Parse private key
        let privateKey = try NIOSSLPrivateKey(bytes: [UInt8](svid.privateKey.utf8), format: .pem)

        // Parse trust bundle for client verification
        let trustedCerts = try svid.trustBundle.map { pemString in
            try NIOSSLCertificate(bytes: [UInt8](pemString.utf8), format: .pem)
        }

        var config = TLSConfiguration.makeServerConfiguration(
            certificateChain: certificates.map { .certificate($0) },
            privateKey: .privateKey(privateKey)
        )
        config.trustRoots = .certificates(trustedCerts)
        config.certificateVerification = requireClientCert ? .fullVerification : .none

        return config
    }

    /// Create TLS configuration from trust bundle only (for verifying peers)
    /// - Parameter bundle: The trust bundle containing CA certificates
    /// - Returns: TLSConfiguration with only trust roots set
    public static func makeTrustOnlyConfiguration(
        bundle: SPIFFETrustBundle
    ) throws -> TLSConfiguration {
        let trustedCerts = try bundle.x509Authorities.map { pemString in
            try NIOSSLCertificate(bytes: [UInt8](pemString.utf8), format: .pem)
        }

        var config = TLSConfiguration.makeClientConfiguration()
        config.trustRoots = .certificates(trustedCerts)
        config.certificateVerification = .fullVerification

        return config
    }
}

// MARK: - SVID Manager

/// Manages SVID lifecycle including fetching, caching, and rotation
public actor SVIDManager {
    private let client: any SPIFFEClientProtocol
    private let logger: Logger

    private var currentSVID: X509SVID?
    private var currentTLSConfig: TLSConfiguration?
    private var watchTask: Task<Void, Never>?
    private var rotationCallbacks: [(X509SVID) async -> Void] = []

    /// Time before expiration to trigger rotation (default: 5 minutes)
    public var rotationMargin: TimeInterval = 300

    public init(client: any SPIFFEClientProtocol, logger: Logger) {
        self.client = client
        self.logger = logger
    }

    /// Start the SVID manager and fetch initial SVID
    public func start() async throws {
        logger.info("Starting SVID manager")

        // Fetch initial SVID
        currentSVID = try await client.fetchX509SVID()

        // Generate TLS config
        currentTLSConfig = try SPIFFETLSConfig.makeClientConfiguration(svid: currentSVID!)

        logger.info("Initial SVID loaded", metadata: [
            "spiffeID": .string(currentSVID!.spiffeID.uri),
            "expiresAt": .string(currentSVID!.expiresAt.description)
        ])

        // Start watching for rotations
        startWatching()
    }

    /// Stop the SVID manager
    public func stop() async {
        watchTask?.cancel()
        watchTask = nil
        await client.close()
        logger.info("SVID manager stopped")
    }

    /// Get the current SVID
    public func getSVID() throws -> X509SVID {
        guard let svid = currentSVID else {
            throw SPIFFEError.noSVIDAvailable
        }

        if svid.isExpired {
            throw SPIFFEError.svidExpired
        }

        return svid
    }

    /// Get the current TLS configuration
    public func getTLSConfiguration() throws -> TLSConfiguration {
        guard let config = currentTLSConfig else {
            throw SPIFFEError.noSVIDAvailable
        }
        return config
    }

    /// Register a callback for SVID rotation events
    public func onRotation(_ callback: @escaping (X509SVID) async -> Void) {
        rotationCallbacks.append(callback)
    }

    /// Check if SVID needs rotation
    public func needsRotation() -> Bool {
        guard let svid = currentSVID else {
            return true
        }
        return svid.willExpire(within: rotationMargin)
    }

    /// Force SVID refresh
    public func refresh() async throws {
        logger.info("Forcing SVID refresh")
        let newSVID = try await client.fetchX509SVID()
        await handleNewSVID(newSVID)
    }

    // MARK: - Private Methods

    private func startWatching() {
        watchTask = Task {
            for await newSVID in client.watchX509SVID() {
                await handleNewSVID(newSVID)
            }
        }
    }

    private func handleNewSVID(_ svid: X509SVID) async {
        logger.info("SVID rotated", metadata: [
            "spiffeID": .string(svid.spiffeID.uri),
            "expiresAt": .string(svid.expiresAt.description)
        ])

        currentSVID = svid

        // Update TLS config
        do {
            currentTLSConfig = try SPIFFETLSConfig.makeClientConfiguration(svid: svid)
        } catch {
            logger.error("Failed to update TLS config after rotation: \(error)")
        }

        // Notify callbacks
        for callback in rotationCallbacks {
            await callback(svid)
        }
    }
}
