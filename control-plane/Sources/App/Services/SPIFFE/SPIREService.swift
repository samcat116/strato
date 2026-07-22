import Foundation
import Vapor
import Crypto
import X509

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

// MARK: - Validated identity

/// A SPIFFE identity that has been chain-verified against the roots of its own
/// trust domain, together with the organization that domain belongs to.
///
/// `organizationID` is nil for the platform trust domain — the domain the
/// control plane's own identities and every pre-per-org-TD agent live in. It is
/// a **registry lookup that scopes a Cedar principal, never an authorization
/// claim**: the trust domain says which org's CA vouched for the identity, and
/// the authorization decision is still Cedar's (`docs/architecture/iam.md`,
/// issue #491).
public struct ValidatedSPIFFEIdentity: Sendable, Equatable {
    public let identity: SPIFFEIdentity
    public let organizationID: UUID?

    public init(identity: SPIFFEIdentity, organizationID: UUID? = nil) {
        self.identity = identity
        self.organizationID = organizationID
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

    public init(
        enabled: Bool = false,
        trustDomain: String = "strato.local",
        bundleEndpointURL: String? = nil,
        trustBundlePath: String? = nil,
        bundleRefreshInterval: TimeInterval = 300
    ) {
        self.enabled = enabled
        self.trustDomain = trustDomain
        self.bundleEndpointURL = bundleEndpointURL
        self.trustBundlePath = trustBundlePath
        self.bundleRefreshInterval = bundleRefreshInterval
    }

    /// Load configuration from environment variables
    public static func fromEnvironment() -> SPIREServiceConfig {
        let enabled = Environment.get("SPIRE_ENABLED")?.lowercased() == "true"
        let trustDomain = Environment.get("SPIRE_TRUST_DOMAIN") ?? "strato.local"
        let bundleEndpointURL = Environment.get("SPIRE_BUNDLE_ENDPOINT_URL")
        let trustBundlePath = Environment.get("SPIRE_TRUST_BUNDLE_PATH")
        let bundleRefreshInterval = TimeInterval(Environment.get("SPIRE_BUNDLE_REFRESH_INTERVAL") ?? "300") ?? 300

        return SPIREServiceConfig(
            enabled: enabled,
            trustDomain: trustDomain,
            bundleEndpointURL: bundleEndpointURL,
            trustBundlePath: trustBundlePath,
            bundleRefreshInterval: bundleRefreshInterval
        )
    }
}

// MARK: - SPIRE Service

/// Service for managing SPIRE trust bundles and validating agent certificates
public actor SPIREService {
    private let config: SPIREServiceConfig
    private let logger: Logger
    private let httpClient: Client

    /// Trust bundles keyed by trust domain. The platform domain's entry comes
    /// from the configured file/endpoint; every other entry is an organization's
    /// domain, sourced from `org_trust_domains` (issue #613).
    ///
    /// Keyed rather than unioned on purpose: verifying a leaf against the union
    /// of every domain's roots would let any organization's CA mint an identity
    /// in any other organization's domain, which is precisely the isolation
    /// per-org trust domains exist to provide.
    private var trustBundles: [String: SPIRETrustBundle] = [:]

    /// Organization each non-platform trust domain resolves to.
    private var organizationsByTrustDomain: [String: UUID] = [:]

    private var refreshTask: Task<Void, Never>?

    /// Where org trust domains come from; nil in unit tests and whenever the
    /// feature is off, in which case only the platform domain exists.
    private let orgTrustDomainSource: OrgTrustDomainSource?

    /// When the org domains were last read, so a certificate naming an unknown
    /// domain can trigger at most one re-read per `orgRefreshCooldown` instead
    /// of a database query per request.
    private var orgTrustDomainsRefreshedAt: Date?
    private let orgRefreshCooldown: TimeInterval = 10

    public init(
        config: SPIREServiceConfig,
        logger: Logger,
        httpClient: Client,
        orgTrustDomainSource: OrgTrustDomainSource? = nil
    ) {
        self.config = config
        self.logger = logger
        self.httpClient = httpClient
        self.orgTrustDomainSource = orgTrustDomainSource
    }

    /// Start the SPIRE service
    public func start() async throws {
        guard config.enabled else {
            logger.info("SPIRE authentication is disabled")
            return
        }

        logger.info(
            "Starting SPIRE service",
            metadata: [
                "trustDomain": .string(config.trustDomain),
                "bundleEndpointURL": .string(config.bundleEndpointURL ?? "none"),
                "trustBundlePath": .string(config.trustBundlePath ?? "none"),
            ])

        // Load the initial trust bundle. A missing bundle at startup is
        // tolerated rather than fatal: in Kubernetes the bundle ConfigMap is
        // published by SPIRE's k8sbundle notifier only after the SPIRE server
        // is up, which may be after this pod starts. Until a refresh succeeds,
        // certificate re-verification stays off and the XFCC path relies on
        // Envoy's own mTLS verification alone.
        do {
            try await refreshTrustBundle()
        } catch {
            logger.warning(
                "SPIRE trust bundle not yet available; certificate re-verification is disabled until a periodic refresh succeeds: \(error)"
            )
        }

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

    /// The trust domain agents are expected to present identities from.
    public var trustDomain: String {
        config.trustDomain
    }

    /// The platform trust domain's bundle — the control plane's own domain.
    public func getTrustBundle() throws -> SPIRETrustBundle {
        guard let bundle = trustBundles[config.trustDomain] else {
            throw SPIREServiceError.trustBundleUnavailable
        }
        return bundle
    }

    /// Whether any trust bundle has been loaded and chain verification is
    /// possible. Callers use this to decide whether to re-verify a forwarded
    /// certificate at all; the per-domain root selection happens inside
    /// `validateCertificate`.
    public var hasTrustBundle: Bool {
        !trustBundles.isEmpty
    }

    /// The organization a trust domain belongs to, or nil for the platform
    /// domain (and for any domain not registered).
    public func organization(forTrustDomain trustDomain: String) -> UUID? {
        organizationsByTrustDomain[trustDomain]
    }

    /// Validate a client certificate (chain) and extract the SPIFFE ID.
    ///
    /// The PEM may contain the leaf alone or the leaf followed by intermediates
    /// (leaf first, as Envoy forwards them in the XFCC `Chain=` field).
    ///
    /// The leaf's SPIFFE ID is read from its SAN URI **before** verification,
    /// because the trust domain in that ID selects which roots the chain must
    /// verify against — and only those. A leaf claiming
    /// `spiffe://org-a…/agent/x` is verified against org A's roots alone, so
    /// org B's CA cannot mint an identity in org A's domain. Reading the SAN
    /// before verification is safe: it decides *which* roots to demand, and an
    /// attacker who lies about the domain only makes the chain check fail.
    /// - Parameter certificatePEM: The client certificate (chain) in PEM format
    /// - Returns: The validated identity and the organization its trust domain
    ///   scopes to (nil for the platform trust domain).
    public func validateCertificate(_ certificatePEM: String) async throws -> ValidatedSPIFFEIdentity {
        guard config.enabled else {
            throw SPIREServiceError.notConfigured
        }

        guard hasTrustBundle else {
            throw SPIREServiceError.trustBundleUnavailable
        }

        let pemBlocks = parsePEMCertificates(certificatePEM)
        guard let leafPEM = pemBlocks.first else {
            throw SPIREServiceError.invalidCertificate("No certificate found in PEM input")
        }

        let leaf: Certificate
        let intermediates: [Certificate]
        do {
            leaf = try Certificate(pemEncoded: leafPEM)
            intermediates = try pemBlocks.dropFirst().map { try Certificate(pemEncoded: $0) }
        } catch {
            throw SPIREServiceError.invalidCertificate("Failed to parse certificate: \(error)")
        }

        let claimedID = try extractSPIFFEID(from: leaf)

        guard let bundle = await bundle(forTrustDomain: claimedID.trustDomain) else {
            throw SPIREServiceError.certificateValidationFailed(
                "No trust bundle for trust domain \(claimedID.trustDomain)"
            )
        }

        let roots: [Certificate]
        do {
            roots = try bundle.x509Authorities.map { try Certificate(pemEncoded: $0) }
        } catch {
            throw SPIREServiceError.invalidCertificate("Failed to parse trust bundle: \(error)")
        }

        var verifier = Verifier(rootCertificates: CertificateStore(roots)) {
            RFC5280Policy()
        }
        let result = await verifier.validate(
            leaf: leaf, intermediates: CertificateStore(intermediates))

        guard case .validCertificate = result else {
            throw SPIREServiceError.certificateValidationFailed(
                "Certificate does not chain to the \(claimedID.trustDomain) trust bundle: \(result)"
            )
        }

        let organizationID = organizationsByTrustDomain[claimedID.trustDomain]

        logger.debug(
            "Certificate validated successfully",
            metadata: [
                "spiffeID": .string(claimedID.uri),
                "trustDomain": .string(claimedID.trustDomain),
                "organizationId": .string(organizationID?.uuidString ?? "platform"),
            ])

        return ValidatedSPIFFEIdentity(identity: claimedID, organizationID: organizationID)
    }

    /// Validate that a SPIFFE ID represents a valid agent
    /// - Parameter spiffeID: The SPIFFE identity to validate
    /// - Returns: The agent ID if valid
    public func validateAgentIdentity(_ spiffeID: SPIFFEIdentity) async throws -> String {
        // An agent may live in the platform trust domain (every agent, until
        // per-org domains are switched on) or in its organization's. Anything
        // else is a domain this control plane has no relationship with.
        guard await isKnownTrustDomain(spiffeID.trustDomain) else {
            throw SPIREServiceError.certificateValidationFailed(
                "Unknown trust domain: \(spiffeID.trustDomain)"
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

    /// Whether this control plane accepts identities from a trust domain at
    /// all: its own platform domain, or a registered organization's.
    private func isKnownTrustDomain(_ trustDomain: String) async -> Bool {
        if trustDomain == config.trustDomain { return true }
        if organizationsByTrustDomain[trustDomain] != nil { return true }
        await refreshOrgTrustDomainsIfStale()
        return organizationsByTrustDomain[trustDomain] != nil
    }

    /// Roots for a trust domain, re-reading the org registry once (subject to
    /// the cooldown) if the domain isn't cached — a freshly provisioned org's
    /// first agent must not have to wait out the bundle refresh interval.
    private func bundle(forTrustDomain trustDomain: String) async -> SPIRETrustBundle? {
        if let bundle = trustBundles[trustDomain] { return bundle }
        guard trustDomain != config.trustDomain else { return nil }
        await refreshOrgTrustDomainsIfStale()
        return trustBundles[trustDomain]
    }

    private func refreshOrgTrustDomainsIfStale() async {
        guard orgTrustDomainSource != nil else { return }
        if let refreshedAt = orgTrustDomainsRefreshedAt,
            Date().timeIntervalSince(refreshedAt) < orgRefreshCooldown
        {
            return
        }
        await refreshOrgTrustDomains()
    }

    private func refreshTrustBundle() async throws {
        // The org registry is refreshed first and independently: a failure to
        // load the platform bundle (its ConfigMap may not be published yet)
        // must not also strand every organization's roots, and vice versa.
        await refreshOrgTrustDomains()

        if let bundlePath = config.trustBundlePath {
            try await loadTrustBundleFromFile(bundlePath)
        } else if let bundleURL = config.bundleEndpointURL {
            try await fetchTrustBundleFromEndpoint(bundleURL)
        } else {
            logger.warning("No trust bundle source configured")
        }
    }

    /// Replace the cached org trust domains with what the registry currently
    /// holds. Domains that have gone away (org deleted, instance torn down)
    /// disappear from the map here, which is how identity acceptance is
    /// revoked. The platform domain's entry is never touched.
    private func refreshOrgTrustDomains() async {
        guard let source = orgTrustDomainSource else { return }

        let snapshots: [OrgTrustDomainSnapshot]
        do {
            snapshots = try await source.loadOrgTrustDomains()
        } catch {
            // Keep serving the domains we already know: a registry read failure
            // must not disconnect an organization's whole fleet.
            logger.error("Failed to refresh organization trust domains: \(error)")
            return
        }

        orgTrustDomainsRefreshedAt = Date()

        var organizations: [String: UUID] = [:]
        var refreshed: [String: SPIRETrustBundle] = [:]
        for snapshot in snapshots where snapshot.trustDomain != config.trustDomain {
            let authorities = parsePEMCertificates(snapshot.bundlePEM)
            guard !authorities.isEmpty else {
                logger.warning(
                    "Organization trust domain has an unparseable bundle; ignoring it",
                    metadata: ["trustDomain": .string(snapshot.trustDomain)])
                continue
            }
            organizations[snapshot.trustDomain] = snapshot.organizationID
            refreshed[snapshot.trustDomain] = SPIRETrustBundle(
                trustDomain: snapshot.trustDomain,
                x509Authorities: authorities,
                sequenceNumber: (trustBundles[snapshot.trustDomain]?.sequenceNumber ?? 0) + 1
            )
        }

        let platformBundle = trustBundles[config.trustDomain]
        trustBundles = refreshed
        trustBundles[config.trustDomain] = platformBundle
        organizationsByTrustDomain = organizations
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

        let newSequence = (trustBundles[config.trustDomain]?.sequenceNumber ?? 0) + 1
        trustBundles[config.trustDomain] = SPIRETrustBundle(
            trustDomain: config.trustDomain,
            x509Authorities: certificates,
            sequenceNumber: newSequence
        )

        logger.info(
            "Trust bundle loaded from file",
            metadata: [
                "certificateCount": .stringConvertible(certificates.count),
                "sequenceNumber": .stringConvertible(newSequence),
            ])
    }

    private func fetchTrustBundleFromEndpoint(_ urlString: String) async throws {
        logger.debug("Fetching trust bundle from endpoint", metadata: ["url": .string(urlString)])

        // Validate URL format
        guard urlString.hasPrefix("http://") || urlString.hasPrefix("https://") else {
            throw SPIREServiceError.serverConnectionFailed(
                "Invalid bundle endpoint URL: must start with http:// or https://")
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
                    let x5c = key["x5c"] as? [String]
                {
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

            let newSequence = (trustBundles[config.trustDomain]?.sequenceNumber ?? 0) + 1
            trustBundles[config.trustDomain] = SPIRETrustBundle(
                trustDomain: config.trustDomain,
                x509Authorities: certificates,
                sequenceNumber: newSequence
            )

            logger.info(
                "Trust bundle fetched from endpoint",
                metadata: [
                    "certificateCount": .stringConvertible(certificates.count),
                    "sequenceNumber": .stringConvertible(newSequence),
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

    private func extractSPIFFEID(from certificate: Certificate) throws -> SPIFFEIdentity {
        let san: SubjectAlternativeNames?
        do {
            san = try certificate.extensions.subjectAlternativeNames
        } catch {
            throw SPIREServiceError.spiffeIDExtractionFailed(
                "Failed to parse Subject Alternative Name extension: \(error)")
        }

        for name in san ?? SubjectAlternativeNames() {
            if case .uniformResourceIdentifier(let uri) = name,
                let spiffeID = SPIFFEIdentity(uri: uri)
            {
                return spiffeID
            }
        }

        throw SPIREServiceError.spiffeIDExtractionFailed(
            "Certificate has no SAN URI entry with a SPIFFE ID"
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
            httpClient: client,
            // Reads `org_trust_domains`, and returns nothing while the per-org
            // trust domain feature is off — so with the flag down the service
            // knows exactly one trust domain, as it always has.
            orgTrustDomainSource: DatabaseOrgTrustDomainSource(app: self)
        )

        try await service.start()
        spireService = service

        logger.info("SPIRE service configured and started")
    }
}
