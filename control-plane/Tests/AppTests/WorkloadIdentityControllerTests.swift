import Fluent
import Foundation
import SPIREServerAPI
import Testing
import Vapor
import VaporTesting

@testable import App

/// Tests for the read-only Workload Identity (SPIFFE / SPIRE) API:
/// system-admin gating, the graceful "not configured" state, and the shape of
/// the entries / node-attestation / federation projections when a SPIRE
/// registration service is present.
@Suite("Workload Identity Controller Tests")
final class WorkloadIdentityControllerTests: BaseTestCase {

    private func makeAdmin(on db: Database) async throws -> String {
        let admin = User(
            username: "wi-admin",
            email: "wi-admin@example.com",
            displayName: "WI Admin",
            isSystemAdmin: true
        )
        try await admin.save(on: db)
        return try await admin.generateAPIKey(on: db)
    }

    private func makeNonAdmin(on db: Database) async throws -> String {
        let user = User(
            username: "wi-user",
            email: "wi-user@example.com",
            displayName: "WI User",
            isSystemAdmin: false
        )
        try await user.save(on: db)
        return try await user.generateAPIKey(on: db)
    }

    private func installFakeSPIRE(on app: Application, fake: FakeSPIREServerAPI) {
        app.spireRegistrationService = SPIRERegistrationService(
            api: fake,
            config: SPIRERegistrationConfig(
                trustDomain: "strato.test",
                serverAPIAddress: .tcp(host: "127.0.0.1", port: 1),
                serverPublicAddress: "spire.example.com:8085",
                agentSelectors: [SPIRESelector(type: "unix", value: "uid:0")],
                svidTTLSeconds: 1800
            ),
            logger: app.logger
        )
    }

    // MARK: - Authorization

