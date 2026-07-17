import Fluent
import SPIREServerAPI
import Vapor

/// Read API backing the **Workload Identity** view (SPIFFE / SPIRE).
///
/// - `GET /api/workload-identity` — system administrators only. Returns the
///   trust domain's workload registration entries, attested-node summary, and
///   trust-bundle metadata as reported by the SPIRE server, plus placeholder
///   sections for federation and SVID issuance that have no data source yet.
///
/// The endpoint is intentionally read-only and degrades gracefully: when SPIRE
/// is not enabled it returns `enabled: false` with empty collections (a 200,
/// not an error) so the UI can render a clean "not configured" state, and a
/// transient SPIRE-server failure is surfaced as a `warning` rather than
/// failing the whole page.
struct WorkloadIdentityController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.grouped("api", "workload-identity").get(use: overview)
    }

    func overview(req: Request) async throws -> WorkloadIdentityResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }
        guard user.isSystemAdmin else {
            throw Abort(.forbidden, reason: "System administrator access required")
        }

        let spireService = req.application.spireService
        let registration = req.application.spireRegistrationService

        let spireEnabled = await spireService?.isEnabled ?? false
        let enabled = spireEnabled || registration != nil
        guard enabled else {
            return WorkloadIdentityResponse.disabled
        }

        // Trust bundle metadata (present only once a bundle has loaded).
        var trustBundle: TrustBundleResponse?
        if let spireService, await spireService.hasTrustBundle,
            let bundle = try? await spireService.getTrustBundle()
        {
            trustBundle = TrustBundleResponse(from: bundle)
        }

        // Trust domain, preferring whichever service can report it.
        let serviceTrustDomain = await spireService?.trustDomain
        let trustDomain =
            registration?.trustDomain ?? trustBundle?.trustDomain ?? serviceTrustDomain

        // Registration entries and attested nodes come from the SPIRE server's
        // read API. A failure here (server down, socket missing) should not
        // blank the page — surface it as a warning and render what we have.
        var entries: [RegistrationEntryResponse] = []
        var nodeAttestation: [NodeAttestationGroup] = []
        var warning: String?
        if let registration {
            do {
                entries = try await registration.listRegistrationEntries()
                    .map(RegistrationEntryResponse.init(from:))
            } catch {
                warning = "Could not list registration entries: \(error.localizedDescription)"
                req.logger.warning("Workload Identity: listing entries failed: \(error)")
            }
            do {
                nodeAttestation = Self.groupByAttestation(try await registration.listAttestedNodes())
            } catch {
                let message = "Could not list attested nodes: \(error.localizedDescription)"
                warning = warning.map { "\($0); \(message)" } ?? message
                req.logger.warning("Workload Identity: listing nodes failed: \(error)")
            }
        } else {
            // SPIRE is enabled (else `enabled` would be false above) but the
            // server registration API isn't configured, so entries and nodes
            // can't be read. Say so, rather than presenting an empty list as if
            // the trust domain had no registrations.
            warning =
                "SPIRE is enabled but the server registration API is not configured "
                + "(set SPIRE_SERVER_API_ADDRESS); registration entries and attested nodes are unavailable."
        }

        // Federation relationships come from SPIRE's trustdomain read API. When
        // it answers we report real relationships and sync state; if it fails,
        // degrade to the domains the entries themselves federate with (state
        // unknown) and surface a warning rather than blanking the panel.
        var federation = FederationResponse(available: false, domains: [])
        if let registration {
            do {
                let relationships = try await registration.listFederationRelationships()
                federation = FederationResponse(
                    available: true,
                    domains:
                        relationships
                        .sorted { $0.trustDomain < $1.trustDomain }
                        .map(FederatedDomainResponse.init(from:))
                )
            } catch {
                let message = "Could not list federation relationships: \(error.localizedDescription)"
                warning = warning.map { "\($0); \(message)" } ?? message
                req.logger.warning("Workload Identity: listing federation relationships failed: \(error)")
                let federatedDomains = Set(entries.flatMap(\.federatesWith)).sorted()
                federation = FederationResponse(
                    available: false,
                    domains: federatedDomains.map { FederatedDomainResponse(trustDomain: $0, state: "unknown") }
                )
            }
        }

        // SVID issuance counts come from an external metrics store (the control
        // plane is not in the signing path). Absent a configured provider the
        // panel stays unavailable; a query failure degrades the same way with a
        // warning rather than failing the page.
        var issuance = IssuanceResponse.unavailable
        if let metrics = req.application.spireIssuanceMetrics {
            do {
                let counts = try await metrics.issuanceCounts(client: req.client)
                issuance = IssuanceResponse(
                    available: true,
                    windowHours: counts.windowHours,
                    x509SVIDs: counts.x509SVIDs,
                    jwtSVIDs: counts.jwtSVIDs
                )
            } catch {
                let message = "Could not read SVID issuance metrics: \(error.localizedDescription)"
                warning = warning.map { "\($0); \(message)" } ?? message
                req.logger.warning("Workload Identity: reading issuance metrics failed: \(error)")
            }
        }

        return WorkloadIdentityResponse(
            enabled: true,
            trustDomain: trustDomain,
            entries: entries,
            nodeAttestation: nodeAttestation,
            trustBundle: trustBundle,
            federation: federation,
            issuance: issuance,
            warning: warning
        )
    }

    /// Collapse attested nodes into per-attestation-type counts for the
    /// "Node attestation" summary panel.
    private static func groupByAttestation(_ nodes: [SPIREAgent]) -> [NodeAttestationGroup] {
        var order: [String] = []
        var counts: [String: (total: Int, banned: Int)] = [:]
        for node in nodes {
            let type = node.attestationType.isEmpty ? "unknown" : node.attestationType
            if counts[type] == nil { order.append(type) }
            var tally = counts[type] ?? (0, 0)
            tally.total += 1
            if node.banned { tally.banned += 1 }
            counts[type] = tally
        }
        return order.map { type in
            let tally = counts[type] ?? (0, 0)
            return NodeAttestationGroup(attestationType: type, count: tally.total, banned: tally.banned)
        }
    }
}

