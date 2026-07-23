import Fluent
import Foundation
import StratoShared
import Testing
import Vapor
import VaporTesting

@testable import App

/// System-admin access has exactly one enforcement path: the tier-1
/// `platform-system-admin` policy inside the evaluator. Controllers used to
/// carry their own admin shortcuts — list endpoints that skipped per-row
/// checks, `isSystemAdmin ||` disjunctions, business rules written as Swift
/// escalations — and each was a place where an admin's access was granted
/// without the evaluator being asked.
///
/// These tests pin the properties that removal bought. They are deliberately
/// behavioural (through the HTTP surface) rather than assertions about the
/// absence of code: what matters is that a guardrail binds an admin's *list*
/// exactly as it binds their item reads, and that the agent rules still hold
/// now that they are policy.
@Suite("Admin Exception Path Tests", .serialized)
final class AdminExceptionPathTests {

    private func withApp(_ test: (Application, TestDataBuilder) async throws -> Void) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()
            app.guardrailAnalyzer = PermissiveGuardrailAnalyzer()
            try await test(app, TestDataBuilder(db: app.db))
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    /// Compile the policy set so the tier-1 policies and any guardrail rows are
    /// live for the checks under test.
    private func rebuildPolicySet(_ app: Application) async throws {
        let version = try await PolicySetVersionService.current(on: app.db)
        await app.cedarPolicySet.rebuild(version: version, on: app.db)
    }

    private func makeAgent(_ app: Application, name: String, org: Organization) async throws -> Agent {
        let agent = Agent(
            name: name,
            hostname: "hv.example",
            version: "1.0.0",
            capabilities: ["qemu"],
            status: .online,
            resources: AgentResources(
                totalCPU: 8, availableCPU: 8,
                totalMemory: 16_000_000_000, availableMemory: 16_000_000_000,
                totalDisk: 100_000_000_000, availableDisk: 100_000_000_000
            ),
            architecture: .x86_64,
            lastHeartbeat: Date()
        )
        agent.organizationScope = .organization(try org.requireID())
        agent.wireProtocolVersion = WireProtocol.agentUpdateMinimumVersion
        try await agent.save(on: app.db)
        return agent
    }

    // MARK: - Guardrails bind admin list endpoints

