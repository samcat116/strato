import ControlPlanePostgres
import Foundation
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

/// The authoritative Cedar evaluator and the canonical decision log it writes.
/// These checks exercise real trees, bindings, and the real engine, then
/// assert on both the enforced verdict and the recorded row.
@Suite("IAM Authorizer Tests", .serialized)
final class IAMAuthorizerTests {

    private func withApp(_ test: (Application) async throws -> Void) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            // Enable decision-row recording (off by default under .testing).
            // After configure — which resets the config from the environment —
            // and before the recorder is lazily built with it at boot.
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
        let vm: VM
        let user: User
    }

    private func buildTree(_ app: Application, prefix: String) async throws -> Tree {
        let builder = TestDataBuilder(db: app.testPostgres)
        let org = try await builder.createOrganization(name: "\(prefix) Org")
        let project = try await builder.createProject(
            name: "\(prefix) Project", description: "d", organization: org)
        let vm = try await builder.createVM(name: "\(prefix)-vm", project: project)
        let user = try await builder.createUser(
            username: "\(prefix)-user", email: "\(prefix)@example.com")
        try await builder.addUserToOrganization(user: user, organization: org, role: "member")
        return Tree(org: org, project: project, vm: vm, user: user)
    }

    /// Run one canonical action/node check exactly as `req.can` would.
    private func check(
        _ app: Application,
        user: User,
        action: String,
        node: IAMNode,
        path: String = "/api/vms",
        state: IAMRequestAuthState = .detached,
        cache: IAMRequestCache? = nil
    ) async throws -> Bool {
        try await IAMAuthorizer.authorize(
            principal: .user(user.id!),
            action: action,
            node: node,
            context: IAMCheckContext(path: path, method: "GET", requestID: "test-request"),
            state: state,
            cache: cache,
            app: app,
            db: app.testPostgres
        ).allowed
    }

    /// The decision row is written by the batching drain; flush it out first.
    private func onlyEntry(_ app: Application) async throws -> DecisionLogSnapshot {
        await app.iamDecisionRecorder.flush()
        let entries = try await app.decisionLogsPersistence.entries(limit: 500).entries
        #expect(entries.count == 1)
        return try #require(entries.first)
    }

    @Test("An allowed check records the decision with policy, tier, and version")
    func allowRecorded() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "agree")
            try await RoleBindingService.grant(
                principalType: .user, principalID: tree.user.id!, role: .viewer,
                nodeType: .project, nodeID: tree.project.id!, createdBy: nil, on: app.testPostgres)
            let version = try await PolicySetVersionService.current(on: app.testPostgres)
            await app.cedarPolicySet.rebuild(version: version, on: app.testPostgres)

            let allowed = try await check(
                app, user: tree.user, action: "vm:read",
                node: IAMNode(type: .virtualMachine, id: tree.vm.id!))
            #expect(allowed)

            let entry = try await onlyEntry(app)
            #expect(entry.decision == "allow")
            #expect(entry.action == "vm:read")
            #expect(entry.nodeType == IAMNodeType.virtualMachine.rawValue)
            #expect(entry.nodeID == tree.vm.id)
            #expect(entry.tier == "grant")
            #expect(entry.determiningPolicies == [RoleDescriptor.policyID(IAMRole.viewer.seededID)])
            #expect(entry.policyVersion == version)
            #expect(entry.organizationID == tree.org.id)
            #expect(entry.requestID == "test-request")
        }
    }

    @Test("A deny is enforced and recorded")
    func denyEnforcedAndRecorded() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "mismatch")
            // No binding: Cedar denies (org members no longer see every
            // project).
            let version = try await PolicySetVersionService.current(on: app.testPostgres)
            await app.cedarPolicySet.rebuild(version: version, on: app.testPostgres)

            let allowed = try await check(
                app, user: tree.user, action: "project:read",
                node: IAMNode(type: .project, id: tree.project.id!))
            #expect(!allowed)

            let entry = try await onlyEntry(app)
            #expect(entry.decision == "deny")
            #expect(entry.action == "project:read")
            #expect(entry.tier == "default-deny")
            #expect(entry.determiningPolicies.isEmpty)
        }
    }

    @Test("A guardrail forbids even an org admin, and the row names the ceiling")
    func guardrailBindsAndIsNamed() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "ceiling")
            try await RoleBindingService.grant(
                principalType: .user, principalID: tree.user.id!, role: .admin,
                nodeType: .organization, nodeID: tree.org.id!, createdBy: nil, on: app.testPostgres)
            let guardrail = try await GuardrailStore.create(
                name: "no-vm-lifecycle", description: nil, effect: nil,
                node: IAMNode(type: .organization, id: tree.org.id!),
                actions: ["vm:*"], principalMatch: .any, resourceMatch: .any,
                createdBy: nil, on: app.testPostgres)
            let version = try await PolicySetVersionService.current(on: app.testPostgres)
            await app.cedarPolicySet.rebuild(version: version, on: app.testPostgres)

            let allowed = try await check(
                app, user: tree.user, action: "vm:start",
                node: IAMNode(type: .virtualMachine, id: tree.vm.id!))
            #expect(!allowed)

            let entry = try await onlyEntry(app)
            #expect(entry.decision == "deny")
            #expect(entry.tier == "guardrail")
            #expect(entry.determiningPolicies == ["guardrail-\(guardrail.id.uuidString.lowercased())"])
        }
    }

    @Test("A repeat of the same check in one request is decided and recorded once")
    func requestScopedDecisionMemo() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "memo")
            try await RoleBindingService.grant(
                principalType: .user, principalID: tree.user.id!, role: .viewer,
                nodeType: .project, nodeID: tree.project.id!, createdBy: nil, on: app.testPostgres)
            let version = try await PolicySetVersionService.current(on: app.testPostgres)
            await app.cedarPolicySet.rebuild(version: version, on: app.testPostgres)

            // The shape of a guarded object route: the middleware checks, then
            // the handler re-checks the identical triple through
            // `Request.authorizedVM`.
            let cache = IAMRequestCache()
            let state = IAMRequestAuthState()
            let node = IAMNode(type: .virtualMachine, id: tree.vm.id!)
            let middleware = try await check(
                app, user: tree.user, action: "vm:read", node: node, state: state, cache: cache)
            let handler = try await check(
                app, user: tree.user, action: "vm:read", node: node, state: state, cache: cache)
            #expect(middleware)
            #expect(handler)
            // The memoized answer still counts as a decision this request made.
            #expect(state.decisionEvaluated.withLockedValue { $0 })

            let entry = try await onlyEntry(app)
            #expect(entry.action == "vm:read")
            // The row count is the point: one question, one decision, one row.
            try await Task.sleep(for: .milliseconds(250))
            let rows = try await app.decisionLogsPersistence.entries(limit: 500).total
            #expect(rows == 1)
        }
    }

    @Test("The request memo is keyed by the whole check, not just the resource")
    func requestMemoDoesNotConflateChecks() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "memokey")
            try await RoleBindingService.grant(
                principalType: .user, principalID: tree.user.id!, role: .viewer,
                nodeType: .project, nodeID: tree.project.id!, createdBy: nil, on: app.testPostgres)
            let version = try await PolicySetVersionService.current(on: app.testPostgres)
            await app.cedarPolicySet.rebuild(version: version, on: app.testPostgres)

            // Same principal, same VM, different action: a viewer may read it
            // but not start it, so a memo keyed on the resource alone would
            // hand back the wrong verdict.
            let cache = IAMRequestCache()
            let node = IAMNode(type: .virtualMachine, id: tree.vm.id!)
            let read = try await check(
                app, user: tree.user, action: "vm:read", node: node, cache: cache)
            let start = try await check(
                app, user: tree.user, action: "vm:start", node: node, cache: cache)
            #expect(read)
            #expect(!start)
        }
    }

    @Test("With no compiled policy set the evaluator fails closed with 503, not a silent deny")
    func failsClosedWithoutCompiledSet() async throws {
        // A bare app whose Cedar cache was never built (configure() would
        // build it): the evaluator must refuse to answer rather than deny —
        // or worse, allow. The policy-set check precedes every database read,
        // so no migrations are needed here.
        let app = try await Application.makeForBareDatabaseTesting()
        var thrown: (any Error)?
        do {
            _ = try await IAMAuthorizer.authorize(
                userID: UUID(),
                action: "vm:read",
                node: IAMNode(type: .virtualMachine, id: UUID()),
                context: IAMCheckContext(path: "/api/vms", method: "GET", requestID: nil),
                state: .detached,
                app: app,
                db: app.testPostgres
            )
        } catch {
            thrown = error
        }
        #expect((thrown as? any AbortError)?.status == .serviceUnavailable)
        try await app.shutdownForTesting()
    }

    @Test("Bare org membership allows org:read through the org-membership platform policy")
    func membershipGrant() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "member")
            let version = try await PolicySetVersionService.current(on: app.testPostgres)
            await app.cedarPolicySet.rebuild(version: version, on: app.testPostgres)

            let allowed = try await check(
                app, user: tree.user, action: "org:read",
                node: IAMNode(type: .organization, id: tree.org.id!))
            #expect(allowed)

            let entry = try await onlyEntry(app)
            #expect(entry.decision == "allow")
            #expect(entry.tier == "platform")
            #expect(entry.determiningPolicies == ["org-membership"])
        }
    }

    @Test("A system admin is allowed by the platform policy and flagged for the audit trail")
    func adminThroughEvaluator() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "admin")
            let admin = try await TestDataBuilder(db: app.testPostgres).createUser(
                username: "authz-admin", email: "authz-admin@example.com", isSystemAdmin: true)
            let version = try await PolicySetVersionService.current(on: app.testPostgres)
            await app.cedarPolicySet.rebuild(version: version, on: app.testPostgres)

            let state = IAMRequestAuthState()
            let allowed = try await check(
                app, user: admin, action: "vm:read",
                node: IAMNode(type: .virtualMachine, id: tree.vm.id!), state: state)
            #expect(allowed)
            // The bypass flag now derives from the determining policy — this
            // is what AuditMiddleware records as an admin audit event.
            #expect(state.adminPolicyUsed.withLockedValue { $0 })

            let entry = try await onlyEntry(app)
            #expect(entry.tier == "platform")
            #expect(entry.determiningPolicies == ["platform-system-admin"])
        }
    }

    @Test("Request.can evaluates a canonical action and node and records the row")
    func canonicalRequestCanIsCedar() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "e2e")
            let version = try await PolicySetVersionService.current(on: app.testPostgres)
            await app.cedarPolicySet.rebuild(version: version, on: app.testPostgres)

            let request = Request(application: app, method: .GET, url: "/api/vms", on: app.eventLoopGroup.next())
            request.auth.login(tree.user)

            // No binding on the VM's project: Cedar denies.
            let allowed = try await request.can(
                "vm:read", on: IAMNode(type: .virtualMachine, id: tree.vm.id!))
            #expect(!allowed)

            let entry = try await onlyEntry(app)
            #expect(entry.decision == "deny")
            #expect(entry.action == "vm:read")
            #expect(entry.path == "/api/vms")
        }
    }

    /// The queue is what keeps decision recording off the connection pool
    /// (#736): checks buffer here and one drain writes them in batches, rather
    /// than each check taking a connection from a Fluent pool that defaults to
    /// one connection per event loop.
    @Test("Separately recorded decisions coalesce into one batch, and overflow is shed")
    func queueBatchesAndSheds() async throws {
        let queue = IAMDecisionQueue(maxQueueDepth: 3, maxBatchSize: 8)

        // The shape a VM create makes: three separate checks, each recording
        // on its own. Only the first starts a drain, and all three leave in
        // one batch — that is the whole point of the change.
        let first = await queue.enqueue([sample(path: "/api/vms")])
        #expect(first == .init(accepted: 1, shed: 0, shedTotal: 0, startDrain: true))
        let second = await queue.enqueue([sample(path: "/api/vms")])
        #expect(second == .init(accepted: 1, shed: 0, shedTotal: 0, startDrain: false))
        _ = await queue.enqueue([sample(path: "/api/vms")])

        // A fourth arriving with a batch of two takes the one remaining slot
        // and sheds the rest: partial acceptance, so a large list decision
        // arriving at a full queue writes what fits instead of losing all of it.
        let overflow = await queue.enqueue([sample(path: "/api/vms"), sample(path: "/api/vms")])
        #expect(overflow == .init(accepted: 0, shed: 2, shedTotal: 2, startDrain: false))

        let batch = try #require(await queue.nextBatch())
        #expect(batch.count == 3)
        // The claimed batch is still in the air until it is reported written.
        #expect(await queue.isIdle == false)
        await queue.finishBatch()
        #expect(await queue.isIdle)
        #expect(await queue.stats.shed == 2)
    }

    /// The create-shaped request — three checks, three decisions — still
    /// records every one of them, and the flush is what a caller waits on
    /// instead of a sleep.
    @Test("Every check of a multi-check request is recorded")
    func multiCheckRequestRecordsEveryDecision() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "multi")
            let version = try await PolicySetVersionService.current(on: app.testPostgres)
            await app.cedarPolicySet.rebuild(version: version, on: app.testPostgres)

            let node = IAMNode(type: .virtualMachine, id: tree.vm.id!)
            for action in ["vm:read", "vm:update", "vm:delete"] {
                _ = try await check(
                    app, user: tree.user, action: action, node: node)
            }
            await app.iamDecisionRecorder.flush()

            let actions = try await app.decisionLogsPersistence.entries(limit: 500).entries.compactMap(\.action)
            #expect(Set(actions) == ["vm:read", "vm:update", "vm:delete"])
        }
    }

    private func sample(path: String) -> PendingIAMDecision {
        .evaluated(
            IAMDecisionRecord(
                subject: UUID().uuidString,
                action: "vm:read",
                node: IAMNode(type: .virtualMachine, id: UUID()),
                organizationID: nil,
                skippedConditionedBindings: 0,
                decision: CedarCheckDecision(
                    allowed: true, determiningPolicyIDs: ["role-viewer"], evaluationErrors: []),
                policyVersion: 1,
                credential: nil,
                context: IAMCheckContext(path: path, method: "GET", requestID: "test-request")))
    }

    @Test("The retention sweep prunes rows older than the window")
    func retentionSweep() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "sweep")
            let version = try await PolicySetVersionService.current(on: app.testPostgres)
            await app.cedarPolicySet.rebuild(version: version, on: app.testPostgres)
            _ = try await check(
                app, user: tree.user, action: "org:read",
                node: IAMNode(type: .organization, id: tree.org.id!))
            let entry = try await onlyEntry(app)

            // Age the row past the window, then sweep.
            let old = Date().addingTimeInterval(-Double(app.iamDecisionLogConfig.retentionDays + 1) * 86_400)
            _ = try await app.decisionLogsPersistence.delete(createdBefore: .distantFuture)
            _ = try await app.decisionLogsPersistence.append([
                DecisionLogWrite(copying: entry, createdAt: old)
            ])

            await app.iamDecisionRecorder.sweepExpiredEntries()
            let remaining = try await app.decisionLogsPersistence.entries(limit: 500).total
            #expect(remaining == 0)
        }
    }
}

