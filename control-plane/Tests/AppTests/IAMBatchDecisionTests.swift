import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import App

/// Issue #687: the batch decision entry point.
///
/// Two properties matter, and each has a test here that would fail loudly if
/// it broke:
///
/// 1. **Agreement.** A batched decision must be the decision the per-node path
///    makes — same slice, same verdict, same recorded row. The single-node
///    forms are literally batches of one, so agreement is structural; these
///    tests pin it against real trees anyway, because "structural" is a claim
///    about code that changes.
/// 2. **Cost.** The point of the batch is that authorization stops scaling with
///    list size. `listScopingCostIsFlatInListSize` counts the queries a
///    twenty-five-item batch issues against a one-item batch and requires them
///    to be equal — a regression that reintroduced a per-item read would show
///    up as a number, not as a slow endpoint nobody profiled.
@Suite("IAM Batch Decision Tests", .serialized)
final class IAMBatchDecisionTests {

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

    /// A tree with enough shape to exercise every batching seam at once: two
    /// orgs, a nested folder chain, several projects, and resources of more
    /// than one type under them.
    private struct Fixture {
        let org: Organization
        let otherOrg: Organization
        let ou: OrganizationalUnit
        let childOU: OrganizationalUnit
        let folderProject: Project
        let orgProject: Project
        let otherProject: Project
        let vms: [VM]
        let sandbox: Sandbox
        let member: User
        let viaGroup: User
        let outsider: User
        let admin: User
        let nobody: User

        var nodes: [IAMNode] {
            var nodes = vms.map { IAMNode(type: .virtualMachine, id: $0.id!) }
            nodes.append(IAMNode(type: .sandbox, id: sandbox.id!))
            nodes.append(IAMNode(type: .project, id: folderProject.id!))
            nodes.append(IAMNode(type: .project, id: otherProject.id!))
            nodes.append(IAMNode(type: .organizationalUnit, id: childOU.id!))
            nodes.append(IAMNode(type: .organization, id: org.id!))
            nodes.append(IAMNode(type: .user, id: member.id!))
            // A dangling id: nothing behind it, so the chain truncates. The
            // batch must handle it exactly as a lone walk does.
            nodes.append(IAMNode(type: .virtualMachine, id: UUID()))
            return nodes
        }

        var principals: [IAMPrincipal] {
            [member, viaGroup, outsider, admin, nobody].map { .user($0.id!) }
        }
    }

    private func buildFixture(_ app: Application, prefix: String) async throws -> Fixture {
        let builder = TestDataBuilder(db: app.db)
        let org = try await builder.createOrganization(name: "\(prefix) Org")
        let otherOrg = try await builder.createOrganization(name: "\(prefix) Other Org")
        let ou = try await builder.createOU(name: "\(prefix) OU", description: "d", organization: org)
        let childOU = try await builder.createOU(
            name: "\(prefix) Child OU", description: "d", organization: org, parentOU: ou)
        let folderProject = try await builder.createProject(
            name: "\(prefix) Folder Project", description: "d", ou: childOU)
        let orgProject = try await builder.createProject(
            name: "\(prefix) Org Project", description: "d", organization: org)
        let otherProject = try await builder.createProject(
            name: "\(prefix) Other Project", description: "d", organization: otherOrg)

        var vms: [VM] = []
        for (index, project) in [folderProject, orgProject, otherProject].enumerated() {
            vms.append(
                try await builder.createVM(
                    name: "\(prefix)-vm-\(index)", project: project,
                    environment: index == 0 ? "production" : "development"))
        }
        let sandbox = try await builder.createSandbox(name: "\(prefix)-sbx", project: folderProject)

        let member = try await builder.createUser(username: "\(prefix)-member", email: "\(prefix)m@example.com")
        try await builder.addUserToOrganization(user: member, organization: org)
        let viaGroup = try await builder.createUser(username: "\(prefix)-group", email: "\(prefix)g@example.com")
        let group = try await builder.createGroup(name: "\(prefix)-ops", description: "d", organization: org)
        try await UserGroup(userID: viaGroup.id!, groupID: group.id!).save(on: app.db)
        let outsider = try await builder.createUser(username: "\(prefix)-out", email: "\(prefix)o@example.com")
        try await builder.addUserToOrganization(user: outsider, organization: otherOrg)
        let admin = try await builder.createUser(
            username: "\(prefix)-root", email: "\(prefix)r@example.com", isSystemAdmin: true)
        let nobody = try await builder.createUser(username: "\(prefix)-none", email: "\(prefix)n@example.com")

        // Grants at three different heights, so the batch has to get inherited
        // grants right and not just leaf ones.
        try await RoleBindingService.grant(
            principalType: .group, principalID: group.id!, role: .operator,
            nodeType: .organizationalUnit, nodeID: ou.id!, createdBy: nil, on: app.db)
        try await RoleBindingService.grant(
            principalType: .user, principalID: outsider.id!, role: .viewer,
            nodeType: .project, nodeID: folderProject.id!, createdBy: nil, on: app.db)
        try await RoleBindingService.grant(
            principalType: .user, principalID: member.id!, role: .editor,
            nodeType: .virtualMachine, nodeID: vms[0].id!, createdBy: nil, on: app.db)

        let version = try await PolicySetVersionService.current(on: app.db)
        await app.cedarPolicySet.rebuild(version: version, on: app.db)

        return Fixture(
            org: org, otherOrg: otherOrg, ou: ou, childOU: childOU,
            folderProject: folderProject, orgProject: orgProject, otherProject: otherProject,
            vms: vms, sandbox: sandbox,
            member: member, viaGroup: viaGroup, outsider: outsider, admin: admin, nobody: nobody)
    }

