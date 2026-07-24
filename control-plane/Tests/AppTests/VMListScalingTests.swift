import Fluent
import Testing
import Vapor
import VaporTesting

@testable import App

/// Regression tests for the `GET /api/vms` 504 past ~200 VMs.
///
/// The endpoint got here in three steps. It ran one `req.can("read", …)` per VM
/// at ~7 queries each; #686 memoized the caller's memberships and each node's
/// resolved chain per request; #710 additionally cached each container's suffix,
/// so VMs sharing a project stopped re-walking the shared project→org path,
/// leaving one row read per leaf. #687 removed the per-leaf residue too: the
/// page is now one batched decision over one entity-slice load, and every read
/// on the path is set-based.
///
/// The property under test is *shape*, not wall-clock — and it is now an
/// equality rather than a budget: the same list at two sizes must cost the same
/// number of queries. Any per-row read that creeps back in fails it.
///
/// `cachedResolutionMatchesUncached` guards the other half — that all this
/// caching and batching still produces the chain a lone uncached walk would.
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

    @Test("GET /api/vms issues the same number of queries however many VMs it returns")
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
            // scoping decides a real (allowed) check per VM rather than
            // short-circuiting on a denial.
            try await RoleBindingService.grant(
                principalType: .user, principalID: user.id!, role: .viewer,
                nodeType: .project, nodeID: project.id!, createdBy: nil, on: app.db)

            /// Drive `VMController.index` with a request we own so Fluent's
            /// per-request query history (enabled on the request, not the app)
            /// records exactly the DB work the list endpoint does. A fresh
            /// request each time, so no memo carries between measurements.
            func queriesToList(expecting expected: Int) async throws -> Int {
                let req = Request(
                    application: app, method: .GET, url: URI(path: "/api/vms"),
                    on: app.eventLoopGroup.next())
                req.auth.login(user)
                req.fluent.history.start()
                let vms = try await VMController().visibleVMs(req: req)
                req.fluent.history.stop()
                #expect(vms.count == expected)
                return req.fluent.history.queries.count
            }

            for index in 0..<10 {
                _ = try await builder.createVM(name: "scale-vm-\(index)", project: project)
            }
            let ten = try await queriesToList(expecting: 10)

            for index in 10..<120 {
                _ = try await builder.createVM(name: "scale-vm-\(index)", project: project)
            }
            let oneTwenty = try await queriesToList(expecting: 120)

            // Equal, not merely sub-linear. Since #687 the whole page is one
            // batched decision over one entity-slice load, so list size changes
            // the size of the `IN` clauses and nothing else — every read on the
            // path (the VM rows, their eager-loaded interfaces, the chain walk,
            // the caller's memberships, the bindings) is set-based. A regression
            // that reintroduced any per-row read would show up here as a
            // difference of 110.
            #expect(
                oneTwenty == ten,
                "GET /api/vms issued \(oneTwenty) queries for 120 VMs but \(ten) for 10; authorization or hydration is scaling with list size"
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
