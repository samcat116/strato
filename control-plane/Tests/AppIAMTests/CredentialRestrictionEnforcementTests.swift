import Fluent
import ControlPlanePostgres
import Foundation
import Testing
import Vapor
import VaporTesting

import AppTestSupport

@testable import App

/// STR-115 end to end: a credential's restriction intersected with its
/// principal's bindings, by the one evaluator, over real trees and real
/// bindings — and landing in `iam_decision_logs` like every other decision.
@Suite("Credential Restriction Enforcement", .serialized)
final class CredentialRestrictionEnforcementTests {

    private func withApp(_ test: (Application) async throws -> Void) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()
            app.iamDecisionLogConfig.recordDecisions = true
            try await test(app)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    private struct Tree {
        let org: Organization
        let project: Project
        let otherProject: Project
        let vm: VM
        let otherVM: VM
        let user: User
    }

    private func buildTree(_ app: Application, prefix: String, admin: Bool = false) async throws -> Tree {
        let builder = TestDataBuilder(db: app.db)
        let org = try await builder.createOrganization(name: "\(prefix) Org")
        let project = try await builder.createProject(
            name: "\(prefix) Project", description: "d", organization: org)
        let otherProject = try await builder.createProject(
            name: "\(prefix) Other", description: "d", organization: org)
        let vm = try await builder.createVM(name: "\(prefix)-vm", project: project)
        let otherVM = try await builder.createVM(name: "\(prefix)-other-vm", project: otherProject)
        let user = try await builder.createUser(
            username: "\(prefix)-user", email: "\(prefix)@example.com", isSystemAdmin: admin)
        try await builder.addUserToOrganization(user: user, organization: org, role: "member")
        // Editor at the organization, so every check below is a question about
        // the *credential*, never about a missing binding.
        try await RoleBindingService.grant(
            principalType: .user, principalID: try user.requireID(), role: .editor,
            nodeType: .organization, nodeID: try org.requireID(), createdBy: nil, on: app.db)
        return Tree(
            org: org, project: project, otherProject: otherProject, vm: vm, otherVM: otherVM, user: user)
    }

    /// One check with a credential's restriction in force, exactly as a request
    /// carrying that credential would make it.
    private func check(
        _ app: Application,
        user: User,
        action: String,
        node: IAMNode,
        restriction: CredentialRestriction,
        credential: CredentialReference? = CredentialReference(kind: .apiKey, id: UUID())
    ) async throws -> CedarCheckDecision {
        try await IAMAuthorizer.authorize(
            userID: try user.requireID(),
            action: action,
            node: node,
            context: IAMCheckContext(path: "/api/vms", method: "POST", requestID: nil),
            state: IAMRequestAuthState(restriction: restriction, credential: credential),
            app: app,
            db: app.db
        )
    }

    private func restriction(_ actions: [String], node: IAMNode? = nil) throws -> CredentialRestriction {
        try CredentialRestriction.validated(
            actions: actions, nodeType: node?.type.rawValue, nodeID: node?.id)
    }

    // MARK: - bindings ∩ restriction

