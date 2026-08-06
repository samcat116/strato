import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

/// IAM phase 5 (issue #482): the authoritative Cedar evaluator and the
/// decision log it writes. These drive `IAMAuthorizer.checkLegacyVocabulary`
/// (the boundary every legacy-vocabulary check site funnels through) against
/// real trees, bindings, and the real engine, then assert on both the
/// enforced verdict and the recorded row.
@Suite("IAM Authorizer Tests", .serialized)
final class IAMAuthorizerTests {

    private func withApp(_ test: (Application) async throws -> Void) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()
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
        let builder = TestDataBuilder(db: app.db)
        let org = try await builder.createOrganization(name: "\(prefix) Org")
        let project = try await builder.createProject(
            name: "\(prefix) Project", description: "d", organization: org)
        let vm = try await builder.createVM(name: "\(prefix)-vm", project: project)
        let user = try await builder.createUser(
            username: "\(prefix)-user", email: "\(prefix)@example.com")
        try await builder.addUserToOrganization(user: user, organization: org, role: "member")
        return Tree(org: org, project: project, vm: vm, user: user)
    }

    /// Run one legacy-vocabulary check exactly as `req.can` would.
    private func check(
        _ app: Application,
        user: User,
        permission: String,
        resourceType: String,
        resourceID: String,
        path: String = "/api/vms",
        state: IAMRequestAuthState? = nil,
        cache: IAMRequestCache? = nil
    ) async throws -> Bool {
        try await IAMAuthorizer.checkLegacyVocabulary(
            principal: .user(user.id!),
            permission: permission,
            resourceType: resourceType,
            resourceID: resourceID,
            context: IAMCheckContext(path: path, method: "GET", requestID: "test-request"),
            state: state,
            cache: cache,
            app: app,
            db: app.db
        )
    }

    /// The decision row is written by the batching drain; flush it out first.
    private func onlyEntry(_ app: Application) async throws -> IAMDecisionLog {
        await app.iamDecisionRecorder.flush()
        let entries = try await IAMDecisionLog.query(on: app.db).all()
        #expect(entries.count == 1)
        return try #require(entries.first)
    }

    @Test("An allowed check records the decision with policy, tier, and version")
    func allowRecorded() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "agree")
            try await RoleBindingService.grant(
                principalType: .user, principalID: tree.user.id!, role: .viewer,
                nodeType: .project, nodeID: tree.project.id!, createdBy: nil, on: app.db)
            let version = try await PolicySetVersionService.current(on: app.db)
            await app.cedarPolicySet.rebuild(version: version, on: app.db)

            let allowed = try await check(
                app, user: tree.user, permission: "read", resourceType: "virtual_machine",
                resourceID: tree.vm.id!.uuidString)
            #expect(allowed)

            let entry = try await onlyEntry(app)
            #expect(entry.cedarDecision == "allow")
            #expect(entry.spicedbDecision == IAMDecisionRecorder.noComparison)
            #expect(entry.decisionsMatch == nil)
            #expect(entry.iamAction == "vm:read")
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
            let version = try await PolicySetVersionService.current(on: app.db)
            await app.cedarPolicySet.rebuild(version: version, on: app.db)

            let allowed = try await check(
                app, user: tree.user, permission: "view_project", resourceType: "project",
                resourceID: tree.project.id!.uuidString)
            #expect(!allowed)

            let entry = try await onlyEntry(app)
            #expect(entry.cedarDecision == "deny")
            #expect(entry.spicedbDecision == IAMDecisionRecorder.noComparison)
            #expect(entry.decisionsMatch == nil)
            #expect(entry.iamAction == "project:read")
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
                nodeType: .organization, nodeID: tree.org.id!, createdBy: nil, on: app.db)
            let guardrail = try await GuardrailStore.create(
                name: "no-vm-lifecycle", description: nil, effect: nil,
                node: IAMNode(type: .organization, id: tree.org.id!),
                actions: ["vm:*"], principalMatch: .any, resourceMatch: .any,
                createdBy: nil, on: app.db)
            let version = try await PolicySetVersionService.current(on: app.db)
            await app.cedarPolicySet.rebuild(version: version, on: app.db)

            let allowed = try await check(
                app, user: tree.user, permission: "start", resourceType: "virtual_machine",
                resourceID: tree.vm.id!.uuidString)
            #expect(!allowed)

            let entry = try await onlyEntry(app)
            #expect(entry.cedarDecision == "deny")
            #expect(entry.tier == "guardrail")
            #expect(entry.determiningPolicies == ["guardrail-\(guardrail.id!.uuidString.lowercased())"])
        }
    }

    @Test("A repeat of the same check in one request is decided and recorded once")
    func requestScopedDecisionMemo() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "memo")
            try await RoleBindingService.grant(
                principalType: .user, principalID: tree.user.id!, role: .viewer,
                nodeType: .project, nodeID: tree.project.id!, createdBy: nil, on: app.db)
            let version = try await PolicySetVersionService.current(on: app.db)
            await app.cedarPolicySet.rebuild(version: version, on: app.db)

            // The shape of a guarded object route: the middleware checks, then
            // the handler re-checks the identical triple through
            // `Request.authorizedVM`.
            let cache = IAMRequestCache()
            let state = IAMRequestAuthState()
            let middleware = try await check(
                app, user: tree.user, permission: "read", resourceType: "virtual_machine",
                resourceID: tree.vm.id!.uuidString, state: state, cache: cache)
            let handler = try await check(
                app, user: tree.user, permission: "read", resourceType: "virtual_machine",
                resourceID: tree.vm.id!.uuidString, state: state, cache: cache)
            #expect(middleware)
            #expect(handler)
            // The memoized answer still counts as a decision this request made.
            #expect(state.decisionEvaluated.withLockedValue { $0 })

            let entry = try await onlyEntry(app)
            #expect(entry.iamAction == "vm:read")
            // The row count is the point: one question, one decision, one row.
            try await Task.sleep(for: .milliseconds(250))
            let rows = try await IAMDecisionLog.query(on: app.db).count()
            #expect(rows == 1)
        }
    }

    @Test("The request memo is keyed by the whole check, not just the resource")
    func requestMemoDoesNotConflateChecks() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "memokey")
            try await RoleBindingService.grant(
                principalType: .user, principalID: tree.user.id!, role: .viewer,
                nodeType: .project, nodeID: tree.project.id!, createdBy: nil, on: app.db)
            let version = try await PolicySetVersionService.current(on: app.db)
            await app.cedarPolicySet.rebuild(version: version, on: app.db)

            // Same principal, same VM, different action: a viewer may read it
            // but not start it, so a memo keyed on the resource alone would
            // hand back the wrong verdict.
            let cache = IAMRequestCache()
            let read = try await check(
                app, user: tree.user, permission: "read", resourceType: "virtual_machine",
                resourceID: tree.vm.id!.uuidString, cache: cache)
            let start = try await check(
                app, user: tree.user, permission: "start", resourceType: "virtual_machine",
                resourceID: tree.vm.id!.uuidString, cache: cache)
            #expect(read)
            #expect(!start)
        }
    }

    @Test("An untranslatable check fails closed and is recorded as a coverage gap")
    func untranslatedDeniedAndRecorded() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "gap")
            let version = try await PolicySetVersionService.current(on: app.db)
            await app.cedarPolicySet.rebuild(version: version, on: app.db)

            let state = IAMRequestAuthState()
            let allowed = try await check(
                app, user: tree.user, permission: "frobnicate", resourceType: "virtual_machine",
                resourceID: tree.vm.id!.uuidString, state: state)
            #expect(!allowed)
            // Denial by translation gap still counts as a decision for the
            // middleware's handler assertion.
            #expect(state.decisionEvaluated.withLockedValue { $0 })

            let entry = try await onlyEntry(app)
            #expect(entry.cedarDecision == "untranslated")
            #expect(entry.decisionsMatch == nil)
            #expect(entry.iamAction == nil)
            #expect(entry.spicedbDecision == IAMDecisionRecorder.noComparison)
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
                legacyEquivalent: nil,
                context: IAMCheckContext(path: "/api/vms", method: "GET", requestID: nil),
                state: nil,
                app: app,
                db: app.db
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
            let version = try await PolicySetVersionService.current(on: app.db)
            await app.cedarPolicySet.rebuild(version: version, on: app.db)

            let allowed = try await check(
                app, user: tree.user, permission: "view_organization", resourceType: "organization",
                resourceID: tree.org.id!.uuidString)
            #expect(allowed)

            let entry = try await onlyEntry(app)
            #expect(entry.cedarDecision == "allow")
            #expect(entry.tier == "platform")
            #expect(entry.determiningPolicies == ["org-membership"])
        }
    }

    @Test("A system admin is allowed by the platform policy and flagged for the audit trail")
    func adminThroughEvaluator() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "admin")
            let admin = try await TestDataBuilder(db: app.db).createUser(
                username: "authz-admin", email: "authz-admin@example.com", isSystemAdmin: true)
            let version = try await PolicySetVersionService.current(on: app.db)
            await app.cedarPolicySet.rebuild(version: version, on: app.db)

            let state = IAMRequestAuthState()
            let allowed = try await check(
                app, user: admin, permission: "read", resourceType: "virtual_machine",
                resourceID: tree.vm.id!.uuidString, state: state)
            #expect(allowed)
            // The bypass flag now derives from the determining policy — this
            // is what AuditMiddleware records as an admin audit event.
            #expect(state.adminPolicyUsed.withLockedValue { $0 })

            let entry = try await onlyEntry(app)
            #expect(entry.tier == "platform")
            #expect(entry.determiningPolicies == ["platform-system-admin"])
        }
    }

    @Test("Request.can in the legacy vocabulary evaluates through Cedar and records the row")
    func legacyRequestCanIsCedar() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "e2e")
            let version = try await PolicySetVersionService.current(on: app.db)
            await app.cedarPolicySet.rebuild(version: version, on: app.db)

            let request = Request(application: app, method: .GET, url: "/api/vms", on: app.eventLoopGroup.next())
            request.auth.login(tree.user)

            // No binding on the VM's project: Cedar denies.
            let allowed = try await request.can(
                "read", on: "virtual_machine", id: tree.vm.id!.uuidString)
            #expect(!allowed)

            let entry = try await onlyEntry(app)
            #expect(entry.cedarDecision == "deny")
            #expect(entry.spicedbPermission == "read")
            #expect(entry.spicedbDecision == IAMDecisionRecorder.noComparison)
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
            let version = try await PolicySetVersionService.current(on: app.db)
            await app.cedarPolicySet.rebuild(version: version, on: app.db)

            for permission in ["read", "update", "delete"] {
                _ = try await check(
                    app, user: tree.user, permission: permission, resourceType: "virtual_machine",
                    resourceID: tree.vm.id!.uuidString)
            }
            await app.iamDecisionRecorder.flush()

            let actions = try await IAMDecisionLog.query(on: app.db).all().compactMap(\.iamAction)
            #expect(Set(actions) == ["vm:read", "vm:update", "vm:delete"])
        }
    }

    private func sample(path: String) -> PendingIAMDecision {
        .untranslated(
            subject: UUID().uuidString,
            equivalent: LegacyCheckEquivalent(
                permission: "read", resourceType: "virtual_machine", resourceID: UUID().uuidString),
            context: IAMCheckContext(path: path, method: "GET", requestID: "test-request"))
    }

    @Test("The retention sweep prunes rows older than the window")
    func retentionSweep() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "sweep")
            let version = try await PolicySetVersionService.current(on: app.db)
            await app.cedarPolicySet.rebuild(version: version, on: app.db)
            _ = try await check(
                app, user: tree.user, permission: "view_organization", resourceType: "organization",
                resourceID: tree.org.id!.uuidString)
            let entry = try await onlyEntry(app)

            // Age the row past the window, then sweep.
            let old = Date().addingTimeInterval(-Double(app.iamDecisionLogConfig.retentionDays + 1) * 86_400)
            entry.createdAt = old
            try await entry.save(on: app.db)

            await app.iamDecisionRecorder.sweepExpiredEntries()
            let remaining = try await IAMDecisionLog.query(on: app.db).count()
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
            try await app.autoMigrate()
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
            let builder = TestDataBuilder(db: app.db)
            // A network in a project that belongs to no organization: the chain
            // is [network, project] and never reaches an organization, so an
            // org-anchored guardrail could not match it.
            let orphanProject = try await builder.createProject(
                name: "Orphan Project", description: "no organization")
            let network = try await builder.createNetwork(
                name: "orphan-net", project: orphanProject, subnet: "10.99.0.0/24",
                gateway: "10.99.0.1", externalAccess: false)

            let user = try await builder.createUser(
                username: "trunc-user", email: "trunc-user@example.com")
            // Even a direct admin binding on the network itself must not win:
            // the in-chain permit is exactly what would fire while the ceiling
            // above the break could not.
            try await RoleBindingService.grant(
                principalType: .user, principalID: user.id!, role: .admin,
                nodeType: .network, nodeID: network.id!, createdBy: nil, on: app.db)
            let version = try await PolicySetVersionService.current(on: app.db)
            await app.cedarPolicySet.rebuild(version: version, on: app.db)

            let state = IAMRequestAuthState()
            let decision = try await IAMAuthorizer.authorize(
                userID: user.id!,
                action: "network:read",
                node: IAMNode(type: .network, id: network.id!),
                legacyEquivalent: nil,
                context: IAMCheckContext(path: "/api/networks", method: "GET", requestID: nil),
                state: state,
                app: app,
                db: app.db
            )
            #expect(!decision.allowed)
            #expect(decision.determiningPolicyIDs.isEmpty)
            #expect(state.decisionEvaluated.withLockedValue { $0 })
        }
    }

    @Test("A network is readable only through a grant on its project's chain")
    func networkReadRequiresAGrant() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "Net Read Org")
            let project = try await builder.createProject(
                name: "Net Read Project", description: "d", organization: org)
            let network = try await builder.createNetwork(
                name: "read-net", project: project, subnet: "10.98.0.0/24", gateway: "10.98.0.1",
                externalAccess: false)
            let user = try await builder.createUser(
                username: "net-read-user", email: "net-read-user@example.com")
            let version = try await PolicySetVersionService.current(on: app.db)
            await app.cedarPolicySet.rebuild(version: version, on: app.db)

            let node = IAMNode(type: .network, id: network.id!)
            let context = IAMCheckContext(path: "/api/networks", method: "GET", requestID: nil)

            // Nothing is world-readable any more: the permit that made
            // project-less networks open to every authenticated user went away
            // with global networks themselves (issue #765).
            let ungranted = try await IAMAuthorizer.authorize(
                userID: user.id!, action: "network:read", node: node, legacyEquivalent: nil,
                context: context, state: nil, app: app, db: app.db)
            #expect(!ungranted.allowed)

            try await RoleBindingService.grant(
                principalType: .user, principalID: user.id!, role: .viewer,
                nodeType: .project, nodeID: project.id!, createdBy: nil, on: app.db)

            let granted = try await IAMAuthorizer.authorize(
                userID: user.id!, action: "network:read", node: node, legacyEquivalent: nil,
                context: context, state: nil, app: app, db: app.db)
            #expect(granted.allowed)
        }
    }

    @Test("requireSystemAdmin denies non-admins, marks the decision, and flags admins for audit")
    func requireSystemAdminBranches() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(username: "rsa-user", email: "rsa-user@example.com")
            let admin = try await builder.createUser(
                username: "rsa-admin", email: "rsa-admin@example.com", isSystemAdmin: true)

            let denied = Request(
                application: app, method: .GET, url: "/api/audit-events", on: app.eventLoopGroup.next())
            denied.auth.login(user)
            var thrown: (any Error)?
            do { _ = try denied.requireSystemAdmin() } catch { thrown = error }
            #expect((thrown as? any AbortError)?.status == .forbidden)
            #expect(denied.iamAuthState.decisionEvaluated.withLockedValue { $0 })
            #expect(!denied.iamAuthState.adminPolicyUsed.withLockedValue { $0 })

            let allowed = Request(
                application: app, method: .GET, url: "/api/audit-events", on: app.eventLoopGroup.next())
            allowed.auth.login(admin)
            _ = try allowed.requireSystemAdmin()
            #expect(allowed.iamAuthState.adminPolicyUsed.withLockedValue { $0 })

            let anonymous = Request(
                application: app, method: .GET, url: "/api/audit-events", on: app.eventLoopGroup.next())
            var anonThrown: (any Error)?
            do { _ = try anonymous.requireSystemAdmin() } catch { anonThrown = error }
            #expect((anonThrown as? any AbortError)?.status == .unauthorized)
        }
    }

    @Test("A handler-checked mutation that evaluates nothing is a hard 500 under .testing")
    func handlerAssertionCatchesMissingCheck() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
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
            checked.markRowScopedAuthorization()
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
        // Listed as its own exact prefix, not by widening the allowlist to
        // `/agent/`: a future route under that prefix must still opt in.
        #expect(M.classify(path: "/agent/something-else") == nil)
        // Identity-plane.
        #expect(M.classify(path: "/api/api-keys") == .loginOnly)
        #expect(M.classify(path: "/api/authorization/check") == .loginOnly)
        // Middleware-mapped resources.
        if case .resource(let guarded)? = M.classify(path: "/api/vms/\(id)/start") {
            #expect(guarded.resourceType == "virtual_machine")
        } else {
            Issue.record("expected /api/vms to be resource-mapped")
        }
        // Handler-checked (the evaluator runs in the handler).
        #expect(M.classify(path: "/api/organizations/\(id)/members") == .handlerChecked)
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

        func permission(_ path: String, _ method: HTTPMethod = .POST) -> String? {
            M.permission(method: method, pathComponents: path.split(separator: "/"), resource: vms)
        }
        func sandboxPermission(_ path: String, _ method: HTTPMethod = .POST) -> String? {
            M.permission(
                method: method, pathComponents: path.split(separator: "/"), resource: sandboxes)
        }

        // The two shapes the guest-agent exec endpoints will serve. The
        // failure this guards is silent: an unlisted POST subpath falls back
        // to `update`, which translates to `vm:update` — an *editor*
        // permission gating a root shell.
        #expect(permission("/api/vms/\(id)/exec") == "exec")
        #expect(permission("/api/vms/\(id)/actions/run") == "run")
        let execAction = IAMActionTranslator.translate(
            permission: "exec", resourceType: "virtual_machine", resourceID: id,
            path: "/api/vms/\(id)/exec")
        #expect(execAction?.action == "vm:exec")
        let runAction = IAMActionTranslator.translate(
            permission: "run", resourceType: "virtual_machine", resourceID: id,
            path: "/api/vms/\(id)/actions/run")
        #expect(runAction?.action == "vm:runCommand")

        // An interactive session is a WebSocket upgrade — a GET — so the verb
        // has to win over the `read` default there too, or the shell is gated
        // on a *viewer* permission. This is the live shape of the sandbox exec
        // attach route, generalized to VMs by the guest-agent work.
        #expect(permission("/api/vms/\(id)/exec", .GET) == "exec")
        #expect(permission("/api/vms/\(id)/exec/\(id)/attach", .GET) == "exec")
        #expect(sandboxPermission("/api/sandboxes/\(id)/exec/\(id)/attach", .GET) == "exec")

        // The `/actions/` hop and the GET rule read the verb list and nothing
        // else: an unrecognized verb still falls back, and every existing
        // shape keeps the permission it had.
        #expect(permission("/api/vms/\(id)/actions/frobnicate") == "update")
        #expect(permission("/api/vms/\(id)/actions") == "update")
        #expect(permission("/api/vms/\(id)/start") == "start")
        #expect(permission("/api/vms/\(id)/snapshots") == "snapshot")
        #expect(permission("/api/vms/\(id)", .DELETE) == "delete")
        #expect(permission("/api/vms", .GET) == "read")
        // GETs whose subpath is not a verb still read — including the VM
        // console, whose own `view_console` check is what gates it.
        #expect(permission("/api/vms/\(id)/console", .GET) == "read")
        #expect(permission("/api/vms/\(id)/snapshots", .GET) == "read")
        #expect(sandboxPermission("/api/sandboxes/\(id)/status", .GET) == "read")
        #expect(sandboxPermission("/api/sandboxes/\(id)/operations", .GET) == "read")

        // The hop is generic across guarded resources, not a VM special case:
        // pinned so a future `/actions/`-shaped sandbox route can't move its
        // gate without this failing first.
        #expect(sandboxPermission("/api/sandboxes/\(id)/actions/exec") == "exec")
        #expect(sandboxPermission("/api/sandboxes/\(id)/actions/frobnicate") == "update")
        // Sandboxes have no `run` verb — one resource gaining a verb must not
        // hand it to the other.
        #expect(sandboxPermission("/api/sandboxes/\(id)/actions/run") == "update")
    }
}
