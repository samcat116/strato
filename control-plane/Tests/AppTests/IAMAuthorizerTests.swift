import Fluent
import FluentSQLiteDriver
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import App

/// IAM phase 5 (issue #482): the authoritative Cedar evaluator, the decision
/// log it writes, and the reverse SpiceDB shadow. These drive
/// `IAMAuthorizer.checkLegacyVocabulary` (the boundary every legacy-vocabulary
/// check site funnels through) against real trees, bindings, and the real
/// engine, then assert on both the enforced verdict and the recorded row.
@Suite("IAM Authorizer Tests", .serialized)
final class IAMAuthorizerTests {

    private func withApp(_ test: (Application) async throws -> Void) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()
            // Enable decision-row recording and the reverse SpiceDB
            // comparison (against the testing mock, whose verdict
            // `spicedbMockAllows` controls). After configure — which resets
            // the config from the environment — and before the recorder is
            // lazily built with it at boot.
            app.iamShadowConfig.recordDecisions = true
            app.iamShadowConfig.enabled = true
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

    /// Run one legacy-vocabulary check exactly as `req.can` / the
    /// `req.spicedb` decorator would.
    private func check(
        _ app: Application,
        user: User,
        permission: String,
        resourceType: String,
        resourceID: String,
        path: String = "/api/vms",
        state: IAMRequestAuthState? = nil
    ) async throws -> Bool {
        try await IAMAuthorizer.checkLegacyVocabulary(
            userID: user.id!,
            permission: permission,
            resourceType: resourceType,
            resourceID: resourceID,
            context: IAMCheckContext(path: path, method: "GET", requestID: "test-request"),
            state: state,
            app: app,
            db: app.db
        )
    }

    /// The decision row is written by a tracked background task; wait for it.
    private func onlyEntry(_ app: Application) async throws -> IAMDecisionLog {
        var entries: [IAMDecisionLog] = []
        for _ in 0..<200 {
            entries = try await IAMDecisionLog.query(on: app.db).all()
            if !entries.isEmpty { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(entries.count == 1)
        return try #require(entries.first)
    }

    @Test("An allowed check records the decision with policy, tier, version, and a matching reverse shadow")
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
            #expect(entry.spicedbDecision == "allow")  // the mock allows by default
            #expect(entry.decisionsMatch == true)
            #expect(entry.iamAction == "vm:read")
            #expect(entry.tier == "grant")
            #expect(entry.determiningPolicies == ["role-viewer"])
            #expect(entry.policyVersion == version)
            #expect(entry.organizationID == tree.org.id)
            #expect(entry.requestID == "test-request")
        }
    }

    @Test("A deny is enforced and the disagreeing SpiceDB verdict is recorded as a mismatch")
    func denyEnforcedAndMismatchRecorded() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "mismatch")
            // No binding: Cedar denies (org members no longer see every
            // project). The mock SpiceDB still says allow — the reverse
            // shadow's regression signal.
            let version = try await PolicySetVersionService.current(on: app.db)
            await app.cedarPolicySet.rebuild(version: version, on: app.db)

            let allowed = try await check(
                app, user: tree.user, permission: "view_project", resourceType: "project",
                resourceID: tree.project.id!.uuidString)
            #expect(!allowed)

            let entry = try await onlyEntry(app)
            #expect(entry.cedarDecision == "deny")
            #expect(entry.spicedbDecision == "allow")
            #expect(entry.decisionsMatch == false)
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
        let app = try await Application.make(.testing)
        app.databases.use(.sqlite(.memory), as: .sqlite)
        var thrown: (any Error)?
        do {
            _ = try await IAMAuthorizer.authorize(
                userID: UUID(),
                action: "vm:read",
                node: IAMNode(type: .virtualMachine, id: UUID()),
                spicedbEquivalent: nil,
                context: IAMCheckContext(path: "/api/vms", method: "GET", requestID: nil),
                state: nil,
                app: app,
                db: app.db
            )
        } catch {
            thrown = error
        }
        #expect((thrown as? any AbortError)?.status == .serviceUnavailable)
        try await app.asyncShutdown()
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
            #expect(entry.decisionsMatch == true)
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

    @Test("Request.spicedb returns the Cedar-authoritative decorator, and its verdict is Cedar's")
    func decoratorIsAuthoritative() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "e2e")
            let version = try await PolicySetVersionService.current(on: app.db)
            await app.cedarPolicySet.rebuild(version: version, on: app.db)

            let request = Request(application: app, method: .GET, url: "/api/vms", on: app.eventLoopGroup.next())
            #expect(try request.spicedb is CedarAuthoritativeSpiceDBService)

            // The mock SpiceDB would allow; Cedar (no binding) denies — and
            // Cedar is what's enforced now.
            let allowed = try await request.spicedb.checkPermission(
                subject: tree.user.id!.uuidString,
                permission: "read",
                resource: "virtual_machine",
                resourceId: tree.vm.id!.uuidString)
            #expect(!allowed)

            let entry = try await onlyEntry(app)
            #expect(entry.cedarDecision == "deny")
            #expect(entry.spicedbDecision == "allow")
            #expect(entry.decisionsMatch == false)
            #expect(entry.path == "/api/vms")
        }
    }

    @Test("With the reverse shadow disabled, rows are still written without a comparison")
    func rowsWithoutReverseShadow() async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()
            // Rows on, reverse shadow left at its .testing default (off).
            app.iamShadowConfig.recordDecisions = true
            let tree = try await buildTree(app, prefix: "norev")
            let version = try await PolicySetVersionService.current(on: app.db)
            await app.cedarPolicySet.rebuild(version: version, on: app.db)

            _ = try await check(
                app, user: tree.user, permission: "view_organization", resourceType: "organization",
                resourceID: tree.org.id!.uuidString)

            let entry = try await onlyEntry(app)
            #expect(entry.cedarDecision == "allow")
            #expect(entry.spicedbDecision == IAMDecisionRecorder.noComparison)
            #expect(entry.decisionsMatch == nil)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    /// The gate is what keeps decision recording off the connection pool: each
    /// record is an insert (plus the reverse-shadow round trip), against a
    /// Fluent pool that defaults to one connection per event loop.
    @Test("The gate admits up to its ceiling, queues to its depth, then sheds")
    func gateBoundsConcurrency() async throws {
        let gate = IAMShadowGate(maxConcurrent: 2, maxQueueDepth: 1)

        #expect(await gate.acquire() == .admitted)
        #expect(await gate.acquire() == .admitted)

        // The third has no slot but the queue has room, so it parks. Run it
        // detached — awaiting it here would deadlock by design.
        let queued = Task { await gate.acquire() }
        var spins = 0
        while await gate.stats.queued < 1, spins < 200 {
            try await Task.sleep(for: .milliseconds(5))
            spins += 1
        }
        #expect(await gate.stats.queued == 1)

        // The fourth finds the queue full and is shed with a running count,
        // rather than growing the line without limit.
        #expect(await gate.acquire() == .shed(total: 1))
        #expect(await gate.acquire() == .shed(total: 2))

        // Releasing hands the slot straight to the waiter.
        await gate.release()
        #expect(await queued.value == .admitted)
        #expect(await gate.stats.queued == 0)
        #expect(await gate.stats.inFlight == 2)
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
            let old = Date().addingTimeInterval(-Double(app.iamShadowConfig.retentionDays + 1) * 86_400)
            entry.createdAt = old
            try await entry.save(on: app.db)

            await app.iamDecisionRecorder.sweepExpiredEntries()
            let remaining = try await IAMDecisionLog.query(on: app.db).count()
            #expect(remaining == 0)
        }
    }
}