// MARK: - DTOs

struct WorkloadIdentityResponse: Content {
    /// Whether SPIRE is configured on this control plane. When false, every
    /// collection is empty and the UI shows a "not configured" state.
    let enabled: Bool
    let trustDomain: String?
    let entries: [RegistrationEntryResponse]
    /// Attested nodes summarized by attestation method.
    let nodeAttestation: [NodeAttestationGroup]
    let trustBundle: TrustBundleResponse?
    let federation: FederationResponse
    let issuance: IssuanceResponse
    /// Non-fatal problem reaching the SPIRE server, if any.
    let warning: String?

    static let disabled = WorkloadIdentityResponse(
        enabled: false,
        trustDomain: nil,
        entries: [],
        nodeAttestation: [],
        trustBundle: nil,
        federation: FederationResponse(available: false, domains: []),
        issuance: .unavailable,
        warning: nil
    )
}

struct RegistrationEntryResponse: Content {
    let id: String
    /// Full identity, e.g. `spiffe://strato.prod/db/primary`.
    let spiffeID: String
    /// Path portion after the trust domain, e.g. `/db/primary`.
    let path: String
    /// Parent identity (SPIRE server for node entries, or a node ID).
    let parentID: String
    /// Short node name derived from `parentID` (e.g. `agent-1`), best-effort.
    let node: String?
    /// Selectors formatted as `type:value`.
    let selectors: [String]
    /// SVID kinds this entry issues: always `x509`, plus `jwt` when a JWT TTL is set.
    let svidTypes: [String]
    let x509TTLSeconds: Int
    let jwtTTLSeconds: Int
    let federatesWith: [String]
    let admin: Bool
    let downstream: Bool
    let hint: String?
    let expiresAt: Date?
    let createdAt: Date?

