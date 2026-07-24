import Fluent
import Testing
import Vapor
import VaporTesting

@testable import App

/// Regression tests for the `GET /api/vms` 504 past ~200 VMs.
///
/// `VMController.index` runs one `req.can("read", …)` per VM. The request-scoped
/// `IAMRequestCache` (#686) already memoizes the caller's memberships and each
/// node's resolved chain, but it keys chains by the node walked *from*, so a
/// list of VMs sharing one project used to re-walk the shared project→org path
/// once per VM. Caching each container's suffix lets the next sibling reuse it,
/// leaving one row read per leaf plus the shared chain resolved once.
///
/// The property under test is *shape*, not wall-clock: with every VM in one
/// project the chain is resolved a constant number of times, so the total query
/// count stays under a small linear budget. A return to per-leaf re-walking
/// pushes it past the budget.
@Suite("VM List Scaling Tests", .serialized)
final class VMListScalingTests {

    private func withApp(_ test: (Application) async throws -> Void) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()
            try await test(app)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    @Test("GET /api/vms query count stays under a linear budget as VMs scale")
    func listQueryCountStaysBounded() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "scaleuser", email: "scale@example.com", isSystemAdmin: false)
            let org = try await builder.createOrganization(name: "Scale Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "member")
            user.currentOrganizationId = org.id
            try await user.save(on: app.db)

            let project = try await builder.createProject(
                name: "Scale Project", description: "many VMs", organization: org)

            // A viewer binding on the project makes every VM readable, so the
            // index loop runs a real (allowed) check per VM rather than
            // short-circuiting on a denial.
            try await RoleBindingService.grant(
                principalType: .user, principalID: user.id!, role: .viewer,
                nodeType: .project, nodeID: project.id!, createdBy: nil, on: app.db)

            let vmCount = 120
            for index in 0..<vmCount {
                _ = try await builder.createVM(name: "scale-vm-\(index)", project: project)
            }

            // Drive `VMController.index` with a request we own so Fluent's
            // per-request query history (enabled on the request, not the app)
            // records exactly the DB work the list endpoint does. An empty query
            // string means the unfiltered list — every VM in the org.
            let req = Request(
                application: app, method: .GET, url: URI(path: "/api/vms"),
                on: app.eventLoopGroup.next())
            req.auth.login(user)
            req.fluent.history.start()
            let vms = try await VMController().index(req: req)
            req.fluent.history.stop()

            #expect(vms.count == vmCount)

            let queryCount = req.fluent.history.queries.count

            // Per-VM cost is a small constant — the VM's own row read plus its
            // role-binding lookup — because the project→org chain and the
            // caller's memberships are resolved once for the whole request. If
            // the shared chain were re-walked per VM (the pre-#686 behavior, or
            // a regression of the container-suffix caching) each check would add
            // the project step back, blowing this budget.
            let budget = vmCount * 3
            #expect(
                queryCount < budget,
                "GET /api/vms issued \(queryCount) queries for \(vmCount) VMs (budget \(budget)); per-request authorization memoization may have regressed"
            )
        }
    }

    /// The suffix caching is only safe if it is invisible: a cached resolution
    /// must equal the independent uncached walk. This exercises the splice path
    /// — two projects sharing a folder→org tail and a nested folder chain, where
    /// later leaves reuse a cached suffix — and asserts equality of both the
    /// resolved chain (with leaf facts) and the full entity slice (hence the
    /// Cedar decision) for every node.
    @Test("Cached resolution equals the uncached walk across shared chains")
    func cachedResolutionMatchesUncached() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "equser", email: "eq@example.com", isSystemAdmin: false)
            let org = try await builder.createOrganization(name: "Eq Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "member")

            // org → ou → childOU → {projectA, projectB}: nested folders plus two
            // projects sharing the folder→org tail, so a leaf in projectB reuses
            // the suffix cached while resolving projectA.
            let ou = try await builder.createOU(name: "Eq OU", description: "d", organization: org)
            let childOU = try await builder.createOU(
                name: "Eq Child OU", description: "d", organization: org, parentOU: ou)
            let projectA = try await builder.createProject(name: "Eq A", description: "d", ou: childOU)
            let projectB = try await builder.createProject(name: "Eq B", description: "d", ou: childOU)
            try await RoleBindingService.grant(
                principalType: .user, principalID: user.id!, role: .viewer,
                nodeType: .organizationalUnit, nodeID: ou.id!, createdBy: nil, on: app.db)

            var nodes: [IAMNode] = []
            for project in [projectA, projectB] {
                for index in 0..<3 {
                    let vm = try await builder.createVM(
                        name: "eq-\(project.name)-\(index)", project: project)
                    nodes.append(IAMNode(type: .virtualMachine, id: vm.id!))
                }
            }
            nodes += [
                IAMNode(type: .project, id: projectA.id!),
                IAMNode(type: .project, id: projectB.id!),
                IAMNode(type: .organizationalUnit, id: childOU.id!),
                IAMNode(type: .organizationalUnit, id: ou.id!),
                IAMNode(type: .organization, id: org.id!),
            ]

            // One shared cache resolves every node in sequence (as a list
            // request would), driving the splice; each result must equal the
            // independent uncached resolution — chain and leaf facts alike.
            let chainCache = IAMRequestCache()
            for node in nodes {
                let cached = try await IAMResourceTree.resolve(node, cache: chainCache, on: app.db)
                let uncached = try await IAMResourceTree.resolve(node, on: app.db)
                #expect(cached == uncached)
            }

            // Full slice equivalence: the memoized load produces the same entity
            // slice — and therefore the same Cedar verdict — as the uncached load.
            let sliceCache = IAMRequestCache()
            for node in nodes {
                let cached = try await EntitySliceLoader.load(
                    userID: user.id!, node: node, cache: sliceCache, on: app.db)
                let uncached = try await EntitySliceLoader.load(userID: user.id!, node: node, on: app.db)
                #expect(cached == uncached)
            }
        }
    }
}
