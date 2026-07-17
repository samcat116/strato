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

                // Federated domain surfaced from the entry, state still unknown.
                #expect(body.federation.available == false)
                #expect(body.federation.domains.map(\.trustDomain) == ["spiffe://partner.example"])
                #expect(body.federation.domains.first?.state == "unknown")
            }
        }
    }
}
