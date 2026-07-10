import Fluent
import StratoShared
import Testing
import Vapor
import VaporTesting

@testable import App

/// Tests for organization-scoped infrastructure: agents, sites, and
/// registration tokens carry a mandatory org-or-OU owner. Covers scope
/// stamping at registration (and its refusal/durability rules), the SpiceDB
/// `agent#parent`/`site#parent` tuple lifecycle, the org-delegated token API,
/// and the system-admin reassignment endpoint.
@Suite("Agent Organization Scope Tests", .serialized)
final class AgentOrganizationScopeTests {

    private func withScopedApp(
        _ test: (Application, Organization, SpiceDBMockRecorder) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)
            try await app.autoMigrate()

            let recorder = SpiceDBMockRecorder()
            app.spicedbMockRecorder = recorder

            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "Scope Org")

            try await test(app, org, recorder)

        } catch {
            try await app.shutdownForTesting()
            throw error
        }

        try await app.shutdownForTesting()
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

    @Test("Registration stamps the token's org scope and writes the agent#parent tuple")
    func registrationStampsScope() async throws {
        try await withScopedApp { app, org, recorder in
            let agentUUID = try await app.agentService.registerAgent(
                self.makeRegisterMessage(agentName: "scoped-agent"),
                agentName: "scoped-agent",
                organizationScope: .organization(org.id!))

            let agent = try #require(try await Agent.find(agentUUID, on: app.db))
            #expect(agent.$organization.id == org.id)
            #expect(agent.$organizationalUnit.id == nil)

            let writes = await recorder.writes
            let tuple = try #require(
                writes.first { $0.entity == "agent" && $0.relation == "parent" })
            #expect(tuple.entityId == agentUUID.uuidString)
            #expect(tuple.subject == "organization")
            #expect(tuple.subjectId == org.id!.uuidString)
        }
    }

    @Test("A brand-new agent with no organization scope is refused")
    func newAgentWithoutScopeRefused() async throws {
        try await withScopedApp { app, _, _ in
            await #expect(throws: AgentServiceError.self) {
                _ = try await app.agentService.registerAgent(
                    self.makeRegisterMessage(agentName: "unowned-agent"),
                    agentName: "unowned-agent")
            }
            let count = try await Agent.query(on: app.db).count()
            #expect(count == 0)
        }
    }

    @Test("A new agent without a redeemed scope falls back to its minted token row (mTLS path)")
    func mtlsFallbackReadsTokenScope() async throws {
        try await withScopedApp { app, org, _ in
            // The mTLS handshake never redeems the WS token, but minting the
            // token created a row carrying the org.
            let token = AgentRegistrationToken(
                agentName: "mtls-node", expirationHours: 1,
                organizationScope: .organization(org.id!))
            try await token.save(on: app.db)

            let agentUUID = try await app.agentService.registerAgent(
                self.makeRegisterMessage(agentName: "mtls-node"),
                agentName: "mtls-node")

            let agent = try #require(try await Agent.find(agentUUID, on: app.db))
            #expect(agent.$organization.id == org.id)
        }
    }

    @Test("Reconnecting with a scopeless rotated token preserves the org assignment")
    func reconnectPreservesScope() async throws {
        try await withScopedApp { app, org, _ in
            let agentUUID = try await app.agentService.registerAgent(
                self.makeRegisterMessage(agentName: "sticky-agent"),
                agentName: "sticky-agent",
                organizationScope: .organization(org.id!))

            // Rotated reconnect tokens carry no scope; nil must not clear.
            _ = try await app.agentService.registerAgent(
                self.makeRegisterMessage(agentName: "sticky-agent"),
                agentName: "sticky-agent")

            let agent = try #require(try await Agent.find(agentUUID, on: app.db))
            #expect(agent.$organization.id == org.id)
        }
    }

    @Test("A token-driven org change is refused while the agent hosts VMs")
    func orgChangeRefusedWhileHostingVMs() async throws {
        try await withScopedApp { app, org, _ in
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

    @Test("A token site assignment in a different org than the agent is ignored")
    func crossOrgSiteAssignmentIgnored() async throws {
        try await withScopedApp { app, org, _ in
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
        }
    }

    // MARK: - Token API

    @Test("Minting a token requires an organization scope")
    func tokenCreationRequiresScope() async throws {
        try await withScopedApp { app, org, _ in
            let builder = TestDataBuilder(db: app.db)
            let admin = try await builder.createUser(
                username: "scope-admin", email: "scope-admin@example.com",
                displayName: "Scope Admin", isSystemAdmin: true)
            let token = try await admin.generateAPIKey(on: app.db)

            struct Body: Content {
                let agentName: String
                var organizationId: UUID? = nil
            }

            try await app.test(.POST, "/api/agents/registration-tokens") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(Body(agentName: "node-x"))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            try await app.test(.POST, "/api/agents/registration-tokens") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(Body(agentName: "node-x", organizationId: org.id))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let created = try res.content.decode(AgentRegistrationTokenResponse.self)
                #expect(created.agentName == "node-x")
            }

            let row = try #require(
                try await AgentRegistrationToken.query(on: app.db)
                    .filter(\.$agentName == "node-x").first())
            #expect(row.organizationID == org.id)
        }
    }

    @Test("A non-admin without manage_agents cannot mint or list tokens")
    func tokenCreationDeniedWithoutManageAgents() async throws {
        try await withScopedApp { app, org, _ in
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "scope-pleb", email: "scope-pleb@example.com",
                displayName: "Pleb", isSystemAdmin: false)
            let token = try await user.generateAPIKey(on: app.db)

            struct Body: Content {
                let agentName: String
                let organizationId: UUID?
            }

            app.spicedbMockAllows = false
            defer { app.spicedbMockAllows = true }

            try await app.test(.POST, "/api/agents/registration-tokens") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(Body(agentName: "node-y", organizationId: org.id))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }

            // Listing succeeds but shows nothing the user can't manage.
            try await app.test(.GET, "/api/agents/registration-tokens") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let items = try res.content.decode([AgentRegistrationTokenListItem].self)
                #expect(items.isEmpty)
            }
        }
    }

    @Test("A token's site must belong to the token's organization")
    func tokenSiteMustMatchOrg() async throws {
        try await withScopedApp { app, org, _ in
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

            try await app.test(.POST, "/api/agents/registration-tokens") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    Body(agentName: "node-z", organizationId: org.id, siteId: foreignSite.id))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    // MARK: - Site tuples

    @Test("Site create writes site#parent; delete removes it")
    func siteTupleLifecycle() async throws {
        try await withScopedApp { app, org, recorder in
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

            let writes = await recorder.writes
            let parent = try #require(
                writes.first { $0.entity == "site" && $0.relation == "parent" })
            #expect(parent.entityId == siteId!.uuidString)
            #expect(parent.subjectId == org.id!.uuidString)

            try await app.test(.DELETE, "/api/sites/\(siteId!.uuidString)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            let deletes = await recorder.deletes
            #expect(deletes.contains { $0.entity == "site" && $0.entityId == siteId!.uuidString })
        }
    }

    // MARK: - Reassignment endpoint

    @Test("Org reassignment moves the scope and rewrites the tuple; drain guards hold")
    func reassignOrganization() async throws {
        try await withScopedApp { app, org, recorder in
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

            // Old tuple deleted, new one written.
            let deletes = await recorder.deletes
            #expect(
                deletes.contains {
                    $0.entity == "agent" && $0.subjectId == org.id!.uuidString
                })
            let writes = await recorder.writes
            #expect(
                writes.contains {
                    $0.entity == "agent" && $0.relation == "parent"
                        && $0.subjectId == otherOrg.id!.uuidString
                })

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
        }
    }

    @Test("Destructive agent actions require a system admin while foreign-org VMs are hosted")
    func destructiveActionsGuardForeignVMs() async throws {
        try await withScopedApp { app, org, _ in
            let builder = TestDataBuilder(db: app.db)
            // Delegated org admin: not a system admin; the mock SpiceDB grants
            // agent#manage, so only the foreign-VM guard stands in the way.
            let orgAdmin = try await builder.createUser(
                username: "delegated-admin", email: "delegated-admin@example.com",
                displayName: "Delegated Admin", isSystemAdmin: false)
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

            // Once the foreign VM is gone, the delegated admin may act.
            try await foreignVM.delete(on: app.db)
            try await app.test(.POST, "/api/agents/\(agentUUID.uuidString)/actions/force-offline") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: orgAdminToken)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }
        }
    }

    @Test("A network cannot pin to a site in a different organization")
    func networkSitePinRequiresSameOrg() async throws {
        try await withScopedApp { app, org, _ in
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "net-pinner", email: "net-pinner@example.com",
                displayName: "Net Pinner", isSystemAdmin: false)
            try await builder.addUserToOrganization(user: user, organization: org, role: "member")
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
        }
    }

    @Test("The org backfill skips reconnect tokens of registered agents")
    func backfillSkipsReconnectTokens() async throws {
        try await withScopedApp { app, org, _ in
            _ = try await app.agentService.registerAgent(
                self.makeRegisterMessage(agentName: "veteran-agent"),
                agentName: "veteran-agent",
                organizationScope: .organization(org.id!))

            // A rotated reconnect credential (scopeless, for a live agent) and
            // a pending join token (scopeless, agent not registered yet) — the
            // pre-migration states the backfill must tell apart.
            let reconnect = AgentRegistrationToken(agentName: "veteran-agent", expirationHours: 24 * 30)
            try await reconnect.save(on: app.db)
            let pending = AgentRegistrationToken(agentName: "future-agent", expirationHours: 1)
            try await pending.save(on: app.db)

            try await BackfillInfraOrganizationScope().prepare(on: app.db)

            let reloadedReconnect = try #require(
                try await AgentRegistrationToken.find(reconnect.id, on: app.db))
            #expect(reloadedReconnect.organizationID == nil)
            let reloadedPending = try #require(
                try await AgentRegistrationToken.find(pending.id, on: app.db))
            #expect(reloadedPending.organizationID == org.id)
        }
    }

    @Test("Site membership changes require manage on the agent, not just the site")
    func siteMembershipRequiresAgentManage() async throws {
        try await withScopedApp { app, org, _ in
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "site-only-admin", email: "site-only-admin@example.com",
                displayName: "Site Only Admin", isSystemAdmin: false)
            let token = try await user.generateAPIKey(on: app.db)

            let site = Site(name: "membership-dc", organizationScope: .organization(org.id!))
            try await site.save(on: app.db)
            let agentUUID = try await app.agentService.registerAgent(
                self.makeRegisterMessage(agentName: "membership-agent"),
                agentName: "membership-agent",
                organizationScope: .organization(org.id!))

            // The sibling-OU scenario: SpiceDB grants site#manage but denies
            // agent#manage (same root org, different delegated subtree).
            app.spicedbMockDeniedResources = ["agent"]
            defer { app.spicedbMockDeniedResources = [] }

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
        try await withScopedApp { app, org, _ in
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
