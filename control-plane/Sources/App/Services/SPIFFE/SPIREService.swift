import Foundation
import Vapor
import Crypto

// MARK: - SPIFFE Identity

/// A SPIFFE ID representing a workload identity
/// Format: spiffe://trust-domain/path
public struct SPIFFEIdentity: Sendable, Equatable, Hashable, CustomStringConvertible {
    /// The trust domain (e.g., "strato.local")
    public let trustDomain: String

    /// The path identifying the workload (e.g., "/agent/agent-1")
    public let path: String

    /// Full SPIFFE ID URI
    public var uri: String {
        "spiffe://\(trustDomain)\(path)"
    }

    public var description: String {
        uri
    }

    /// Initialize from trust domain and path
    public init(trustDomain: String, path: String) {
        self.trustDomain = trustDomain
        self.path = path.hasPrefix("/") ? path : "/\(path)"
    }

    /// Parse a SPIFFE ID from URI string
    /// - Parameter uri: The SPIFFE ID URI (e.g., "spiffe://strato.local/agent/agent-1")
    /// - Returns: Parsed SPIFFEIdentity or nil if invalid
    public init?(uri: String) {
        guard uri.hasPrefix("spiffe://") else {
            return nil
        }

        let withoutScheme = String(uri.dropFirst("spiffe://".count))

        // Find first slash after trust domain
        guard let slashIndex = withoutScheme.firstIndex(of: "/") else {
            // No path specified
            self.trustDomain = withoutScheme
            self.path = "/"
            return
        }

        self.trustDomain = String(withoutScheme[..<slashIndex])
        self.path = String(withoutScheme[slashIndex...])
    }

    /// Check if this identity represents an agent
    public var isAgent: Bool {
        path.hasPrefix("/agent/")
    }

    /// Extract agent ID from path (if this is an agent identity)
    public var agentID: String? {
        guard isAgent else { return nil }
        return String(path.dropFirst("/agent/".count))
    }
}

// MARK: - SPIRE Trust Bundle

/// Trust bundle containing CA certificates for a trust domain
public struct SPIRETrustBundle: Sendable {
    /// The trust domain this bundle is for
    public let trustDomain: String

    /// X.509 CA certificates (PEM-encoded)
    public let x509Authorities: [String]

    /// When this bundle was last refreshed
    public let refreshedAt: Date

    /// Sequence number for change detection
    public let sequenceNumber: UInt64

    public init(
        trustDomain: String,
        x509Authorities: [String],
        refreshedAt: Date = Date(),
        sequenceNumber: UInt64 = 0
    ) {
        self.trustDomain = trustDomain
        self.x509Authorities = x509Authorities
        self.refreshedAt = refreshedAt
        self.sequenceNumber = sequenceNumber
    }

    /// Combined authorities as single PEM string
    public var x509AuthoritiesPEM: String {
        x509Authorities.joined(separator: "\n")
    }
}

// MARK: - SPIRE Service Errors

public enum SPIREServiceError: Error, LocalizedError {
    case notConfigured
    case trustBundleUnavailable
    case certificateValidationFailed(String)
    case spiffeIDExtractionFailed(String)
    case serverConnectionFailed(String)
    case invalidCertificate(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "SPIRE service is not configured"
        case .trustBundleUnavailable:
            return "Trust bundle is not available"
        case .certificateValidationFailed(let reason):
            return "Certificate validation failed: \(reason)"
        case .spiffeIDExtractionFailed(let reason):
            return "Failed to extract SPIFFE ID: \(reason)"
        case .serverConnectionFailed(let reason):
            return "Failed to connect to SPIRE Server: \(reason)"
        case .invalidCertificate(let reason):
            return "Invalid certificate: \(reason)"
        }
    }
}

// MARK: - SPIRE Service Configuration

public struct SPIREServiceConfig: Sendable {
    /// Whether SPIRE authentication is enabled
    public let enabled: Bool