    @Test("Non-admins are forbidden")
    func nonAdminForbidden() async throws {
        try await withApp { app in
            let token = try await makeNonAdmin(on: app.db)
            try await app.test(.GET, "/api/workload-identity") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test("Unauthenticated requests are rejected")
    func unauthenticatedRejected() async throws {
        try await withApp { app in
            try await app.test(.GET, "/api/workload-identity") { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    // MARK: - Disabled state

    @Test("Reports not-enabled with empty collections when SPIRE is unconfigured")
    func disabledWhenUnconfigured() async throws {
        try await withApp { app in
            let token = try await makeAdmin(on: app.db)
            try await app.test(.GET, "/api/workload-identity") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let body = try res.content.decode(WorkloadIdentityResponse.self)
                #expect(body.enabled == false)
                #expect(body.entries.isEmpty)
                #expect(body.nodeAttestation.isEmpty)
                #expect(body.trustBundle == nil)
                #expect(body.federation.available == false)
                #expect(body.issuance.available == false)
            }
        }
    }

    @Test("Warns when SPIRE is enabled but the registration API is unconfigured")
    func warnsWhenRegistrationAPIMissing() async throws {
        try await withApp { app in
            let token = try await makeAdmin(on: app.db)
            // SPIRE is enabled, but no registration service (no
            // SPIRE_SERVER_API_ADDRESS), so entries/nodes can't be read.
            app.spireService = SPIREService(
                config: SPIREServiceConfig(enabled: true, trustDomain: "strato.test"),
                logger: app.logger,
                httpClient: app.client
            )

            try await app.test(.GET, "/api/workload-identity") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let body = try res.content.decode(WorkloadIdentityResponse.self)
                #expect(body.enabled == true)
                #expect(body.trustDomain == "strato.test")
                #expect(body.entries.isEmpty)
                #expect(body.nodeAttestation.isEmpty)
                #expect(body.warning != nil)
            }
        }
    }

    // MARK: - Populated state

    @Test("Projects SPIRE entries, node attestation, and federated domains")
    func projectsSPIREData() async throws {
        try await withApp { app in
            let token = try await makeAdmin(on: app.db)
            let fake = FakeSPIREServerAPI()
            await fake.setEntries([
                SPIREEntry(
                    id: "e1",
                    spiffeID: "spiffe://strato.test/db/primary",
                    parentID: "spiffe://strato.test/node/agent-1",
                    selectors: [SPIRESelector(type: "unix", value: "uid:1000")],
                    x509SVIDTTLSeconds: 3600,
                    jwtSVIDTTLSeconds: 0,
                    federatesWith: ["spiffe://partner.example"],
                    admin: false,
                    downstream: false,
                    hint: "",
                    expiresAt: nil,
                    createdAt: nil
                ),
                SPIREEntry(
                    id: "e2",
                    spiffeID: "spiffe://strato.test/web/frontend",
                    parentID: "spiffe://strato.test/node/agent-2",
                    selectors: [SPIRESelector(type: "docker", value: "label:app=web")],
                    x509SVIDTTLSeconds: 1800,
                    jwtSVIDTTLSeconds: 300,
                    federatesWith: [],
                    admin: false,
                    downstream: false,
                    hint: "",
                    expiresAt: nil,
                    createdAt: nil
                ),
            ])
            await fake.setAgents([
                SPIREAgent(
                    spiffeID: "spiffe://strato.test/node/agent-1",
                    attestationType: "join_token",
                    x509SVIDSerialNumber: "1",
                    x509SVIDExpiresAt: nil,
                    selectors: [],
                    banned: false,
                    canReattest: true,
                    agentVersion: "1.9.0"
                ),
                SPIREAgent(
                    spiffeID: "spiffe://strato.test/node/agent-2",
                    attestationType: "join_token",
                    x509SVIDSerialNumber: "2",
                    x509SVIDExpiresAt: nil,
                    selectors: [],
                    banned: true,
                    canReattest: true,
                    agentVersion: "1.9.0"
                ),
            ])
            await fake.setFederationRelationships([
                // Holds a peer bundle → synced.
                SPIREFederationRelationship(
                    trustDomain: "partner.example",
                    bundleEndpointURL: "https://partner.example/bundle",
                    bundleEndpointProfile: "https_spiffe",
                    endpointSPIFFEID: "spiffe://partner.example/spire/server",
                    bundleX509AuthorityCount: 2,
                    bundleSequenceNumber: 7
                ),
                // No bundle fetched yet → refresh_failed.
                SPIREFederationRelationship(
                    trustDomain: "pending.example",
                    bundleEndpointURL: "https://pending.example/bundle",
                    bundleEndpointProfile: "https_web",
                    endpointSPIFFEID: nil,
                    bundleX509AuthorityCount: 0,
                    bundleSequenceNumber: 0
                ),
            ])
            installFakeSPIRE(on: app, fake: fake)

            try await app.test(.GET, "/api/workload-identity") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let body = try res.content.decode(WorkloadIdentityResponse.self)
                #expect(body.enabled == true)
                #expect(body.trustDomain == "strato.test")
                #expect(body.entries.count == 2)

                let primary = try #require(body.entries.first { $0.id == "e1" })
                #expect(primary.path == "/db/primary")
                #expect(primary.node == "agent-1")
                #expect(primary.selectors == ["unix:uid:1000"])
                // Every entry issues both X.509 and JWT SVIDs, regardless of a
                // custom JWT TTL override (e1 has none, e2 does).
                #expect(primary.svidTypes == ["x509", "jwt"])

                let frontend = try #require(body.entries.first { $0.id == "e2" })
                #expect(frontend.svidTypes == ["x509", "jwt"])
                #expect(frontend.jwtTTLSeconds == 300)

                // Both nodes attested via join_token → one group of two, one banned.
                #expect(body.nodeAttestation.count == 1)
                let group = try #require(body.nodeAttestation.first)
                #expect(group.attestationType == "join_token")
                #expect(group.count == 2)
                #expect(group.banned == 1)

                // Real federation relationships from SPIRE's trustdomain API,
                // sorted by trust domain, with sync state from bundle presence.
                #expect(body.federation.available == true)
                #expect(body.federation.domains.map(\.trustDomain) == ["partner.example", "pending.example"])
                let synced = try #require(body.federation.domains.first { $0.trustDomain == "partner.example" })
                #expect(synced.state == "synced")
                let pending = try #require(body.federation.domains.first { $0.trustDomain == "pending.example" })
                #expect(pending.state == "refresh_failed")

                // No issuance-metrics provider installed → panel unavailable.
                #expect(body.issuance.available == false)
            }
        }
    }

    // MARK: - Federation degrade

    @Test("Degrades to entry-derived domains when the federation API fails")
    func federationDegradesOnFailure() async throws {
        try await withApp { app in
            let token = try await makeAdmin(on: app.db)
            let fake = FakeSPIREServerAPI()
            await fake.setEntries([
                SPIREEntry(
                    id: "e1",
                    spiffeID: "spiffe://strato.test/db/primary",
                    parentID: "spiffe://strato.test/node/agent-1",
                    selectors: [SPIRESelector(type: "unix", value: "uid:1000")],
                    x509SVIDTTLSeconds: 3600,
                    jwtSVIDTTLSeconds: 0,
                    federatesWith: ["spiffe://partner.example"],
                    admin: false,
                    downstream: false,
                    hint: "",
                    expiresAt: nil,
                    createdAt: nil
                )
            ])
            await fake.setFailFederation(true)
            installFakeSPIRE(on: app, fake: fake)

            try await app.test(.GET, "/api/workload-identity") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let body = try res.content.decode(WorkloadIdentityResponse.self)
                // Falls back to entry-derived domains (normalized to bare trust
                // domain names) with unknown state.
                #expect(body.federation.available == false)
                #expect(body.federation.domains.map(\.trustDomain) == ["partner.example"])
                #expect(body.federation.domains.first?.state == "unknown")
                #expect(body.warning?.contains("federation relationships") == true)
            }
        }
    }

    @Test("Merges static (entry-derived) federation domains the API omits")
    func mergesStaticFederationDomains() async throws {
        try await withApp { app in
            let token = try await makeAdmin(on: app.db)
            let fake = FakeSPIREServerAPI()
            // An entry federates with two domains; only one has a dynamic
            // relationship in the trustdomain API. The other is a static
            // (server.conf `federates_with`) relationship the API never returns.
            await fake.setEntries([
                SPIREEntry(
                    id: "e1",
                    spiffeID: "spiffe://strato.test/db/primary",
                    parentID: "spiffe://strato.test/node/agent-1",
                    selectors: [SPIRESelector(type: "unix", value: "uid:1000")],
                    x509SVIDTTLSeconds: 3600,
                    jwtSVIDTTLSeconds: 0,
                    federatesWith: ["spiffe://dynamic.example", "spiffe://static.example"],
                    admin: false,
                    downstream: false,
                    hint: "",
                    expiresAt: nil,
                    createdAt: nil
                )
            ])
            await fake.setFederationRelationships([
                SPIREFederationRelationship(
                    trustDomain: "dynamic.example",
                    bundleEndpointURL: "https://dynamic.example/bundle",
                    bundleEndpointProfile: "https_spiffe",
                    endpointSPIFFEID: "spiffe://dynamic.example/spire/server",
                    bundleX509AuthorityCount: 1,
                    bundleSequenceNumber: 3
                )
            ])
            installFakeSPIRE(on: app, fake: fake)

            try await app.test(.GET, "/api/workload-identity") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let body = try res.content.decode(WorkloadIdentityResponse.self)
                #expect(body.federation.available == true)
                // Both domains appear: the dynamic one with real state, the
                // static one (API-omitted) supplemented with unknown state.
                #expect(body.federation.domains.map(\.trustDomain) == ["dynamic.example", "static.example"])
                let dynamic = try #require(body.federation.domains.first { $0.trustDomain == "dynamic.example" })
                #expect(dynamic.state == "synced")
                let staticDomain = try #require(body.federation.domains.first { $0.trustDomain == "static.example" })
                #expect(staticDomain.state == "unknown")
            }
        }
    }