    /// The headline regression the fast paths hid: a tier-2 guardrail
    /// forbidding `site:read` bound a system admin on `GET /api/sites/:id` but
    /// *not* on `GET /api/sites`, because the list endpoint short-circuited on
    /// `isSystemAdmin` before asking the evaluator. Both must now deny.
    @Test("A guardrail forbidding site:read narrows a system admin's site list, not just item reads")
    func guardrailBindsAdminSiteList() async throws {
        try await withApp { app, builder in
            let org = try await builder.createOrganization(name: "Ceiling Org")
            let admin = try await builder.createUser(
                username: "ceil-admin", email: "ceil-admin@example.com", isSystemAdmin: true)
            let token = try await admin.generateAPIKey(on: app.db)

            let site = Site(name: "ceilinged-dc", organizationScope: .organization(try org.requireID()))
            try await site.save(on: app.db)

            try await rebuildPolicySet(app)

            // Baseline: with no ceiling the admin sees the site in the list.
            try await app.test(.GET, "/api/sites") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let sites = try res.content.decode([SiteResponse].self)
                #expect(sites.contains { $0.id == site.id })
            }

            // A forbid on the org ceilings everything beneath it, admins included.
            _ = try await GuardrailStore.create(
                name: "no-site-reads",
                description: nil,
                effect: nil,
                node: IAMNode(type: .organization, id: try org.requireID()),
                actions: ["site:read"],
                principalMatch: .any,
                resourceMatch: .any,
                createdBy: admin.id,
                on: app.db
            )
            try await rebuildPolicySet(app)

            try await app.test(.GET, "/api/sites/\(try site.requireID().uuidString)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }

            // The point of the change: the list is ceilinged too.
            try await app.test(.GET, "/api/sites") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let sites = try res.content.decode([SiteResponse].self)
                #expect(!sites.contains { $0.id == site.id })
            }
        }
    }

    // MARK: - Identity plane

    /// `platform-user-self` grants a non-admin their own record and nothing
    /// more; `platform-system-admin` covers everyone else's. Neither is a
    /// controller-local check any more.
    @Test("A non-admin reaches their own user record and not another's")
    func userSelfPolicyScopesToSelf() async throws {
        try await withApp { app, builder in
            let user = try await builder.createUser(username: "selfy", email: "selfy@example.com")
            let other = try await builder.createUser(username: "othery", email: "othery@example.com")
            let token = try await user.generateAPIKey(on: app.db)
            try await rebuildPolicySet(app)

            try await app.test(.GET, "/api/users/\(try user.requireID().uuidString)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            try await app.test(.GET, "/api/users/\(try other.requireID().uuidString)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    /// The limitation that falls out of user records being parentless: a
    /// guardrail attaches to a *node* and compiles to `resource in <node>`, and
    /// nothing is ever `in` a user record, so an org-scoped ceiling does not
    /// reach the identity plane. Pinned so the gap is a decision on record
    /// rather than a surprise — closing it means giving users a place in the
    /// tree, which multi-org membership currently rules out.
    @Test("An org-scoped guardrail does not reach user records — they are parentless")
    func orgGuardrailDoesNotReachUserRecords() async throws {
        try await withApp { app, builder in
            let org = try await builder.createOrganization(name: "Identity Org")
            let admin = try await builder.createUser(
                username: "id-admin", email: "id-admin@example.com", isSystemAdmin: true)
            let victim = try await builder.createUser(username: "victim", email: "victim@example.com")
            let token = try await admin.generateAPIKey(on: app.db)

            _ = try await GuardrailStore.create(
                name: "no-user-deletes",
                description: nil,
                effect: nil,
                node: IAMNode(type: .organization, id: try org.requireID()),
                actions: ["user:delete"],
                principalMatch: .any,
                resourceMatch: .any,
                createdBy: admin.id,
                on: app.db
            )
            try await rebuildPolicySet(app)

            try await app.test(.DELETE, "/api/users/\(try victim.requireID().uuidString)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }
        }
    }

    // MARK: - Agent restrictions, as policy

    /// `agent:updateArtifact` is a distinct action no seeded role carries, so
    /// an org admin holding `agent:manage` cannot install an arbitrary binary
    /// on the host.
    @Test("An org admin with agent:manage cannot override the update artifact")
    func artifactOverrideRequiresItsOwnAction() async throws {
        try await withApp { app, builder in
            let org = try await builder.createOrganization(name: "Artifact Org")
            let orgAdmin = try await builder.createUser(
                username: "art-admin", email: "art-admin@example.com", isSystemAdmin: false)
            try await RoleBindingService.grant(
                principalType: .user, principalID: try orgAdmin.requireID(), role: .admin,
                nodeType: .organization, nodeID: try org.requireID(), createdBy: nil, on: app.db)
            let token = try await orgAdmin.generateAPIKey(on: app.db)

            let agent = try await makeAgent(app, name: "artifact-agent", org: org)
            try await rebuildPolicySet(app)

            struct Body: Content {
                let artifactUrl: String
                let sha256: String
            }
            let path = "/api/agents/\(try agent.requireID().uuidString)/actions/update"
            try await app.test(.POST, path) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    Body(
                        artifactUrl: "https://evil.example.com/agent.tar.gz",
                        sha256: String(repeating: "ab", count: 32)))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
                #expect(res.body.string.contains("system admin"))
            }
        }
    }

    /// `platform-agent-foreign-workloads`: while an agent hosts another
    /// organization's VM, a delegated org admin may not force it offline. This
    /// used to be `requireNoForeignWorkloads` in the controller.
    @Test("A delegated org admin cannot force-offline an agent hosting another org's VM")
    func foreignWorkloadForbidBindsOrgAdmin() async throws {
        try await withApp { app, builder in
            let homeOrg = try await builder.createOrganization(name: "Home Org")
            let foreignOrg = try await builder.createOrganization(name: "Foreign Org")
            let orgAdmin = try await builder.createUser(
                username: "fw-admin", email: "fw-admin@example.com", isSystemAdmin: false)
            try await RoleBindingService.grant(
                principalType: .user, principalID: try orgAdmin.requireID(), role: .admin,
                nodeType: .organization, nodeID: try homeOrg.requireID(), createdBy: nil, on: app.db)
            let token = try await orgAdmin.generateAPIKey(on: app.db)

            let agent = try await makeAgent(app, name: "fw-agent", org: homeOrg)
            let path = "/api/agents/\(try agent.requireID().uuidString)/actions/force-offline"
            try await rebuildPolicySet(app)

            // With only its own org's workloads, the delegated admin may act.
            try await app.test(.POST, path) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status != .forbidden)
            }

            // Park a foreign-org VM on the agent; the forbid now fires.
            let foreignProject = try await builder.createProject(
                name: "Foreign Project", description: "d", organization: foreignOrg)
            let vm = try await builder.createVM(name: "foreign-vm", project: foreignProject)
            vm.hypervisorId = try agent.requireID().uuidString
            try await vm.save(on: app.db)

            try await app.test(.POST, path) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    /// The same forbid names `!principal.systemAdmin`, so a system admin still
    /// gets through — a `forbid` otherwise beats `platform-system-admin` too.
    @Test("A system admin can still force-offline an agent hosting a foreign VM")
    func foreignWorkloadForbidExemptsSystemAdmin() async throws {
        try await withApp { app, builder in
            let homeOrg = try await builder.createOrganization(name: "Home Org")
            let foreignOrg = try await builder.createOrganization(name: "Foreign Org")
            let admin = try await builder.createUser(
                username: "fw-sysadmin", email: "fw-sysadmin@example.com", isSystemAdmin: true)
            let token = try await admin.generateAPIKey(on: app.db)

            let agent = try await makeAgent(app, name: "fw-agent-2", org: homeOrg)

            let foreignProject = try await builder.createProject(
                name: "Foreign Project", description: "d", organization: foreignOrg)
            let vm = try await builder.createVM(name: "foreign-vm-2", project: foreignProject)
            vm.hypervisorId = try agent.requireID().uuidString
            try await vm.save(on: app.db)
            try await rebuildPolicySet(app)

            try await app.test(.POST, "/api/agents/\(try agent.requireID().uuidString)/actions/force-offline") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status != .forbidden)
            }
        }
    }
}