    init(from entry: SPIREEntry) {
        self.id = entry.id
        self.spiffeID = entry.spiffeID
        self.path = Self.path(from: entry.spiffeID)
        self.parentID = entry.parentID
        self.node = Self.shortNode(from: entry.parentID)
        self.selectors = entry.selectors.map { "\($0.type):\($0.value)" }
        // SPIRE issues both X.509-SVIDs and JWT-SVIDs for every registration
        // entry; the TTL fields only tune lifetimes. A `jwtSVIDTTLSeconds` of 0
        // means "use the server's default JWT-SVID TTL", not "no JWT-SVID", so
        // JWT capability must not be gated on a non-zero override.
        self.svidTypes = ["x509", "jwt"]
        self.x509TTLSeconds = Int(entry.x509SVIDTTLSeconds)
        self.jwtTTLSeconds = Int(entry.jwtSVIDTTLSeconds)
        self.federatesWith = entry.federatesWith
        self.admin = entry.admin
        self.downstream = entry.downstream
        self.hint = entry.hint.isEmpty ? nil : entry.hint
        self.expiresAt = entry.expiresAt
        self.createdAt = entry.createdAt
    }

    /// The path portion of a `spiffe://<trust-domain><path>` identity.
    private static func path(from spiffeID: String) -> String {
        guard let range = spiffeID.range(of: "spiffe://") else { return spiffeID }
        let afterScheme = spiffeID[range.upperBound...]
        guard let slash = afterScheme.firstIndex(of: "/") else { return "" }
        return String(afterScheme[slash...])
    }

    /// Best-effort short node label from a parent SPIFFE ID: the segment after
    /// `/node/` (our provisioned node IDs), else the last path segment.
    private static func shortNode(from parentID: String) -> String? {
        guard !parentID.isEmpty else { return nil }
        let path = Self.path(from: parentID)
        if let nodeRange = path.range(of: "/node/") {
            let name = String(path[nodeRange.upperBound...])
            return name.isEmpty ? nil : name
        }
        let segments = path.split(separator: "/")
        return segments.last.map(String.init)
    }
}

struct NodeAttestationGroup: Content {
    let attestationType: String
    let count: Int
    let banned: Int
}

struct TrustBundleResponse: Content {
    let trustDomain: String
    let x509AuthorityCount: Int
    let refreshedAt: Date
    let sequenceNumber: UInt64

    init(from bundle: SPIRETrustBundle) {
        self.trustDomain = bundle.trustDomain
        self.x509AuthorityCount = bundle.x509Authorities.count
        self.refreshedAt = bundle.refreshedAt
        self.sequenceNumber = bundle.sequenceNumber
    }
}

/// Federation relationships. When `available` is true, `domains` are the trust
/// domain's configured federation relationships with real sync state read from
/// SPIRE; when false (unconfigured, or the trustdomain API could not be
/// reached), `domains` degrades to the trust domains entries federate with,
/// with `state: unknown`.
struct FederationResponse: Content {
    let available: Bool
    let domains: [FederatedDomainResponse]
}

struct FederatedDomainResponse: Content {
    let trustDomain: String
    /// `synced` | `refresh_failed` | `unknown`.
    let state: String
}

extension FederatedDomainResponse {
    /// Project a real federation relationship. SPIRE exposes no explicit
    /// per-relationship health field, so sync state is inferred from whether it
    /// currently holds the peer bundle: SPIRE stores a bundle only after a
    /// successful fetch (or an explicit bootstrap), so a populated bundle means
    /// `synced`, and its absence means a pending or failed refresh.
    init(from relationship: SPIREFederationRelationship) {
        self.trustDomain = relationship.trustDomain
        self.state = relationship.bundleX509AuthorityCount > 0 ? "synced" : "refresh_failed"
    }
}

/// SVID issuance metrics. Placeholder until issuance telemetry is collected;
/// `available` is false and counts are nil in that case.
struct IssuanceResponse: Content {
    let available: Bool
    let windowHours: Int
    let x509SVIDs: Int?
    let jwtSVIDs: Int?

    static let unavailable = IssuanceResponse(
        available: false, windowHours: 24, x509SVIDs: nil, jwtSVIDs: nil)
}