    @Test("Treats a JWT-only peer bundle as synced")
    func jwtOnlyBundleIsSynced() async throws {
        try await withApp { app in
            let token = try await makeAdmin(on: app.db)
            let fake = FakeSPIREServerAPI()
            await fake.setFederationRelationships([
                // A JWT-only trust domain: a valid, synced bundle with zero
                // X.509 authorities.
                SPIREFederationRelationship(
                    trustDomain: "jwt.example",
                    bundleEndpointURL: "https://jwt.example/bundle",
                    bundleEndpointProfile: "https_spiffe",
                    endpointSPIFFEID: "spiffe://jwt.example/spire/server",
                    bundleX509AuthorityCount: 0,
                    bundleJWTAuthorityCount: 2,
                    bundleSequenceNumber: 4
                )
            ])
            installFakeSPIRE(on: app, fake: fake)

            try await app.test(.GET, "/api/workload-identity") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let body = try res.content.decode(WorkloadIdentityResponse.self)
                let domain = try #require(body.federation.domains.first { $0.trustDomain == "jwt.example" })
                #expect(domain.state == "synced")
            }
        }
    }

    // MARK: - Issuance

    @Test("Projects SVID issuance counts from the metrics provider")
    func projectsIssuanceMetrics() async throws {
        try await withApp { app in
            let token = try await makeAdmin(on: app.db)
            installFakeSPIRE(on: app, fake: FakeSPIREServerAPI())
            app.spireIssuanceMetrics = FakeIssuanceMetricsProvider(
                counts: SPIREIssuanceCounts(windowHours: 24, x509SVIDs: 1280, jwtSVIDs: 96))

            try await app.test(.GET, "/api/workload-identity") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let body = try res.content.decode(WorkloadIdentityResponse.self)
                #expect(body.issuance.available == true)
                #expect(body.issuance.windowHours == 24)
                #expect(body.issuance.x509SVIDs == 1280)
                #expect(body.issuance.jwtSVIDs == 96)
            }
        }
    }

    @Test("Issuance stays unavailable and warns when the metrics provider fails")
    func issuanceDegradesOnFailure() async throws {
        try await withApp { app in
            let token = try await makeAdmin(on: app.db)
            installFakeSPIRE(on: app, fake: FakeSPIREServerAPI())
            app.spireIssuanceMetrics = FakeIssuanceMetricsProvider(counts: nil)

            try await app.test(.GET, "/api/workload-identity") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let body = try res.content.decode(WorkloadIdentityResponse.self)
                #expect(body.issuance.available == false)
                #expect(body.warning?.contains("issuance metrics") == true)
            }
        }
    }
}

/// In-memory issuance-metrics provider: returns canned counts, or throws when
/// `counts` is nil to exercise the graceful-degrade path.
private struct FakeIssuanceMetricsProvider: SPIREIssuanceMetricsProvider {
    let counts: SPIREIssuanceCounts?

    func issuanceCounts(client: any Client) async throws -> SPIREIssuanceCounts {
        guard let counts else {
            throw SPIREIssuanceMetricsError.unreachable("fake: Prometheus down")
        }
        return counts
    }
}
