import Fluent
import Foundation
import SPIREServerAPI
import StratoShared
import Testing
import Vapor
import VaporTesting

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
    ) -> AgentEnrollment {
        AgentEnrollment(
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
            capabilities: ["qemu"],
            resources: AgentResources(
                totalCPU: 16, availableCPU: 16,
                totalMemory: 1 << 34, availableMemory: 1 << 34,
                totalDisk: 1 << 40, availableDisk: 1 << 40
            ),
            protocolVersion: WireProtocol.currentVersion
        )
    }

    // MARK: - Registration scope stamping

    @Test("Registration stamps the caller-supplied org scope")
    func registrationStampsScope() async throws {
        try await withScopedApp { app, org in
            let agentUUID = try await app.agentService.registerAgent(
                self.makeRegisterMessage(agentName: "scoped-agent"),
                agentName: "scoped-agent",
                organizationScope: .organization(org.id!))

            let agent = try #require(try await Agent.find(agentUUID, on: app.db))
            #expect(agent.$organization.id == org.id)
            #expect(agent.$organizationalUnit.id == nil)
        }
    }

    @Test("A brand-new agent with no organization scope is refused")
    func newAgentWithoutScopeRefused() async throws {
        try await withScopedApp { app, _ in
            await #expect(throws: AgentServiceError.self) {
                _ = try await app.agentService.registerAgent(
                    self.makeRegisterMessage(agentName: "unowned-agent"),
                    agentName: "unowned-agent")
            }
            let count = try await Agent.query(on: app.db).count()
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
            try await enrollment.save(on: app.db)

            let agentUUID = try await app.agentService.registerAgent(
                self.makeRegisterMessage(agentName: "mtls-node"),
                agentName: "mtls-node")

            let agent = try #require(try await Agent.find(agentUUID, on: app.db))
            #expect(agent.$organization.id == org.id)
            #expect(agent.$site.id == site.id)

            // The enrollment is marked redeemed but survives: scope stays
            // readable, and unlike a single-use token it is not consumed.
            let reloaded = try #require(try await AgentEnrollment.find(enrollment.id, on: app.db))
            #expect(reloaded.isUsed == true)
        }
    }

    @Test("Reconnecting without a scope preserves the org assignment")
    func reconnectPreservesScope() async throws {
        try await withScopedApp { app, org in
            let agentUUID = try await app.agentService.registerAgent(
                self.makeRegisterMessage(agentName: "sticky-agent"),
                agentName: "sticky-agent",
                organizationScope: .organization(org.id!))

            // Every reconnect passes no scope; nil must not clear.
            _ = try await app.agentService.registerAgent(
                self.makeRegisterMessage(agentName: "sticky-agent"),
                agentName: "sticky-agent")

            let agent = try #require(try await Agent.find(agentUUID, on: app.db))
            #expect(agent.$organization.id == org.id)
        }
    }

    @Test("An existing agent does not re-read its enrollment on reconnect")
    func existingAgentIgnoresEnrollmentOnReconnect() async throws {
        try await withScopedApp { app, org in
            let builder = TestDataBuilder(db: app.db)
            let otherOrg = try await builder.createOrganization(name: "Enrollment Drift Org")

            let agentUUID = try await app.agentService.registerAgent(
                self.makeRegisterMessage(agentName: "durable-agent"),
                agentName: "durable-agent",
                organizationScope: .organization(org.id!))
            let site = Site(name: "drift-dc", organizationScope: .organization(org.id!))
            try await site.save(on: app.db)
            let agent = try #require(try await Agent.find(agentUUID, on: app.db))
            agent.$site.id = site.id
            try await agent.save(on: app.db)

            // A stale enrollment naming a different org and no site. Both values
            // are durable on the agent row, and re-reading the enrollment on
            // every reconnect would fight an operator who has since moved the
            // agent — so the enrollment is deliberately not consulted again.
            let enrollment = self.makeEnrollment(
                agentName: "durable-agent", organizationScope: .organization(otherOrg.id!))
            try await enrollment.save(on: app.db)

            _ = try await app.agentService.registerAgent(
                self.makeRegisterMessage(agentName: "durable-agent"),
                agentName: "durable-agent")

            let reloaded = try #require(try await Agent.find(agentUUID, on: app.db))
            #expect(reloaded.$organization.id == org.id)
            #expect(reloaded.$site.id == site.id)
        }
    }

    @Test("An org change is refused while the agent hosts VMs")
    func orgChangeRefusedWhileHostingVMs() async throws {
        try await withScopedApp { app, org in
            let builder = TestDataBuilder(db: app.db)
            let otherOrg = try await builder.createOrganization(name: "Other Org")
            let project = try await builder.createProject(
                name: "Scope Project", description: "p", organization: org)

            let agentUUID = try await app.agentService.registerAgent(
                self.makeRegisterMessage(agentName: "loaded-agent"),
                agentName: "loaded-agent",
                organizationScope: .organization(org.id!))

            let vm = try await builder.createVM(name: "resident", project: project)
            vm.hypervisorId = agentUUID.uuidString
            try await vm.save(on: app.db)

            // Refused (logged, not fatal): the agent keeps its original org.
            _ = try await app.agentService.registerAgent(
                self.makeRegisterMessage(agentName: "loaded-agent"),
                agentName: "loaded-agent",
                organizationScope: .organization(otherOrg.id!))

            let agent = try #require(try await Agent.find(agentUUID, on: app.db))
            #expect(agent.$organization.id == org.id)
        }
    }

    @Test("A site assignment in a different org than the agent is ignored")
    func crossOrgSiteAssignmentIgnored() async throws {
        try await withScopedApp { app, org in
            let builder = TestDataBuilder(db: app.db)
            let otherOrg = try await builder.createOrganization(name: "Foreign Org")
            let foreignSite = Site(name: "foreign-dc", organizationScope: .organization(otherOrg.id!))
            try await foreignSite.save(on: app.db)

            let agentUUID = try await app.agentService.registerAgent(
                self.makeRegisterMessage(agentName: "cross-org-agent"),
                agentName: "cross-org-agent",
                siteID: foreignSite.id,
                organizationScope: .organization(org.id!))

            let agent = try #require(try await Agent.find(agentUUID, on: app.db))
            #expect(agent.$site.id == nil)
            #expect(agent.$organization.id == org.id)

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

            let ouAgentUUID = try await app.agentService.registerAgent(
                self.makeRegisterMessage(agentName: "ou-a-agent"),
                agentName: "ou-a-agent",
                siteID: ouBSite.id,
                organizationScope: .organizationalUnit(ouA.id!))
            let ouAgent = try #require(try await Agent.find(ouAgentUUID, on: app.db))
            #expect(ouAgent.$site.id == nil)
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
            let token = try await admin.generateAPIKey(on: app.db)

            struct Body: Content {
                let agentName: String
                var organizationId: UUID? = nil
            }

            try await app.test(.POST, "/api/agent-enrollments") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(Body(agentName: "node-x"))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            try await app.test(.POST, "/api/agent-enrollments") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(Body(agentName: "node-x", organizationId: org.id))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let created = try res.content.decode(AgentEnrollmentResponse.self)
                #expect(created.agentName == "node-x")
            }

            let row = try #require(
                try await AgentEnrollment.query(on: app.db)
                    .filter(\.$agentName == "node-x").first())
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
            let token = try await user.generateAPIKey(on: app.db)

            struct Body: Content {
                let agentName: String
                let organizationId: UUID?
            }

            // The user holds no binding or membership anywhere, so agent
            // management on the org is denied.
            try await app.test(.POST, "/api/agent-enrollments") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(Body(agentName: "node-y", organizationId: org.id))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }

            // Listing succeeds but shows nothing the user can't manage.
            try await app.test(.GET, "/api/agent-enrollments") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let items = try res.content.decode([AgentEnrollmentListItem].self)
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
            let token = try await admin.generateAPIKey(on: app.db)

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
            let token = try await admin.generateAPIKey(on: app.db)

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

            let createdSite = try await Site.find(siteId!, on: app.db)
            let site = try #require(createdSite)
            #expect(site.$organization.id == org.id)
            #expect(site.$organizationalUnit.id == nil)

            try await app.test(.DELETE, "/api/sites/\(siteId!.uuidString)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            let remaining = try await Site.find(siteId!, on: app.db)
            #expect(remaining == nil)
        }
    }

    // MARK: - Reassignment endpoint

    @Test("Org reassignment moves the scope; drain guards hold")
    func reassignOrganization() async throws {
        try await withScopedApp { app, org in
            let builder = TestDataBuilder(db: app.db)
            let admin = try await builder.createUser(
                username: "reassign-admin", email: "reassign-admin@example.com",
                displayName: "Reassign Admin", isSystemAdmin: true)
            let token = try await admin.generateAPIKey(on: app.db)
            let otherOrg = try await builder.createOrganization(name: "Destination Org")

            let agentUUID = try await app.agentService.registerAgent(
                self.makeRegisterMessage(agentName: "movable-agent"),
                agentName: "movable-agent",
                organizationScope: .organization(org.id!))

            struct Body: Content {
                let organizationId: UUID?
            }

            try await app.test(.PATCH, "/api/agents/\(agentUUID.uuidString)/organization") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(Body(organizationId: otherOrg.id))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let response = try res.content.decode(AgentResponse.self)
                #expect(response.organizationId == otherOrg.id)
            }

            let agent = try #require(try await Agent.find(agentUUID, on: app.db))
            #expect(agent.$organization.id == otherOrg.id)

            // With a hosted VM, the move is refused.
            let project = try await builder.createProject(
                name: "Dest Project", description: "p", organization: otherOrg)
            let vm = try await builder.createVM(name: "anchor", project: project)
            vm.hypervisorId = agentUUID.uuidString
            try await vm.save(on: app.db)

            try await app.test(.PATCH, "/api/agents/\(agentUUID.uuidString)/organization") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(Body(organizationId: org.id))
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            // A hosted sandbox anchors the agent the same way.
            try await vm.delete(on: app.db)
            let sandbox = try await builder.createSandbox(name: "anchor-sbx", project: project)
            sandbox.hypervisorId = agentUUID.uuidString
            try await sandbox.save(on: app.db)

            try await app.test(.PATCH, "/api/agents/\(agentUUID.uuidString)/organization") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(Body(organizationId: org.id))
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            // A detached volume anchors the agent the same way.
            try await sandbox.delete(on: app.db)
            let volume = Volume(
                name: "anchor-vol", description: "v", projectID: project.id!,
                size: 1 << 30, createdByID: admin.id!)
            volume.hypervisorId = agentUUID.uuidString
            try await volume.save(on: app.db)

            try await app.test(.PATCH, "/api/agents/\(agentUUID.uuidString)/organization") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(Body(organizationId: org.id))
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
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
            let orgAdminToken = try await orgAdmin.generateAPIKey(on: app.db)

            let agentUUID = try await app.agentService.registerAgent(
                self.makeRegisterMessage(agentName: "shared-agent"),
                agentName: "shared-agent",
                organizationScope: .organization(org.id!))

            // A VM from a different org placed on this agent (pre-scoping
            // placement; the scheduler isn't org-scoped until phase 2).
            let foreignOrg = try await builder.createOrganization(name: "Foreign Tenant")
            let foreignProject = try await builder.createProject(
                name: "Foreign Project", description: "p", organization: foreignOrg)
            let foreignVM = try await builder.createVM(name: "tenant-vm", project: foreignProject)
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
                name: "tenant-vol", description: "v", projectID: foreignProject.id!,
                size: 1 << 30, createdByID: orgAdmin.id!)
            foreignVolume.hypervisorId = agentUUID.uuidString
            try await foreignVolume.save(on: app.db)

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
            let adminToken = try await admin.generateAPIKey(on: app.db)

            let enrollment = self.makeEnrollment(
                agentName: "retiring-agent", organizationScope: .organization(org.id!))
            try await enrollment.save(on: app.db)
            let agentUUID = try await app.agentService.registerAgent(
                self.makeRegisterMessage(agentName: "retiring-agent"),
                agentName: "retiring-agent")

            try await app.test(.DELETE, "/api/agents/\(agentUUID.uuidString)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            let leftover = try await AgentEnrollment.query(on: app.db)
                .filter(\.$agentName == "retiring-agent")
                .count()
            #expect(leftover == 0)

            // The name is immediately reusable — a leftover row would trip the
            // one-enrollment-per-name guard and lock the name permanently.
            struct Body: Content {
                let agentName: String
                let organizationId: UUID?
            }
            try await app.test(.POST, "/api/agent-enrollments") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
                try req.content.encode(Body(agentName: "retiring-agent", organizationId: org.id))
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
            user.currentOrganizationId = org.id
            try await user.save(on: app.db)
            let project = try await builder.createProject(
                name: "Pin Project", description: "p", organization: org)
            let token = try await user.generateAPIKey(on: app.db)

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
            let token = try await user.generateAPIKey(on: app.db)

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
            let token = try await user.generateAPIKey(on: app.db)

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
            let agentUUID = try await app.agentService.registerAgent(
                self.makeRegisterMessage(agentName: "membership-agent"),
                agentName: "membership-agent",
                organizationScope: .organization(org.id!))

            try await app.test(.POST, "/api/sites/\(site.id!.uuidString)/agents/\(agentUUID.uuidString)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }

            let agent = try #require(try await Agent.find(agentUUID, on: app.db))
            #expect(agent.$site.id == nil)
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

            let agentUUID = try await app.agentService.registerAgent(
                self.makeRegisterMessage(agentName: "ou-agent"),
                agentName: "ou-agent",
                organizationScope: .organizationalUnit(ou.id!))

            let agent = try #require(try await Agent.find(agentUUID, on: app.db))
            #expect(agent.$organizationalUnit.id == ou.id)
            #expect(agent.$organization.id == nil)
            let rootOrg = try await agent.rootOrganizationID(on: app.db)
            #expect(rootOrg == org.id)
        }
    }
}
