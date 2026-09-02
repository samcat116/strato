import Foundation
import NIOSSL
import Logging

// MARK: - SPIFFE TLS Configuration

/// Utilities for creating TLS configurations from SPIFFE SVIDs
public enum SPIFFETLSConfig {
    /// Create a client TLS configuration for mTLS using an SVID
    /// - Parameters:
    ///   - svid: The X.509 SVID to use for client authentication
    ///   - peerTrustDomain: The trust domain of the peer this configuration
    ///     will dial, selecting which of the SVID's root sets verifies it.
    ///     Nil means the SVID's own domain — the single-trust-domain case.
    ///     Once the agent lives in its organization's trust domain (issue
    ///     #600) the control plane is a federated peer, and naming its domain
    ///     here is what picks up the federated roots. Unlike the WebSocket
    ///     path, this is load-bearing rather than defense in depth: the
    ///     artifact downloader has no pinning callback, so these roots are the
    ///     only thing standing between it and an unverified peer.
    ///   - verifyPeer: Whether to verify the server certificate (default: true)
    /// - Returns: TLSConfiguration for client connections
    public static func makeClientConfiguration(
        svid: X509SVID,
        peerTrustDomain: String? = nil,
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
            let peerDomain = peerTrustDomain ?? svid.spiffeID.trustDomain
            guard let rootsPEM = svid.roots(forTrustDomain: peerDomain) else {
                throw SPIFFEError.noRootsForTrustDomain(
                    peerTrustDomain: peerDomain,
                    ownTrustDomain: svid.spiffeID.trustDomain,
                    federated: Array(svid.federatedBundles.keys)
                )
            }
            let trustedCerts = try rootsPEM.map { pemString in
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
        // SPIFFE peers present URI SANs (spiffe://...), not DNS SANs, so
        // hostname verification cannot apply. Server identity is enforced
        // instead by the pinned-SPIFFE-ID verification callback that
        // SPIFFEWebSocketConnector installs on the connection (issue #552) —
        // this configuration alone only checks that the chain reaches the
        // trust bundle, which any workload in the trust domain satisfies.
        config.certificateVerification = verifyPeer ? .noHostnameVerification : .none

        return config
    }

}

// MARK: - SVID Manager

/// Manages SVID lifecycle including fetching, caching, and rotation
public actor SVIDManager {
    private let client: any SPIFFEClientProtocol
    private let logger: Logger

    /// Trust domain of the peer the managed TLS configuration dials — the
    /// control plane, the agent's only mTLS peer. Nil keeps the SVID's own
    /// domain, which is correct until the agent and control plane live in
    /// different trust domains (issue #600).
    private let peerTrustDomain: String?

    private var currentSVID: X509SVID?
    private var currentTLSConfig: TLSConfiguration?
    private var watchTask: Task<Void, Never>?
    private var rotationCallbacks: [(X509SVID) async -> Void] = []

    public init(client: any SPIFFEClientProtocol, logger: Logger, peerTrustDomain: String? = nil) {
        self.client = client
        self.logger = logger
        self.peerTrustDomain = peerTrustDomain
    }

    /// Start the SVID manager and fetch initial SVID
    public func start() async throws {
        logger.info("Starting SVID manager")

        // Fetch initial SVID
        currentSVID = try await client.fetchX509SVID()

        // Generate TLS config
        currentTLSConfig = try SPIFFETLSConfig.makeClientConfiguration(
            svid: currentSVID!, peerTrustDomain: peerTrustDomain)

        logger.info(
            "Initial SVID loaded",
            metadata: [
                "strato.agent.identity": .string(currentSVID!.spiffeID.uri),
                "expiresAt": .string(currentSVID!.expiresAt.description),
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
        logger.info(
            "SVID rotated",
            metadata: [
                "strato.agent.identity": .string(svid.spiffeID.uri),
                "expiresAt": .string(svid.expiresAt.description),
            ])

        currentSVID = svid

        // Update TLS config
        do {
            currentTLSConfig = try SPIFFETLSConfig.makeClientConfiguration(
                svid: svid, peerTrustDomain: peerTrustDomain)
        } catch {
            logger.error("Failed to update TLS config after rotation: \(error)")
        }

        // Notify callbacks
        for callback in rotationCallbacks {
            await callback(svid)
        }
    }
}