    @Test("A restriction narrows what the bindings grant, and names itself in the decision")
    func restrictionNarrowsBindings() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "narrow")
            let vmNode = IAMNode(type: .virtualMachine, id: try tree.vm.requireID())

            let readOnly = try restriction(["vm:read"])
            let allowed = try await check(
                app, user: tree.user, action: "vm:read", node: vmNode, restriction: readOnly)
            #expect(allowed.allowed)

            let denied = try await check(
                app, user: tree.user, action: "vm:delete", node: vmNode, restriction: readOnly)
            #expect(!denied.allowed)
            #expect(denied.determiningPolicyIDs.contains(CedarCheckDecision.credentialRestrictionPolicyID))
            #expect(denied.tier == CedarCheckDecision.credentialTier)

            // Without the credential, the same principal may delete: the
            // restriction is the only thing that changed.
            let unrestricted = try await check(
                app, user: tree.user, action: "vm:delete", node: vmNode, restriction: .unrestricted,
                credential: nil)
            #expect(unrestricted.allowed)
        }
    }

    @Test("A restriction cannot grant what the bindings do not")
    func restrictionCannotGrant() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "No Grant Org")
            let project = try await builder.createProject(
                name: "No Grant Project", description: "d", organization: org)
            let vm = try await builder.createVM(name: "no-grant-vm", project: project)
            let stranger = try await builder.createUser(
                username: "stranger", email: "stranger@example.com")
            try await builder.addUserToOrganization(user: stranger, organization: org, role: "member")

            // A wide-open restriction over a principal with no VM binding is
            // still nothing: a restriction only ever subtracts.
            let decision = try await check(
                app, user: stranger, action: "vm:delete",
                node: IAMNode(type: .virtualMachine, id: try vm.requireID()),
                restriction: .unrestricted)
            #expect(!decision.allowed)
        }
    }

    /// A forbid beats every permit, `platform-system-admin` included. If it did
    /// not, the narrowest credential in the system would be the most powerful
    /// one whenever a system admin held it.
    @Test("A restricted credential binds a system admin")
    func restrictionBindsSystemAdmin() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "admin", admin: true)
            let vmNode = IAMNode(type: .virtualMachine, id: try tree.vm.requireID())

            #expect(
                try await check(
                    app, user: tree.user, action: "vm:delete", node: vmNode, restriction: .unrestricted
                ).allowed)

            let denied = try await check(
                app, user: tree.user, action: "vm:delete", node: vmNode,
                restriction: try restriction(["vm:read"]))
            #expect(!denied.allowed)
            #expect(denied.tier == CedarCheckDecision.credentialTier)
        }
    }

    // MARK: - Node scope

    @Test("A node-scoped credential reaches only its own subtree")
    func nodeScope() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "scoped")
            let projectNode = IAMNode(type: .project, id: try tree.project.requireID())
            let scoped = try restriction(["vm:*"], node: projectNode)

            let inScope = try await check(
                app, user: tree.user, action: "vm:delete",
                node: IAMNode(type: .virtualMachine, id: try tree.vm.requireID()), restriction: scoped)
            #expect(inScope.allowed)

            let outOfScope = try await check(
                app, user: tree.user, action: "vm:delete",
                node: IAMNode(type: .virtualMachine, id: try tree.otherVM.requireID()), restriction: scoped)
            #expect(!outOfScope.allowed)
            #expect(outOfScope.determiningPolicyIDs.contains(CedarCheckDecision.credentialRestrictionPolicyID))
        }
    }

    // MARK: - The membership probe (STR-203)

    /// What the probe does and does not set aside. The ceiling goes; the audit
    /// flags and the credential attribution stay, and an unrestricted state is
    /// handed straight back rather than copied.
    @Test("A membership probe suspends the ceiling and keeps the audit trail")
    func membershipProbeSuspendsCeilingAndSharesAudit() throws {
        let credential = CredentialReference(kind: .apiKey, id: UUID())
        let node = IAMNode(type: .project, id: UUID())
        let state = IAMRequestAuthState(
            restriction: try restriction(["vm:read"], node: node), credential: credential)
        let probe = state.membershipProbe()

        #expect(probe.restriction.isUnrestricted)
        #expect(probe.credential == credential)

        // The same boxes, not copies: a decision made through the probe is a
        // decision this request made.
        probe.decisionEvaluated.withLockedValue { $0 = true }
        probe.adminPolicyUsed.withLockedValue { $0 = true }
        #expect(state.decisionEvaluated.withLockedValue { $0 })
        #expect(state.adminPolicyUsed.withLockedValue { $0 })

        let unrestricted = IAMRequestAuthState()
        #expect(unrestricted.membershipProbe() === unrestricted)
    }

    /// The memo discipline behind the suspension. A probe's allow answers a
    /// *different* question than the same triple asked under the ceiling, so it
    /// must not be reusable as the second one — which is why the credential
    /// restriction is part of `IAMRequestCache.DecisionKey`.
    @Test("A probe's allow does not answer the same check made under the ceiling")
    func probeAllowDoesNotAnswerARestrictedCheck() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "probe")
            let projectNode = IAMNode(type: .project, id: try tree.project.requireID())
            let state = IAMRequestAuthState(
                restriction: try restriction(["vm:read"], node: projectNode),
                credential: CredentialReference(kind: .apiKey, id: UUID()))
            let cache = IAMRequestCache()
            let context = IAMCheckContext(path: "/api/vms", method: "GET", requestID: nil)

            let orgNode = IAMNode(type: .organization, id: try tree.org.requireID())
            let probed = try await IAMAuthorizer.authorize(
                principal: .user(try tree.user.requireID()),
                action: "org:read",
                node: orgNode,
                context: context,
                state: state.membershipProbe(),
                cache: cache,
                app: app,
                db: app.db)
            #expect(probed.allowed, "the probe asks about the principal, and this one is a member")

            let underTheCeiling = try await IAMAuthorizer.authorize(
                principal: .user(try tree.user.requireID()),
                action: "org:read",
                node: orgNode,
                context: context,
                state: state,
                cache: cache,
                app: app,
                db: app.db)
            #expect(!underTheCeiling.allowed, "the probe's answer must not be reused for the real question")
        }
    }

    // MARK: - Batch filtering

    @Test("A batched list filters to the credential's subtree")
    func batchFiltersByNodeScope() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "batch")
            let projectNode = IAMNode(type: .project, id: try tree.project.requireID())
            let inScope = IAMNode(type: .virtualMachine, id: try tree.vm.requireID())
            let outOfScope = IAMNode(type: .virtualMachine, id: try tree.otherVM.requireID())

            let decisions = try await IAMAuthorizer.authorize(
                principal: .user(try tree.user.requireID()),
                action: "vm:read",
                nodes: [inScope, outOfScope],
                context: IAMCheckContext(path: "/api/vms", method: "GET", requestID: nil),
                state: IAMRequestAuthState(restriction: try restriction(["vm:*"], node: projectNode)),
                app: app,
                db: app.db)

            #expect(decisions[inScope]?.allowed == true)
            #expect(decisions[outOfScope]?.allowed == false)
        }
    }

    /// The action half is constant across a batch, so a list the credential
    /// cannot read at all comes back empty — the same shape an unbound user
    /// sees — rather than throwing. A list that 500s because of a narrow token
    /// would be a worse answer than an empty page.
    @Test("A batched list the credential cannot read at all is empty, not an error")
    func batchWithExcludedActionIsEmpty() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "empty")
            let nodes = [
                IAMNode(type: .virtualMachine, id: try tree.vm.requireID()),
                IAMNode(type: .virtualMachine, id: try tree.otherVM.requireID()),
            ]

            let decisions = try await IAMAuthorizer.authorize(
                principal: .user(try tree.user.requireID()),
                action: "vm:read",
                nodes: nodes,
                context: IAMCheckContext(path: "/api/vms", method: "GET", requestID: nil),
                state: IAMRequestAuthState(restriction: try restriction(["volume:read"])),
                app: app,
                db: app.db)

            #expect(decisions.count == 2)
            #expect(decisions.values.allSatisfy { !$0.allowed })
        }
    }

    // MARK: - The decision log

    @Test("Decision rows name the credential, on allows as well as denies")
    func decisionRowsCarryTheCredential() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "logged")
            let vmNode = IAMNode(type: .virtualMachine, id: try tree.vm.requireID())
            let credentialID = UUID()
            let credential = CredentialReference(kind: .cliSession, id: credentialID)

            _ = try await check(
                app, user: tree.user, action: "vm:read", node: vmNode,
                restriction: try restriction(["vm:read"]), credential: credential)
            _ = try await check(
                app, user: tree.user, action: "vm:delete", node: vmNode,
                restriction: try restriction(["vm:read"]), credential: credential)

            await app.iamDecisionRecorder.flush()
            let rows = try await app.decisionLogsPersistence.entries(
                matching: DecisionLogFilter(credentialID: credentialID),
                limit: 500
            ).entries
            #expect(rows.count == 2)
            #expect(rows.allSatisfy { $0.credentialType == "cli_session" })

            let allow = try #require(rows.first { $0.action == "vm:read" })
            #expect(allow.decision == "allow")
            let deny = try #require(rows.first { $0.action == "vm:delete" })
            #expect(deny.decision == "deny")
            #expect(deny.tier == CedarCheckDecision.credentialTier)
            #expect(deny.determiningPolicies.contains(CedarCheckDecision.credentialRestrictionPolicyID))
        }
    }

    /// A workload's SVID names a principal and carries no restriction, so its
    /// requests must be indistinguishable from what they were before STR-115.
    @Test("A request with no credential records none and is evaluated unrestricted")
    func noCredentialRecordsNone() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "svid")
            let vmNode = IAMNode(type: .virtualMachine, id: try tree.vm.requireID())

            let decision = try await check(
                app, user: tree.user, action: "vm:delete", node: vmNode,
                restriction: .unrestricted, credential: nil)
            #expect(decision.allowed)

            await app.iamDecisionRecorder.flush()
            let rows = try await app.decisionLogsPersistence.entries(
                matching: DecisionLogFilter(nodeID: vmNode.id),
                limit: 500
            ).entries
            #expect(!rows.isEmpty)
            #expect(rows.allSatisfy { $0.credentialType == nil && $0.credentialID == nil })
        }
    }

    // MARK: - The handler helpers that skip the evaluator

    /// `requireSystemAdmin`, `allowsScopelessPlatformRow` and
    /// `markRowScopedAuthorization` satisfy the default-deny assertion without
    /// making a Cedar decision, so a restriction has nothing to intersect with
    /// there and each has to say so itself.
    /// A request carrying a restricted API key, built through the real
    /// plumbing: the authenticators set `request.apiKey`, and `iamAuthState`
    /// derives the restriction from it on first use.
    private func request(
        _ app: Application, method: HTTPMethod, user: User, restriction: CredentialRestriction
    ) -> Request {
        let request = Request(
            application: app, method: method, url: "/api/audit-events", on: app.eventLoopGroup.next())
        request.auth.login(user)
        request.apiKey = APIKeySnapshot(
            id: UUID(),
            userID: (try? user.requireID()) ?? UUID(),
            name: "k",
            keyPrefix: "p",
            restriction: restriction.stored
        )
        return request
    }

    @Test("requireSystemAdmin keeps reads for an action-limited credential and refuses its mutations")
    func requireSystemAdminUnderRestriction() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let admin = try await builder.createUser(
                username: "helper-admin", email: "helper-admin@example.com", isSystemAdmin: true)
            let readOnly = CredentialRestriction.readOnly

            // A read-only key held by an admin can still use admin GET surfaces.
            _ = try await request(app, method: .GET, user: admin, restriction: readOnly)
                .requireSystemAdmin()

            var thrown: (any Error)?
            do {
                _ = try await request(app, method: .POST, user: admin, restriction: readOnly)
                    .requireSystemAdmin()
            } catch {
                thrown = error
            }
            #expect((thrown as? any AbortError)?.status == .forbidden)

            // A node-scoped credential is refused on any method: a token issued
            // for one project has no business on a global platform surface.
            let scoped = try restriction(["*"], node: IAMNode(type: .project, id: UUID()))
            var scopedThrown: (any Error)?
            do {
                _ = try await request(app, method: .GET, user: admin, restriction: scoped)
                    .requireSystemAdmin()
            } catch {
                scopedThrown = error
            }
            #expect((scopedThrown as? any AbortError)?.status == .forbidden)
        }
    }

    @Test("allowsScopelessPlatformRow honours the action half and refuses node-scoped credentials")
    func scopelessPlatformRowUnderRestriction() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let admin = try await builder.createUser(
                username: "row-admin", email: "row-admin@example.com", isSystemAdmin: true)

            // A read-only credential can see a scopeless row when its action
            // restriction covers the row's read action.
            #expect(
                request(app, method: .GET, user: admin, restriction: .readOnly)
                    .allowsScopelessPlatformRow(action: "agent:read"))

            #expect(
                !request(app, method: .GET, user: admin, restriction: try restriction(["vm:read"]))
                    .allowsScopelessPlatformRow(action: "agent:read"))

            // A scopeless row is outside every subtree by definition.
            #expect(
                !request(
                    app, method: .GET, user: admin,
                    restriction: try restriction(["*"], node: IAMNode(type: .project, id: UUID()))
                ).allowsScopelessPlatformRow(action: "agent:read"))
        }
    }

    /// `iamAuthState` is created on first use, and only middleware *ordering*
    /// guarantees that first use comes after authentication. Nothing enforces
    /// that ordering, and a snapshot taken too early would be fail-*open*: the
    /// state would hold `.unrestricted` for the rest of the request and every
    /// restricted credential on it would wield full principal power. The
    /// credential half is therefore re-derived on every access.
    @Test("A state built before authentication does not freeze a credential as unrestricted")
    func authStateIsNotAStaleSnapshot() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "early-user", email: "early-user@example.com")

            let request = Request(
                application: app, method: .POST, url: "/api/vms", on: app.eventLoopGroup.next())
            // Stand in for a middleware registered above the authenticators
            // that touches the state — `AuditMiddleware.adminBypassUsed` is the
            // realistic one.
            #expect(request.iamAuthState.restriction.isUnrestricted)

            request.auth.login(user)
            request.apiKey = APIKeySnapshot(
                id: UUID(),
                userID: try user.requireID(),
                name: "k",
                keyPrefix: "p",
                restriction: try restriction(["vm:read"]).stored
            )

            #expect(!request.iamAuthState.restriction.isUnrestricted)
            #expect(request.iamAuthState.restriction.permits(action: "vm:read"))
            #expect(!request.iamAuthState.restriction.permits(action: "vm:delete"))
            #expect(request.iamAuthState.credential?.kind == .apiKey)
        }
    }

    @Test("A refusal outside the evaluator is still attributable in the decision log")
    func nonEvaluatorRefusalIsRecorded() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "row-user", email: "row-user@example.com")

            let request = self.request(
                app, method: .POST, user: user, restriction: .readOnly)
            var thrown: (any Error)?
            do { try await request.markRowScopedAuthorization() } catch { thrown = error }
            #expect((thrown as? any AbortError)?.status == .forbidden)

            await app.iamDecisionRecorder.flush()
            let rows = try await app.decisionLogsPersistence.entries(
                matching: DecisionLogFilter(decision: "credential_restricted"),
                limit: 500
            ).entries
            #expect(rows.count == 1)
            let row = try #require(rows.first)
            #expect(row.action == nil)
            #expect(row.nodeType == nil)
            #expect(row.nodeID == nil)
            #expect(row.tier == CedarCheckDecision.credentialTier)
            #expect(row.credentialType == "api_key")
        }
    }

    // MARK: - Guardrails cover credentials for free

    @Test("A guardrail and a restriction both denying attribute to the guardrail")
    func guardrailOutranksCredentialInAttribution() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "ceiling")
            let vmNode = IAMNode(type: .virtualMachine, id: try tree.vm.requireID())

            _ = try await GuardrailStore.create(
                name: "no vm deletes",
                description: nil,
                effect: nil,
                node: IAMNode(type: .organization, id: try tree.org.requireID()),
                actions: ["vm:delete"],
                principalMatch: .any,
                resourceMatch: .any,
                createdBy: nil,
                on: app.db)
            let version = try await PolicySetVersionService.current(on: app.db)
            await app.cedarPolicySet.rebuild(version: version, on: app.db)

            let decision = try await check(
                app, user: tree.user, action: "vm:delete", node: vmNode,
                restriction: try restriction(["vm:read"]))
            #expect(!decision.allowed)
            #expect(decision.determiningPolicyIDs.contains(CedarCheckDecision.credentialRestrictionPolicyID))
            #expect(decision.determiningPolicyIDs.contains { $0.hasPrefix("guardrail-") })
            // A ceiling denies this request and every future one from anybody;
            // a restriction denies only this token. The stronger statement wins
            // the attribution, and `determining_policies` keeps both.
            #expect(decision.tier == "guardrail")
        }
    }
}