    /// Expected trust domain for agents
    public let trustDomain: String

    /// URL of the SPIRE Server bundle endpoint
    public let bundleEndpointURL: String?

    /// Path to local trust bundle file (alternative to endpoint)
    public let trustBundlePath: String?

    /// How often to refresh the trust bundle (seconds)
    public let bundleRefreshInterval: TimeInterval

    /// Whether to require client certificates for agent connections
    public let requireClientCert: Bool

    public init(
        enabled: Bool = false,
        trustDomain: String = "strato.local",
        bundleEndpointURL: String? = nil,
        trustBundlePath: String? = nil,
        bundleRefreshInterval: TimeInterval = 300,
        requireClientCert: Bool = true
    ) {
        self.enabled = enabled
        self.trustDomain = trustDomain
        self.bundleEndpointURL = bundleEndpointURL
        self.trustBundlePath = trustBundlePath
        self.bundleRefreshInterval = bundleRefreshInterval
        self.requireClientCert = requireClientCert
    }

    /// Load configuration from environment variables
    public static func fromEnvironment() -> SPIREServiceConfig {
        let enabled = Environment.get("SPIRE_ENABLED")?.lowercased() == "true"
        let trustDomain = Environment.get("SPIRE_TRUST_DOMAIN") ?? "strato.local"
        let bundleEndpointURL = Environment.get("SPIRE_BUNDLE_ENDPOINT_URL")
        let trustBundlePath = Environment.get("SPIRE_TRUST_BUNDLE_PATH")
        let bundleRefreshInterval = TimeInterval(Environment.get("SPIRE_BUNDLE_REFRESH_INTERVAL") ?? "300") ?? 300
        let requireClientCert = Environment.get("SPIRE_REQUIRE_CLIENT_CERT")?.lowercased() != "false"

        return SPIREServiceConfig(
            enabled: enabled,
            trustDomain: trustDomain,
            bundleEndpointURL: bundleEndpointURL,
            trustBundlePath: trustBundlePath,
            bundleRefreshInterval: bundleRefreshInterval,
            requireClientCert: requireClientCert
        )
    }
}

// MARK: - SPIRE Service