// MARK: - Review follow-ups (#482 PR review)

/// The fail-loud backstops themselves, and the truncated-chain fail-closed
/// rule the review called out: nets are only nets if a regression in them
/// fails a test.
@Suite("IAM Authorizer Backstop Tests", .serialized)
final class IAMAuthorizerBackstopTests {

    private func withApp(_ test: (Application) async throws -> Void) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            app.iamDecisionLogConfig.recordDecisions = true
            try await test(app)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    @Test("A truncated ancestor chain is denied outright — a ceiling must not silently detach")
    func truncatedChainFailsClosed() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.testPostgres)
            // A network in a project that belongs to no organization: the chain
            // is [network, project] and never reaches an organization, so an
            // org-anchored guardrail could not match it.
            let orphanProject = try await builder.createProject(
                name: "Orphan Project", description: "no organization")
            // The network's required site must not repair the intentionally
            // truncated ownership chain, so keep it scopeless as well.
            let orphanSite = Site(name: "orphan-site")
            try await orphanSite.save(on: app.testPostgres)
            let network = LogicalNetwork(
                name: "orphan-net", subnet: "10.99.0.0/24", gateway: "10.99.0.1",
                projectID: try orphanProject.requireID(), externalAccess: false,
                siteID: try orphanSite.requireID())
            try await network.save(on: app.testPostgres)

            let user = try await builder.createUser(
                username: "trunc-user", email: "trunc-user@example.com")
            // Even a direct admin binding on the network itself must not win:
            // the in-chain permit is exactly what would fire while the ceiling
            // above the break could not.
            try await RoleBindingService.grant(
                principalType: .user, principalID: user.id!, role: .admin,
                nodeType: .network, nodeID: network.id!, createdBy: nil, on: app.testPostgres)
            let version = try await PolicySetVersionService.current(on: app.testPostgres)
            await app.cedarPolicySet.rebuild(version: version, on: app.testPostgres)

            let state = IAMRequestAuthState()
            let decision = try await IAMAuthorizer.authorize(
                userID: user.id!,
                action: "network:read",
                node: IAMNode(type: .network, id: network.id!),
                context: IAMCheckContext(path: "/api/networks", method: "GET", requestID: nil),
                state: state,
                app: app,
                db: app.testPostgres
            )
            #expect(!decision.allowed)
            #expect(decision.determiningPolicyIDs.isEmpty)
            #expect(state.decisionEvaluated.withLockedValue { $0 })
        }
    }

    @Test("A network is readable only through a grant on its project's chain")
    func networkReadRequiresAGrant() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.testPostgres)
            let org = try await builder.createOrganization(name: "Net Read Org")
            let project = try await builder.createProject(
                name: "Net Read Project", description: "d", organization: org)
            let network = try await builder.createNetwork(
                name: "read-net", project: project, subnet: "10.98.0.0/24", gateway: "10.98.0.1",
                externalAccess: false)
            let user = try await builder.createUser(
                username: "net-read-user", email: "net-read-user@example.com")
            let version = try await PolicySetVersionService.current(on: app.testPostgres)
            await app.cedarPolicySet.rebuild(version: version, on: app.testPostgres)

            let node = IAMNode(type: .network, id: network.id!)
            let context = IAMCheckContext(path: "/api/networks", method: "GET", requestID: nil)

            // Nothing is world-readable any more: the permit that made
            // project-less networks open to every authenticated user went away
            // with global networks themselves (issue #765).
            let ungranted = try await IAMAuthorizer.authorize(
                userID: user.id!, action: "network:read", node: node,
                context: context, state: .detached, app: app, db: app.testPostgres)
            #expect(!ungranted.allowed)

            try await RoleBindingService.grant(
                principalType: .user, principalID: user.id!, role: .viewer,
                nodeType: .project, nodeID: project.id!, createdBy: nil, on: app.testPostgres)

            let granted = try await IAMAuthorizer.authorize(
                userID: user.id!, action: "network:read", node: node,
                context: context, state: .detached, app: app, db: app.testPostgres)
            #expect(granted.allowed)
        }
    }

    @Test("requireSystemAdmin denies non-admins, marks the decision, and flags admins for audit")
    func requireSystemAdminBranches() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.testPostgres)
            let user = try await builder.createUser(username: "rsa-user", email: "rsa-user@example.com")
            let admin = try await builder.createUser(
                username: "rsa-admin", email: "rsa-admin@example.com", isSystemAdmin: true)

            let denied = Request(
                application: app, method: .GET, url: "/api/audit-events", on: app.eventLoopGroup.next())
            denied.auth.login(user)
            var thrown: (any Error)?
            do { _ = try await denied.requireSystemAdmin() } catch { thrown = error }
            #expect((thrown as? any AbortError)?.status == .forbidden)
            #expect(denied.iamAuthState.decisionEvaluated.withLockedValue { $0 })
            #expect(!denied.iamAuthState.adminPolicyUsed.withLockedValue { $0 })

            let allowed = Request(
                application: app, method: .GET, url: "/api/audit-events", on: app.eventLoopGroup.next())
            allowed.auth.login(admin)
            _ = try await allowed.requireSystemAdmin()
            #expect(allowed.iamAuthState.adminPolicyUsed.withLockedValue { $0 })

            let anonymous = Request(
                application: app, method: .GET, url: "/api/audit-events", on: app.eventLoopGroup.next())
            var anonThrown: (any Error)?
            do { _ = try await anonymous.requireSystemAdmin() } catch { anonThrown = error }
            #expect((anonThrown as? any AbortError)?.status == .unauthorized)
        }
    }

    @Test("A handler-checked mutation that evaluates nothing is a hard 500 under .testing")
    func handlerAssertionCatchesMissingCheck() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.testPostgres)
            let user = try await builder.createUser(
                username: "forgetful-user", email: "forgetful-user@example.com")

            struct SilentOK: AsyncResponder {
                func respond(to request: Request) async throws -> Response {
                    Response(status: .ok)  // a handler that forgot its check
                }
            }
            let request = Request(
                application: app, method: .POST, url: "/api/sites", on: app.eventLoopGroup.next())
            request.auth.login(user)
            var thrown: (any Error)?
            do {
                _ = try await AuthorizationMiddleware().respond(to: request, chainingTo: SilentOK())
            } catch {
                thrown = error
            }
            #expect((thrown as? any AbortError)?.status == .internalServerError)

            // The same handler with a recorded decision passes through.
            let checked = Request(
                application: app, method: .POST, url: "/api/sites", on: app.eventLoopGroup.next())
            checked.auth.login(user)
            try await checked.markRowScopedAuthorization()
            let res = try await AuthorizationMiddleware().respond(to: checked, chainingTo: SilentOK())
            #expect(res.status == .ok)
        }
    }

    @Test("Sensitive routes pin their classification")
    func routeClassificationPinned() async throws {
        let id = UUID().uuidString
        typealias M = AuthorizationMiddleware
        // Public stays exactly the audited allowlist.
        #expect(M.classify(path: "/auth/login/begin") == .isPublic)
        #expect(M.classify(path: "/api/users/register") == .isPublic)
        #expect(M.classify(path: "/organizations/\(id)/scim/v2/Users") == .isPublic)
        #expect(M.classify(path: "/api/projects/\(id)/images/\(id)/download") == .isPublic)
        #expect(M.classify(path: "/api/sandboxes/\(id)/snapshots/\(id)/artifacts/rootfs") == .isPublic)
        #expect(M.classify(path: "/agent/desired-state") == .isPublic)
        #expect(M.classify(path: "/api/agent-enrollments/install") == .isPublic)
        #expect(M.classify(path: "/api/agent-enrollments/bootstrap") == .isPublic)
        // Matched exactly, not by prefix: neither a sibling under `/agent/` nor
        // a longer path that merely starts with it may inherit public access.
        #expect(M.classify(path: "/agent/something-else") == nil)
        #expect(M.classify(path: "/agent/desired-state-history") == nil)
        #expect(M.classify(path: "/api/agent-enrollments/bootstrap-history") == .handlerChecked)
        // Identity-plane.
        #expect(M.classify(path: "/api/api-keys") == .loginOnly)
        #expect(M.classify(path: "/api/authorization/check") == .loginOnly)
        // Middleware-mapped resources.
        if case .resource(let guarded)? = M.classify(path: "/api/vms/\(id)/start") {
            #expect(guarded.nodeType == .virtualMachine)
        } else {
            Issue.record("expected /api/vms to be resource-mapped")
        }
        // Handler-checked (the evaluator runs in the handler).
        #expect(M.classify(path: "/api/organizations/\(id)/members") == .handlerChecked)
        #expect(M.classify(path: "/api/load-balancers/\(id)/listeners") == .handlerChecked)
        #expect(M.classify(path: "/api/iam/guardrails") == .handlerChecked)
        #expect(M.classify(path: "/organizations/\(id)/settings/scim-tokens") == .handlerChecked)
        // Unknown paths classify as nothing — denied.
        #expect(M.classify(path: "/vms/\(id)") == nil)
        #expect(M.classify(path: "/this-route-does-not-exist") == nil)
    }

    @Test("In-guest execution routes derive their own verb, not the update fallback")
    func guestExecutionRoutesDeriveTheirVerb() {
        let id = UUID().uuidString
        typealias M = AuthorizationMiddleware
        guard case .resource(let vms)? = M.classify(path: "/api/vms/\(id)/exec"),
            case .resource(let sandboxes)? = M.classify(path: "/api/sandboxes/\(id)/exec")
        else {
            Issue.record("expected /api/vms and /api/sandboxes to be resource-mapped")
            return
        }

        func action(_ path: String, _ method: HTTPMethod = .POST) -> String? {
            M.action(method: method, pathComponents: path.split(separator: "/"), resource: vms)
        }
        func sandboxAction(_ path: String, _ method: HTTPMethod = .POST) -> String? {
            M.action(
                method: method, pathComponents: path.split(separator: "/"), resource: sandboxes)
        }

        // The live interactive shape and the reserved async shape. The
        // failure this guards is silent: an unlisted POST subpath falls back
        // to `vm:update` — an *editor* action gating a root shell.
        #expect(action("/api/vms/\(id)/exec") == "vm:exec")
        #expect(action("/api/vms/\(id)/actions/run") == "vm:runCommand")

        // An interactive session is a WebSocket upgrade — a GET — so the verb
        // has to win over the `read` default there too, or the shell is gated
        // on a *viewer* action. Sandbox and VM attach must derive their own
        // exec actions rather than the read fallback.
        #expect(action("/api/vms/\(id)/exec", .GET) == "vm:exec")
        #expect(action("/api/vms/\(id)/exec/\(id)/attach", .GET) == "vm:exec")
        #expect(sandboxAction("/api/sandboxes/\(id)/exec/\(id)/attach", .GET) == "sandbox:exec")

        // The `/actions/` hop and the GET rule read the verb list and nothing
        // else: an unrecognized verb still falls back, and every existing
        // shape keeps the action it had.
        #expect(action("/api/vms/\(id)/actions/frobnicate") == "vm:update")
        #expect(action("/api/vms/\(id)/actions") == "vm:update")
        #expect(action("/api/vms/\(id)/start") == "vm:start")
        #expect(action("/api/vms/\(id)/snapshots") == "vm:snapshot")
        #expect(action("/api/vms/\(id)", .DELETE) == "vm:delete")
        #expect(action("/api/vms", .GET) == "vm:read")
        // GETs whose subpath is not a verb still read — including the VM
        // console, whose own `view_console` check is what gates it.
        #expect(action("/api/vms/\(id)/console", .GET) == "vm:read")
        #expect(action("/api/vms/\(id)/snapshots", .GET) == "vm:read")
        #expect(sandboxAction("/api/sandboxes/\(id)/status", .GET) == "sandbox:read")
        #expect(sandboxAction("/api/sandboxes/\(id)/operations", .GET) == "sandbox:read")

        // The hop is generic across guarded resources, not a VM special case:
        // pinned so a future `/actions/`-shaped sandbox route can't move its
        // gate without this failing first.
        #expect(sandboxAction("/api/sandboxes/\(id)/actions/exec") == "sandbox:exec")
        #expect(sandboxAction("/api/sandboxes/\(id)/actions/frobnicate") == "sandbox:update")
        // Sandboxes have no `run` verb — one resource gaining a verb must not
        // hand it to the other.
        #expect(sandboxAction("/api/sandboxes/\(id)/actions/run") == "sandbox:update")
    }

    @Test("Guarded resource metadata preserves create and snapshot actions")
    func guardedResourceCanonicalActionDistinctions() {
        let id = UUID().uuidString
        typealias M = AuthorizationMiddleware
        guard case .resource(let vms)? = M.classify(path: "/api/vms"),
            case .resource(let sandboxes)? = M.classify(path: "/api/sandboxes")
        else {
            Issue.record("expected VM and sandbox collections to be resource-mapped")
            return
        }

        for resource in [vms, sandboxes] {
            let actions =
                [
                    resource.readAction, resource.createAction, resource.updateAction,
                    resource.deleteAction, resource.snapshotAction,
                ] + Array(resource.actionVerbs.values)
            for action in actions {
                #expect(IAMRoleRegistry.allActions.contains(action))
                #expect(
                    CedarSchemaBuilder.resourceTypes(for: action).contains(
                        resource.nodeType.cedarEntityType))
            }
        }

        func action(_ path: String, _ method: HTTPMethod, _ resource: M.GuardedResource) -> String? {
            M.action(method: method, pathComponents: path.split(separator: "/"), resource: resource)
        }

        #expect(action("/api/vms", .POST, vms) == "vm:create")
        #expect(action("/api/sandboxes", .POST, sandboxes) == "sandbox:create")
        #expect(action("/api/vms/\(id)/snapshots/\(id)", .DELETE, vms) == "vm:snapshot")
        #expect(
            action("/api/sandboxes/\(id)/snapshots/\(id)", .DELETE, sandboxes)
                == "sandbox:snapshot")
        #expect(action("/api/vms/\(id)", .DELETE, vms) == "vm:delete")
        #expect(action("/api/sandboxes/\(id)", .DELETE, sandboxes) == "sandbox:delete")
    }
}