    // MARK: - Agreement

    @Test("A batched ancestor walk resolves every chain exactly as a lone walk does")
    func batchedChainsMatchSingleWalks() async throws {
        try await withApp { app in
            let fixture = try await buildFixture(app, prefix: "chain")
            let nodes = fixture.nodes

            let batched = try await IAMResourceTree.resolve(nodes, on: app.db)
            for node in nodes {
                let single = try await IAMResourceTree.resolve(node, on: app.db)
                let fromBatch = batched[node]
                #expect(fromBatch == single, "chain for \(node.type.rawValue) diverged when batched")
            }
        }
    }

    @Test("Batched entity slices are identical to the per-node slices")
    func batchedSlicesMatchSingleSlices() async throws {
        try await withApp { app in
            let fixture = try await buildFixture(app, prefix: "slice")
            let targets = fixture.principals.flatMap { principal in
                fixture.nodes.map { IAMCheckTarget(principal: principal, node: $0) }
            }

            let batched = try await EntitySliceLoader.load(targets, action: "vm:read", on: app.db)
            for target in targets {
                let single = try await EntitySliceLoader.load(
                    principal: target.principal, node: target.node, action: "vm:read", on: app.db)
                let fromBatch = batched[target]
                #expect(
                    fromBatch == single,
                    "slice for \(target.principal.subject) on \(target.node.type.rawValue) diverged when batched")
            }
        }
    }

    @Test("Batched decisions are identical to the looped single checks across a mixed grid")
    func batchedDecisionsMatchSingleDecisions() async throws {
        try await withApp { app in
            let fixture = try await buildFixture(app, prefix: "decide")
            let built = try await IAMDecisionEngine.compiledSet(app)
            let actions = ["vm:read", "vm:start", "vm:delete", "project:read", "org:read", "iam:setPolicy"]

            for action in actions {
                let targets = fixture.principals.flatMap { principal in
                    fixture.nodes.map { IAMCheckTarget(principal: principal, node: $0) }
                }
                let batched = try await IAMDecisionEngine.decide(
                    targets, action: action, built: built, on: app.db)

                for target in targets {
                    let single = try await IAMDecisionEngine.decide(
                        principal: target.principal, action: action, node: target.node,
                        built: built, on: app.db)
                    let fromBatch = batched[target]
                    let agrees = fromBatch?.verdict.allowed == single.verdict.allowed
                    #expect(
                        agrees,
                        "\(action) for \(target.principal.subject) on \(target.node.type.rawValue): batch says \(String(describing: fromBatch?.verdict.allowed)), single says \(single.verdict.allowed)"
                    )
                    let sameCeilings = fromBatch?.denyingCeilingIDs == single.denyingCeilingIDs
                    #expect(sameCeilings, "ceiling marks diverged for \(action) on \(target.node.type.rawValue)")
                }
            }
        }
    }

    // MARK: - Cost

    @Test("List scoping costs the same number of queries for twenty-five items as for one")
    func listScopingCostIsFlatInListSize() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "flat Org")
            let ou = try await builder.createOU(name: "flat OU", description: "d", organization: org)
            let project = try await builder.createProject(
                name: "flat Project", description: "d", ou: ou)
            let user = try await builder.createUser(username: "flat-user", email: "flat@example.com")
            try await builder.addUserToOrganization(user: user, organization: org)

            var vms: [VM] = []
            for index in 0..<25 {
                vms.append(try await builder.createVM(name: "flat-vm-\(index)", project: project))
            }
            let nodes = vms.map { IAMNode(type: .virtualMachine, id: $0.id!) }

            func queriesToScope(_ nodes: [IAMNode]) async throws -> Int {
                let targets = nodes.map { IAMCheckTarget(principal: .user(user.id!), node: $0) }
                app.fluent.history.start()
                defer { app.fluent.history.stop() }
                _ = try await EntitySliceLoader.load(targets, action: "vm:read", on: app.db)
                return app.fluent.history.queries.count
            }

            let one = try await queriesToScope(Array(nodes.prefix(1)))
            let many = try await queriesToScope(nodes)
            // Equal, not merely sub-linear: every read in the loader is
            // set-based, so list size changes the size of the IN clauses and
            // nothing else. Looping the old single-node path would have made
            // this 25x.
            #expect(many == one, "scoping 25 VMs took \(many) queries, scoping 1 took \(one)")
        }
    }

    @Test("A batch of fifty checks on one resource loads one slice, not fifty")
    func repeatedResourceInABatchLoadsOneSlice() async throws {
        try await withApp { app in
            let fixture = try await buildFixture(app, prefix: "repeat")
            let node = IAMNode(type: .virtualMachine, id: fixture.vms[0].id!)
            let principal = IAMPrincipal.user(fixture.member.id!)

            app.fluent.history.start()
            defer { app.fluent.history.stop() }
            let slices = try await EntitySliceLoader.load(
                Array(repeating: IAMCheckTarget(principal: principal, node: node), count: 50),
                action: "vm:read", on: app.db)
            let queries = app.fluent.history.queries.count

            #expect(slices.count == 1)
            // Deduplication happens before any read: fifty identical questions
            // are one question.
            #expect(queries <= 8, "fifty repeats of one check took \(queries) queries")
        }
    }

    // MARK: - Recording

    @Test("A batched authorization records one row per node, and none for a memoized repeat")
    func batchAuthorizationRecordsOneRowPerNode() async throws {
        try await withApp { app in
            let fixture = try await buildFixture(app, prefix: "record")
            let nodes = fixture.vms.map { IAMNode(type: .virtualMachine, id: $0.id!) }
            let cache = IAMRequestCache()
            let state = IAMRequestAuthState()
            let context = IAMCheckContext(path: "/api/vms", method: "GET", requestID: "batch-test")

            let first = try await IAMAuthorizer.authorize(
                principal: .user(fixture.member.id!), action: "vm:read", nodes: nodes,
                context: context, state: state, cache: cache, app: app, db: app.db)
            #expect(first.count == nodes.count)
            #expect(state.decisionEvaluated.withLockedValue { $0 })

            // The same list again in the same request: every triple is
            // memoized, so nothing is re-evaluated and nothing is re-recorded.
            let second = try await IAMAuthorizer.authorize(
                principal: .user(fixture.member.id!), action: "vm:read", nodes: nodes,
                context: context, state: state, cache: cache, app: app, db: app.db)
            let sameVerdicts = second.mapValues(\.allowed) == first.mapValues(\.allowed)
            #expect(sameVerdicts)

            try await Task.sleep(for: .milliseconds(500))
            let rows = try await IAMDecisionLog.query(on: app.db).count()
            #expect(rows == nodes.count, "expected one row per node, got \(rows)")

            let actions = Set(try await IAMDecisionLog.query(on: app.db).all().compactMap(\.iamAction))
            #expect(actions == ["vm:read"])
        }
    }
}