/// Service for managing SPIRE trust bundles and validating agent certificates
public actor SPIREService {
    private let config: SPIREServiceConfig
    private let logger: Logger
    private let httpClient: Client

    private var trustBundle: SPIRETrustBundle?
    private var refreshTask: Task<Void, Never>?

    public init(config: SPIREServiceConfig, logger: Logger, httpClient: Client) {
        self.config = config
        self.logger = logger
        self.httpClient = httpClient
    }

    /// Start the SPIRE service
    public func start() async throws {
        guard config.enabled else {
            logger.info("SPIRE authentication is disabled")
            return
        }

        logger.info("Starting SPIRE service", metadata: [
            "trustDomain": .string(config.trustDomain),
            "bundleEndpointURL": .string(config.bundleEndpointURL ?? "none"),
            "trustBundlePath": .string(config.trustBundlePath ?? "none")
        ])

        // Load initial trust bundle
        try await refreshTrustBundle()

        // Start periodic refresh
        startPeriodicRefresh()

        logger.info("SPIRE service started successfully")
    }

    /// Stop the SPIRE service
    public func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        logger.info("SPIRE service stopped")
    }

    /// Check if SPIRE authentication is enabled
    public var isEnabled: Bool {
        config.enabled
    }

    /// Get the current trust bundle
    public func getTrustBundle() throws -> SPIRETrustBundle {
        guard let bundle = trustBundle else {
            throw SPIREServiceError.trustBundleUnavailable
        }
        return bundle
    }

    /// Validate a client certificate and extract the SPIFFE ID
    /// - Parameter certificatePEM: The client certificate in PEM format
    /// - Returns: The validated SPIFFE identity
    public func validateCertificate(_ certificatePEM: String) async throws -> SPIFFEIdentity {
        guard config.enabled else {
            throw SPIREServiceError.notConfigured
        }

        guard trustBundle != nil else {
            throw SPIREServiceError.trustBundleUnavailable
        }

        // Extract SPIFFE ID from certificate's SAN URI
        let spiffeID = try extractSPIFFEID(from: certificatePEM)

        // Verify the trust domain matches
        guard spiffeID.trustDomain == config.trustDomain else {
            throw SPIREServiceError.certificateValidationFailed(
                "Trust domain mismatch: expected \(config.trustDomain), got \(spiffeID.trustDomain)"
            )
        }

        logger.debug("Certificate validated successfully", metadata: [
            "spiffeID": .string(spiffeID.uri)
        ])

        return spiffeID
    }

    /// Validate that a SPIFFE ID represents a valid agent
    /// - Parameter spiffeID: The SPIFFE identity to validate
    /// - Returns: The agent ID if valid
    public func validateAgentIdentity(_ spiffeID: SPIFFEIdentity) throws -> String {
        guard spiffeID.trustDomain == config.trustDomain else {
            throw SPIREServiceError.certificateValidationFailed(
                "Trust domain mismatch: expected \(config.trustDomain), got \(spiffeID.trustDomain)"
            )
        }

        guard spiffeID.isAgent else {
            throw SPIREServiceError.certificateValidationFailed(
                "SPIFFE ID is not an agent identity: \(spiffeID.uri)"
            )
        }

        guard let agentID = spiffeID.agentID, !agentID.isEmpty else {
            throw SPIREServiceError.certificateValidationFailed(
                "Invalid agent ID in SPIFFE ID: \(spiffeID.uri)"
            )
        }

        return agentID
    }

    // MARK: - Private Methods

    private func refreshTrustBundle() async throws {
        if let bundlePath = config.trustBundlePath {
            try await loadTrustBundleFromFile(bundlePath)
        } else if let bundleURL = config.bundleEndpointURL {
            try await fetchTrustBundleFromEndpoint(bundleURL)
        } else {
            logger.warning("No trust bundle source configured")
        }
    }

    private func loadTrustBundleFromFile(_ path: String) async throws {
        logger.debug("Loading trust bundle from file", metadata: ["path": .string(path)])

        guard FileManager.default.fileExists(atPath: path) else {
            throw SPIREServiceError.trustBundleUnavailable
        }

        let pem = try String(contentsOfFile: path, encoding: .utf8)
        let certificates = parsePEMCertificates(pem)

        guard !certificates.isEmpty else {
            throw SPIREServiceError.trustBundleUnavailable
        }

        let newSequence = (trustBundle?.sequenceNumber ?? 0) + 1
        trustBundle = SPIRETrustBundle(
            trustDomain: config.trustDomain,
            x509Authorities: certificates,
            sequenceNumber: newSequence
        )

        logger.info("Trust bundle loaded from file", metadata: [
            "certificateCount": .stringConvertible(certificates.count),
            "sequenceNumber": .stringConvertible(newSequence)
        ])
    }

    private func fetchTrustBundleFromEndpoint(_ urlString: String) async throws {
        logger.debug("Fetching trust bundle from endpoint", metadata: ["url": .string(urlString)])

        // Validate URL format
        guard urlString.hasPrefix("http://") || urlString.hasPrefix("https://") else {
            throw SPIREServiceError.serverConnectionFailed("Invalid bundle endpoint URL: must start with http:// or https://")
        }

        let url = URI(string: urlString)

        do {
            let response = try await httpClient.get(url)

            guard response.status == .ok else {
                throw SPIREServiceError.serverConnectionFailed("HTTP \(response.status.code)")
            }

            guard let body = response.body else {
                throw SPIREServiceError.serverConnectionFailed("Empty response body")
            }

            // Parse SPIFFE bundle format (JSON with x509_authorities)
            let bundleData = Data(buffer: body)
            let json = try JSONSerialization.jsonObject(with: bundleData) as? [String: Any]

            guard let keys = json?["keys"] as? [[String: Any]] else {
                throw SPIREServiceError.serverConnectionFailed("Invalid bundle format")
            }

            var certificates: [String] = []
            for key in keys {
                if let use = key["use"] as? String, use == "x509-svid",
                   let x5c = key["x5c"] as? [String] {
                    for cert in x5c {
                        // x5c contains base64-encoded DER certificates
                        let pem = "-----BEGIN CERTIFICATE-----\n\(cert)\n-----END CERTIFICATE-----"
                        certificates.append(pem)
                    }
                }
            }

            guard !certificates.isEmpty else {
                throw SPIREServiceError.trustBundleUnavailable
            }

            let newSequence = (trustBundle?.sequenceNumber ?? 0) + 1
            trustBundle = SPIRETrustBundle(
                trustDomain: config.trustDomain,
                x509Authorities: certificates,
                sequenceNumber: newSequence
            )

            logger.info("Trust bundle fetched from endpoint", metadata: [
                "certificateCount": .stringConvertible(certificates.count),
                "sequenceNumber": .stringConvertible(newSequence)
            ])
        } catch let error as SPIREServiceError {
            throw error
        } catch {
            throw SPIREServiceError.serverConnectionFailed(error.localizedDescription)
        }
    }

    private func startPeriodicRefresh() {
        refreshTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(config.bundleRefreshInterval))
                    try await refreshTrustBundle()
                } catch {
                    if !Task.isCancelled {
                        logger.error("Failed to refresh trust bundle: \(error)")
                    }
                }
            }
        }
    }

    private func extractSPIFFEID(from certificatePEM: String) throws -> SPIFFEIdentity {
        // This is a simplified extraction that looks for the SPIFFE ID in the certificate
        // In production, use a proper X.509 parser to extract from SAN URI extension

        // For now, attempt to parse from a comment or known location
        // The SPIFFE ID should be in the Subject Alternative Name (SAN) URI extension

        // Simplified: Look for spiffe:// URI pattern in the certificate
        // A proper implementation would use Security.framework (macOS) or OpenSSL

        // This is a placeholder - in production, integrate with swift-certificates or similar
        if let range = certificatePEM.range(of: "spiffe://[^\"\\s]+", options: .regularExpression) {
            let uriString = String(certificatePEM[range])
            if let spiffeID = SPIFFEIdentity(uri: uriString) {
                return spiffeID
            }
        }

        throw SPIREServiceError.spiffeIDExtractionFailed(
            "Could not find SPIFFE ID in certificate. Ensure the certificate contains a SAN URI extension with the SPIFFE ID."
        )
    }

    private func parsePEMCertificates(_ pem: String) -> [String] {
        var certificates: [String] = []
        var current = ""
        var inCertificate = false

        for line in pem.components(separatedBy: .newlines) {
            if line.contains("-----BEGIN CERTIFICATE-----") {
                inCertificate = true
                current = line + "\n"
            } else if line.contains("-----END CERTIFICATE-----") {
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

// MARK: - Vapor Application Extension

extension Application {
    private struct SPIREServiceKey: StorageKey {
        typealias Value = SPIREService
    }

    public var spireService: SPIREService? {
        get { storage[SPIREServiceKey.self] }
        set { storage[SPIREServiceKey.self] = newValue }
    }

    /// Configure SPIRE service
    public func configureSPIRE() async throws {
        let config = SPIREServiceConfig.fromEnvironment()

        guard config.enabled else {
            logger.info("SPIRE authentication is disabled")
            return
        }

        let service = SPIREService(
            config: config,
            logger: logger,
            httpClient: client
        )

        try await service.start()
        spireService = service

        logger.info("SPIRE service configured and started")
    }
}
