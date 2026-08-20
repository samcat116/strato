import Fluent
import Foundation
import SPIREServerAPI
import StratoShared
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

/// Tests for organization-scoped infrastructure: agents, sites, and
/// enrollments carry a mandatory org-or-OU owner. Covers scope stamping at
/// registration (and its refusal/durability rules), the persisted
/// agent/site parentage the Cedar hierarchy is built from, the org-delegated
/// enrollment API, and the system-admin reassignment endpoint.
@Suite("Agent Organization Scope Tests", .serialized)
final class AgentOrganizationScopeTests {

    private func withScopedApp(
        _ test: (Application, Organization) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "Scope Org")

            try await test(app, org)

        } catch {
            try await app.shutdownForTesting()
            throw error
        }

        try await app.shutdownForTesting()
    }

    /// Enrolling a node *is* SPIRE provisioning, so every test that drives the
    /// enrollment API needs a SPIRE registration service — without one the
    /// endpoint refuses with 503 before reaching the behavior under test.
    private func installFakeSPIRE(on app: Application) {
        app.spireRegistrationService = SPIRERegistrationService(
            api: FakeSPIREServerAPI(),
            config: SPIRERegistrationConfig(
                trustDomain: "strato.local",
                serverAPIAddress: .tcp(host: "127.0.0.1", port: 1),
                serverPublicAddress: "spire.example.com:8085",
                agentSelectors: [SPIRESelector(type: "unix", value: "uid:0")],
                svidTTLSeconds: 1800
            ),
            logger: app.logger)
    }

    /// An enrollment row as the operator's `POST /api/agent-enrollments` would
    /// have left it — the sole carrier of a new agent's scope and site.
    private func makeEnrollment(
        agentName: String,
        siteID: UUID? = nil,
        organizationScope: OrganizationScope? = nil
    ) -> TestAgentEnrollment {
        TestAgentEnrollment(
            agentName: agentName,
            spiffeID: "spiffe://strato.local/agent/\(agentName)",
            expirationHours: 1,
            siteID: siteID,
            organizationScope: organizationScope)
    }

    private func makeRegisterMessage(agentName: String) -> AgentRegisterMessage {
        AgentRegisterMessage(
            agentId: agentName,
            hostname: "host-\(agentName)",
            version: "1.0.0",
            resources: AgentResources(
                totalCPU: 16, availableCPU: 16,
                totalMemory: 1 << 34, availableMemory: 1 << 34,
                totalDisk: 1 << 40, availableDisk: 1 << 40
            ),
            protocolVersion: WireProtocol.currentVersion
        )
    }

    /// Registration now requires a site. Tests concerned with organization
    /// behavior use a scope-local site unless they explicitly supply one.
    private func registerAgent(
        on app: Application,
        agentName: String,
        siteID: UUID? = nil,
        organizationScope: OrganizationScope? = nil
    ) async throws -> UUID {
        var resolvedSiteID = siteID
        if resolvedSiteID == nil, let organizationScope {
            let existing: Site?
            if let organizationID = organizationScope.organizationID {
                existing = try await LegacySiteStore.sites(
                    organizationID: organizationID,
                    on: app.db
                ).first
            } else if let organizationalUnitID = organizationScope.organizationalUnitID {
                existing = try await LegacySiteStore.sites(
                    organizationalUnitID: organizationalUnitID,
                    on: app.db
                ).first
            } else {
                existing = nil
            }
            if let existing {
                resolvedSiteID = try existing.requireID()
            } else {
                let site = Site(
                    name: "scope-site-\(UUID().uuidString.prefix(8))",
                    organizationScope: organizationScope)
                try await site.save(on: app.db)
                resolvedSiteID = try site.requireID()
            }
        }
        return try await app.agentService.registerAgent(
            makeRegisterMessage(agentName: agentName),
            agentName: agentName,
            siteID: resolvedSiteID,
            organizationScope: organizationScope)
    }

    // MARK: - Registration scope stamping

    @Test("Registration stamps the caller-supplied org scope")
    func registrationStampsScope() async throws {
        try await withScopedApp { app, org in
            let agentUUID = try await self.registerAgent(
                on: app, agentName: "scoped-agent",
                organizationScope: .organization(org.id!))

            let agent = try #require(try await Agent.find(agentUUID, on: app.db))
            #expect(agent.organizationID == org.id)
            #expect(agent.organizationalUnitID == nil)
        }
    }

    @Test("A brand-new agent with no organization scope is refused")
    func newAgentWithoutScopeRefused() async throws {
        try await withScopedApp { app, _ in
            await #expect(throws: AgentServiceError.self) {
                _ = try await self.registerAgent(on: app, agentName: "unowned-agent")
            }
            let count = try await Agent.count(on: app.db)
            #expect(count == 0)
        }
    }

    @Test("A brand-new agent takes its scope and site from its enrollment row")
    func newAgentReadsEnrollmentScopeAndSite() async throws {
        try await withScopedApp { app, org in
            // An SVID authenticates the node's identity but carries neither the
            // owning org nor the site: the enrollment an operator created for
            // this name is the only source of both, and the WebSocket controller
            // passes neither parameter.
            let site = Site(name: "enroll-dc", organizationScope: .organization(org.id!))
            try await site.save(on: app.db)
            let enrollment = self.makeEnrollment(
                agentName: "mtls-node", siteID: site.id,
                organizationScope: .organization(org.id!))
            _ = try await saveTestAgentEnrollment(enrollment, on: app.db)

            let agentUUID = try await self.registerAgent(on: app, agentName: "mtls-node")

            let agent = try #require(try await Agent.find(agentUUID, on: app.db))
            #expect(agent.organizationID == org.id)
            #expect(agent.siteID == site.id)

            // The enrollment is marked redeemed but survives: scope stays
            // readable, and unlike a single-use token it is not consumed.
            let reloaded = try #require(
                try await findTestAgentEnrollment(enrollment.id, on: app.db)
            )
            #expect(reloaded.isUsed == true)
        }
    }

    @Test("Reconnecting without a scope preserves the org assignment")
    func reconnectPreservesScope() async throws {
        try await withScopedApp { app, org in
            let agentUUID = try await self.registerAgent(
                on: app, agentName: "sticky-agent",
                organizationScope: .organization(org.id!))

            // Every reconnect passes no scope; nil must not clear.
            _ = try await self.registerAgent(on: app, agentName: "sticky-agent")

            let agent = try #require(try await Agent.find(agentUUID, on: app.db))
            #expect(agent.organizationID == org.id)
        }
    }

    @Test("An existing agent does not re-read its enrollment on reconnect")
    func existingAgentIgnoresEnrollmentOnReconnect() async throws {
        try await withScopedApp { app, org in
            let builder = TestDataBuilder(db: app.db)
            let otherOrg = try await builder.createOrganization(name: "Enrollment Drift Org")

            let agentUUID = try await self.registerAgent(
                on: app, agentName: "durable-agent",
                organizationScope: .organization(org.id!))
            let site = Site(name: "drift-dc", organizationScope: .organization(org.id!))
            try await site.save(on: app.db)
            let agent = try #require(try await Agent.find(agentUUID, on: app.db))
            try await agent.replacing(siteID: try site.requireID()).save(on: app.db)

            // A stale enrollment naming a different org and no site. Both values
            // are durable on the agent row, and re-reading the enrollment on
            // every reconnect would fight an operator who has since moved the
            // agent — so the enrollment is deliberately not consulted again.
            let enrollment = self.makeEnrollment(
                agentName: "durable-agent", organizationScope: .organization(otherOrg.id!))
            _ = try await saveTestAgentEnrollment(enrollment, on: app.db)

            _ = try await self.registerAgent(on: app, agentName: "durable-agent")

            let reloaded = try #require(try await Agent.find(agentUUID, on: app.db))
            #expect(reloaded.organizationID == org.id)
            #expect(reloaded.siteID == site.id)
        }
    }

    @Test("An org change is refused while the agent hosts VMs")
    func orgChangeRefusedWhileHostingVMs() async throws {
        try await withScopedApp { app, org in
            let builder = TestDataBuilder(db: app.db)
            let otherOrg = try await builder.createOrganization(name: "Other Org")
            let project = try await builder.createProject(
                name: "Scope Project", description: "p", organization: org)

            let agentUUID = try await self.registerAgent(
                on: app, agentName: "loaded-agent",
                organizationScope: .organization(org.id!))

            var vm = try await builder.createVM(name: "resident", project: project)
            vm.hypervisorId = agentUUID.uuidString
            try await vm.save(on: app.db)

            // Refused (logged, not fatal): the agent keeps its original org.
            _ = try await self.registerAgent(
                on: app, agentName: "loaded-agent",
                organizationScope: .organization(otherOrg.id!))

            let agent = try #require(try await Agent.find(agentUUID, on: app.db))
            #expect(agent.organizationID == org.id)
        }
    }

    @Test("A site assignment in a different org than the agent is ignored")
    func crossOrgSiteAssignmentIgnored() async throws {
        try await withScopedApp { app, org in
            let builder = TestDataBuilder(db: app.db)
            let otherOrg = try await builder.createOrganization(name: "Foreign Org")
            let foreignSite = Site(name: "foreign-dc", organizationScope: .organization(otherOrg.id!))
            try await foreignSite.save(on: app.db)

            let agentUUID = try await self.registerAgent(
                on: app, agentName: "cross-org-agent",
                organizationScope: .organization(org.id!))
            let originalAgent = try #require(try await Agent.find(agentUUID, on: app.db))
            let originalSiteID = originalAgent.siteID
            _ = try await self.registerAgent(
                on: app, agentName: "cross-org-agent",
                siteID: foreignSite.id,
                organizationScope: .organization(org.id!))

            let agent = try #require(try await Agent.find(agentUUID, on: app.db))
            #expect(agent.siteID == originalSiteID)
            #expect(agent.organizationID == org.id)

            // Sibling-OU delegation within one org is refused the same way:
            // an OU-B site must not admit an OU-A agent (root org matches).
            let ouA = OrganizationalUnit(
                name: "Member OU A", description: "a", organizationID: org.id!,
                path: "/\(org.id!.uuidString)", depth: 1)
            try await ouA.save(on: app.db)
            let ouB = OrganizationalUnit(
                name: "Member OU B", description: "b", organizationID: org.id!,
                path: "/\(org.id!.uuidString)", depth: 1)
            try await ouB.save(on: app.db)
            let ouBSite = Site(name: "ou-b-dc", organizationScope: .organizationalUnit(ouB.id!))
            try await ouBSite.save(on: app.db)

            let ouAgentUUID = try await self.registerAgent(
                on: app, agentName: "ou-a-agent",
                organizationScope: .organizationalUnit(ouA.id!))
            let originalOUAgent = try #require(try await Agent.find(ouAgentUUID, on: app.db))
            let originalOUSiteID = originalOUAgent.siteID
            _ = try await self.registerAgent(
                on: app, agentName: "ou-a-agent",
                siteID: ouBSite.id,
                organizationScope: .organizationalUnit(ouA.id!))
            let ouAgent = try #require(try await Agent.find(ouAgentUUID, on: app.db))
            #expect(ouAgent.siteID == originalOUSiteID)
        }
    }

    // MARK: - Enrollment API

    @Test("Creating an enrollment requires an organization scope")
    func enrollmentCreationRequiresScope() async throws {
        try await withScopedApp { app, org in
            self.installFakeSPIRE(on: app)
            let builder = TestDataBuilder(db: app.db)
            let admin = try await builder.createUser(
                username: "scope-admin", email: "scope-admin@example.com",
                displayName: "Scope Admin", isSystemAdmin: true)
            let token = try await admin.generateAPIKey(on: app)

            struct Body: Content {
                let agentName: String
                var organizationId: UUID? = nil
                var siteId: UUID? = nil
            }

            // A site the org owns, so the otherwise-valid case below can join
            // it (enrollment now requires a site).
            let site = Site(name: "scope-dc", organizationScope: .organization(org.id!))
            try await site.save(on: app.db)

            try await app.test(.POST, "/api/agent-enrollments") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(Body(agentName: "node-x", siteId: site.id))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            try await app.test(.POST, "/api/agent-enrollments") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(Body(agentName: "node-x", organizationId: org.id, siteId: site.id))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let created = try res.content.decode(AgentEnrollmentResponse.self)
                #expect(created.agentName == "node-x")
            }

            let row = try #require(
                try await findTestAgentEnrollment(agentName: "node-x", on: app.db)
            )
            #expect(row.organizationID == org.id)
        }
    }

    @Test("A non-admin without manage_agents cannot create or list enrollments")
    func enrollmentCreationDeniedWithoutManageAgents() async throws {
        try await withScopedApp { app, org in
            self.installFakeSPIRE(on: app)
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "scope-pleb", email: "scope-pleb@example.com",
                displayName: "Pleb", isSystemAdmin: false)
            let token = try await user.generateAPIKey(on: app)

            struct Body: Content {
                let agentName: String
                let organizationId: UUID?
                let siteId: UUID?
            }

            let site = Site(name: "pleb-dc", organizationScope: .organization(org.id!))
            try await site.save(on: app.db)

            // The user holds no binding or membership anywhere, so agent
            // management on the org is denied — the manage_agents check fires
            // before the site is ever resolved.
            try await app.test(.POST, "/api/agent-enrollments") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(Body(agentName: "node-y", organizationId: org.id, siteId: site.id))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }

            // Listing succeeds but shows nothing the user can't manage.
            try await app.test(.GET, "/api/agent-enrollments") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let items = try res.content.decode(PagedResponse<AgentEnrollmentListItem>.self).items
                #expect(items.isEmpty)
            }
        }
    }

    @Test("An enrollment's site must belong to the enrollment's organization")
    func enrollmentSiteMustMatchOrg() async throws {
        try await withScopedApp { app, org in
            self.installFakeSPIRE(on: app)
            let builder = TestDataBuilder(db: app.db)
            let admin = try await builder.createUser(
                username: "scope-admin2", email: "scope-admin2@example.com",
                displayName: "Scope Admin 2", isSystemAdmin: true)
            let token = try await admin.generateAPIKey(on: app)

            let otherOrg = try await builder.createOrganization(name: "Elsewhere Org")
            let foreignSite = Site(name: "elsewhere-dc", organizationScope: .organization(otherOrg.id!))
            try await foreignSite.save(on: app.db)

            struct Body: Content {
                let agentName: String
                let organizationId: UUID?
                let siteId: UUID?
            }

            try await app.test(.POST, "/api/agent-enrollments") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    Body(agentName: "node-z", organizationId: org.id, siteId: foreignSite.id))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    // MARK: - Site parentage

    @Test("Site create persists the org parent; delete removes the row")
    func siteParentageLifecycle() async throws {
        try await withScopedApp { app, org in
            let builder = TestDataBuilder(db: app.db)
            let admin = try await builder.createUser(
                username: "site-scope-admin", email: "site-scope-admin@example.com",
                displayName: "Site Scope Admin", isSystemAdmin: true)
            let token = try await admin.generateAPIKey(on: app)

            var siteId: UUID?
            try await app.test(.POST, "/api/sites") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateSiteRequest(
                        name: "tuple-dc", description: nil,
                        organizationId: org.id, organizationalUnitId: nil))
            } afterResponse: { res in
                #expect(res.status == .ok)
                siteId = try res.content.decode(SiteResponse.self).id
            }

            let createdSite = try await LegacySiteStore.site(id: siteId!, on: app.db)
            let site = try #require(createdSite)
            #expect(site.organizationID == org.id)
            #expect(site.organizationalUnitID == nil)

            try await app.test(.DELETE, "/api/sites/\(siteId!.uuidString)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            let remaining = try await LegacySiteStore.site(id: siteId!, on: app.db)
            #expect(remaining == nil)
        }
    }

    @Test("Destructive agent actions require a system admin while foreign-org VMs are hosted")
    func destructiveActionsGuardForeignVMs() async throws {
        try await withScopedApp { app, org in
            let builder = TestDataBuilder(db: app.db)
            // Delegated org admin: not a system admin; their org-admin binding
            // grants agent:manage, so only the foreign-VM guard stands in the
            // way.
            let orgAdmin = try await builder.createUser(
                username: "delegated-admin", email: "delegated-admin@example.com",
                displayName: "Delegated Admin", isSystemAdmin: false)
            try await builder.addUserToOrganization(user: orgAdmin, organization: org, role: "admin")
            let orgAdminToken = try await orgAdmin.generateAPIKey(on: app)

            let agentUUID = try await self.registerAgent(
                on: app, agentName: "shared-agent",
                organizationScope: .organization(org.id!))

            // A VM from a different org placed on this agent (pre-scoping
            // placement; the scheduler isn't org-scoped until phase 2).
            let foreignOrg = try await builder.createOrganization(name: "Foreign Tenant")
            let foreignProject = try await builder.createProject(
                name: "Foreign Project", description: "p", organization: foreignOrg)
            var foreignVM = try await builder.createVM(name: "tenant-vm", project: foreignProject)
            foreignVM.hypervisorId = agentUUID.uuidString
            try await foreignVM.save(on: app.db)

            try await app.test(.POST, "/api/agents/\(agentUUID.uuidString)/actions/force-offline") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: orgAdminToken)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
            try await app.test(.DELETE, "/api/agents/\(agentUUID.uuidString)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: orgAdminToken)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }

            // A foreign-org DETACHED VOLUME stored on the agent blocks the
            // delegated admin the same way (volume placement is unscoped
            // until phase 2 too).
            try await foreignVM.delete(on: app.db)
            let foreignVolume = Volume(
                name: "tenant-vol", description: "v", projectID: foreignProject.id!, environment: "development",
                size: 1 << 30, createdByID: orgAdmin.id!)
            try await foreignVolume.save(on: app.db)
            try await placeVolume(foreignVolume, on: agentUUID.uuidString, using: app.db)

            try await app.test(.POST, "/api/agents/\(agentUUID.uuidString)/actions/force-offline") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: orgAdminToken)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }

            // Once the foreign workloads are gone, the delegated admin may act.
            try await foreignVolume.delete(on: app.db)
            try await app.test(.POST, "/api/agents/\(agentUUID.uuidString)/actions/force-offline") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: orgAdminToken)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }
        }
    }

    @Test("Deregistration deletes the agent's enrollment so the name is reusable")
    func deregistrationClearsEnrollment() async throws {
        try await withScopedApp { app, org in
            self.installFakeSPIRE(on: app)
            let builder = TestDataBuilder(db: app.db)
            let admin = try await builder.createUser(
                username: "dereg-admin", email: "dereg-admin@example.com",
                displayName: "Dereg Admin", isSystemAdmin: true)
            let adminToken = try await admin.generateAPIKey(on: app)

            let site = Site(name: "retiring-site", organizationScope: .organization(org.id!))
            try await site.save(on: app.db)
            let enrollment = self.makeEnrollment(
                agentName: "retiring-agent", siteID: try site.requireID(),
                organizationScope: .organization(org.id!))
            _ = try await saveTestAgentEnrollment(enrollment, on: app.db)
            let agentUUID = try await self.registerAgent(on: app, agentName: "retiring-agent")

            try await app.test(.DELETE, "/api/agents/\(agentUUID.uuidString)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            let leftover = try await testAgentEnrollmentCount(
                agentName: "retiring-agent",
                on: app.db
            )
            #expect(leftover == 0)

            // The name is immediately reusable — a leftover row would trip the
            // one-enrollment-per-name guard and lock the name permanently.
            struct Body: Content {
                let agentName: String
                let organizationId: UUID?
                let siteId: UUID?
            }
            let replacementSite = Site(name: "dereg-dc", organizationScope: .organization(org.id!))
            try await replacementSite.save(on: app.db)
            try await app.test(.POST, "/api/agent-enrollments") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
                try req.content.encode(
                    Body(
                        agentName: "retiring-agent", organizationId: org.id,
                        siteId: replacementSite.id))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }
        }
    }

    @Test("A network cannot pin to a site in a different organization")
    func networkSitePinRequiresSameOrg() async throws {
        try await withScopedApp { app, org in
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "net-pinner", email: "net-pinner@example.com",
                displayName: "Net Pinner", isSystemAdmin: false)
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            try await user.replacingCurrentOrganization(org.id).save(on: app.db)
            let project = try await builder.createProject(
                name: "Pin Project", description: "p", organization: org)
            let token = try await user.generateAPIKey(on: app)

            let foreignOrg = try await builder.createOrganization(name: "Pin Foreign Org")
            let foreignSite = Site(name: "pin-foreign-dc", organizationScope: .organization(foreignOrg.id!))
            try await foreignSite.save(on: app.db)
            let ownSite = Site(name: "pin-own-dc", organizationScope: .organization(org.id!))
            try await ownSite.save(on: app.db)

            struct Body: Content {
                let name: String
                let subnet: String
                let projectId: UUID?
                let siteId: UUID?
            }

            // Cross-org pin refused: the site's OVN fabric and agents belong
            // to another tenant.
            try await app.test(.POST, "/api/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    Body(name: "sneaky-net", subnet: "10.50.0.0/24", projectId: project.id, siteId: foreignSite.id))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            // Same-org pin succeeds.
            try await app.test(.POST, "/api/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    Body(name: "honest-net", subnet: "10.51.0.0/24", projectId: project.id, siteId: ownSite.id))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            // OU delegation within ONE org: a site scoped to OU-B serves only
            // OU-B's subtree, not a sibling OU's project (root org matches!).
            let ouA = OrganizationalUnit(
                name: "Pin OU A", description: "a", organizationID: org.id!,
                path: "/\(org.id!.uuidString)", depth: 1)
            try await ouA.save(on: app.db)
            let ouB = OrganizationalUnit(
                name: "Pin OU B", description: "b", organizationID: org.id!,
                path: "/\(org.id!.uuidString)", depth: 1)
            try await ouB.save(on: app.db)
            let projectA = try await builder.createProject(
                name: "Pin Project A", description: "p", ou: ouA)
            let projectB = try await builder.createProject(
                name: "Pin Project B", description: "p", ou: ouB)
            let siteB = Site(name: "pin-ou-b-dc", organizationScope: .organizationalUnit(ouB.id!))
            try await siteB.save(on: app.db)

            try await app.test(.POST, "/api/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    Body(name: "sibling-ou-net", subnet: "10.52.0.0/24", projectId: projectA.id, siteId: siteB.id))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
            try await app.test(.POST, "/api/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    Body(name: "own-ou-net", subnet: "10.53.0.0/24", projectId: projectB.id, siteId: siteB.id))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }
        }
    }

    @Test("Enrolling with a site pin requires manage on the site")
    func enrollmentSitePinRequiresSiteManage() async throws {
        try await withScopedApp { app, org in
            self.installFakeSPIRE(on: app)
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "agents-only-admin", email: "agents-only-admin@example.com",
                displayName: "Agents Only Admin", isSystemAdmin: false)
            let token = try await user.generateAPIKey(on: app)

            // The delegated-subtree scenario: the caller admins one OU (so
            // manage_agents on the enrollment's OU scope passes), but the
            // pinned site is owned at the org level, where the caller holds no
            // binding — so site manage is denied.
            let ou = OrganizationalUnit(
                name: "Pin Gated OU", description: "ou", organizationID: org.id!,
                path: "/\(org.id!.uuidString)", depth: 1)
            try await ou.save(on: app.db)
            try await RoleBindingService.grant(
                principalType: .user, principalID: user.id!, role: .admin,
                nodeType: .organizationalUnit, nodeID: ou.id!, createdBy: nil, on: app.db)

            let site = Site(name: "pin-gated-dc", organizationScope: .organization(org.id!))
            try await site.save(on: app.db)

            struct Body: Content {
                let agentName: String
                let organizationalUnitId: UUID?
                let siteId: UUID?
            }
            try await app.test(.POST, "/api/agent-enrollments") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    Body(agentName: "pin-gated-agent", organizationalUnitId: ou.id, siteId: site.id))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test("Site membership changes require manage on the agent, not just the site")
    func siteMembershipRequiresAgentManage() async throws {
        try await withScopedApp { app, org in
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "site-only-admin", email: "site-only-admin@example.com",
                displayName: "Site Only Admin", isSystemAdmin: false)
            let token = try await user.generateAPIKey(on: app)

            // The delegated-subtree scenario: the site lives in an OU the
            // caller admins (site manage passes), but the agent is owned at
            // the org level, where the caller holds no binding — so agent
            // manage is denied.
            let ou = OrganizationalUnit(
                name: "Membership OU", description: "ou", organizationID: org.id!,
                path: "/\(org.id!.uuidString)", depth: 1)
            try await ou.save(on: app.db)
            try await RoleBindingService.grant(
                principalType: .user, principalID: user.id!, role: .admin,
                nodeType: .organizationalUnit, nodeID: ou.id!, createdBy: nil, on: app.db)

            let site = Site(name: "membership-dc", organizationScope: .organizationalUnit(ou.id!))
            try await site.save(on: app.db)
            let agentUUID = try await self.registerAgent(
                on: app, agentName: "membership-agent",
                organizationScope: .organization(org.id!))

            try await app.test(.POST, "/api/sites/\(site.id!.uuidString)/agents/\(agentUUID.uuidString)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }

            let agent = try #require(try await Agent.find(agentUUID, on: app.db))
            #expect(agent.siteID != site.id)
        }
    }

    // MARK: - OU scope resolution

    @Test("An OU-scoped agent resolves its root organization through the OU")
    func ouScopeResolvesRootOrg() async throws {
        try await withScopedApp { app, org in
            let ou = OrganizationalUnit(
                name: "Scope OU", description: "ou", organizationID: org.id!,
                path: "/\(org.id!.uuidString)", depth: 1)
            try await ou.save(on: app.db)

            let agentUUID = try await self.registerAgent(
                on: app, agentName: "ou-agent",
                organizationScope: .organizationalUnit(ou.id!))

            let agent = try #require(try await Agent.find(agentUUID, on: app.db))
            #expect(agent.organizationalUnitID == ou.id)
            #expect(agent.organizationID == nil)
            let rootOrg = try await agent.rootOrganizationID(on: app.db)
            #expect(rootOrg == org.id)
        }
    }
}
