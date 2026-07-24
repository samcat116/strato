import Fluent
import Testing
import Vapor
import VaporTesting

@testable import App

/// Issue #699: the list endpoints that decorated every row they returned with a
/// `COUNT` of its own.
///
/// The property under test is *shape*, not wall-clock, and it is an equality
/// rather than a budget: the same page at two sizes must cost the same number
/// of queries. A per-row count creeping back in shows up here as a difference
/// equal to the size gap. Each test also asserts the counts themselves, because
/// a batched aggregate that mislabels its keys is just as wrong as a slow one.
@Suite("List Count Batching Tests", .serialized)
final class ListCountBatchingTests {

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

    /// Drives a handler with a request the test owns, so Fluent's per-request
    /// query history (enabled on the request, not the app) records exactly the
    /// database work that handler does. A fresh request each time, so no
    /// per-request memo carries between measurements.
    private func measure(
        on app: Application,
        as user: User,
        path: String,
        parameters: [String: String] = [:],
        _ work: (Request) async throws -> Void
    ) async throws -> Int {
        let req = Request(
            application: app, method: .GET, url: URI(path: path),
            on: app.eventLoopGroup.next())
        req.auth.login(user)
        for (name, value) in parameters {
            req.parameters.set(name, to: value)
        }
        req.fluent.history.start()
        try await work(req)
        req.fluent.history.stop()
        return req.fluent.history.queries.count
    }

    // MARK: - Projects

    @Test("GET /api/projects costs the same however many projects it summarizes")
    func projectSummariesDoNotCountPerProject() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(username: "projuser", email: "proj@example.com")
            let org = try await builder.createOrganization(name: "Project Count Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")

            /// The first project carries VMs so the summary counts a non-zero
            /// value through the grouped aggregate, not just zeros.
            let first = try await builder.createProject(
                name: "project-000", description: "with VMs", organization: org)
            for index in 0..<3 {
                _ = try await builder.createVM(name: "count-vm-\(index)", project: first)
            }

            func queriesToList(expecting expected: Int) async throws -> Int {
                try await measure(on: app, as: user, path: "/api/projects") { req in
                    try await OpenAPIRequestContext.$current.withValue(req) {
                        let output = try await ProjectsAPIService().listProjects(.init())
                        guard case .ok(let ok) = output, case .json(let summaries) = ok.body else {
                            Issue.record("listProjects did not return 200 JSON")
                            return
                        }
                        #expect(summaries.count == expected)
                        #expect(summaries.first(where: { $0.name == "project-000" })?.vmCount == 3)
                        #expect(summaries.filter { $0.vmCount == 0 }.count == expected - 1)
                    }
                }
            }

            for index in 1..<4 {
                _ = try await builder.createProject(
                    name: "project-\(String(format: "%03d", index))", description: "d", organization: org)
            }
            let four = try await queriesToList(expecting: 4)

            for index in 4..<40 {
                _ = try await builder.createProject(
                    name: "project-\(String(format: "%03d", index))", description: "d", organization: org)
            }
            let forty = try await queriesToList(expecting: 40)

            #expect(
                forty == four,
                "GET /api/projects issued \(forty) queries for 40 projects but \(four) for 4")
        }
    }

    // MARK: - Networks

    @Test("GET /api/networks costs the same however many networks it lists")
    func networkListDoesNotCountPerNetwork() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "netuser", email: "net@example.com", isSystemAdmin: true)
            let org = try await builder.createOrganization(name: "Network Count Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            let project = try await builder.createProject(
                name: "Network Count Project", description: "d", organization: org)
            /// NICs on the first network only: the grouped count has to put
            /// them under that name and leave every other network at zero. One
            /// VM per NIC — a VM's interfaces are unique by device name.
            func addNetwork(_ index: Int, nics: Int = 0) async throws {
                let network = LogicalNetwork(
                    name: "net-\(String(format: "%03d", index))",
                    subnet: "10.\(index).0.0/24", gateway: "10.\(index).0.1",
                    projectID: project.id, externalAccess: false)
                try await network.save(on: app.db)
                for nic in 0..<nics {
                    let vm = try await builder.createVM(name: "nic-holder-\(index)-\(nic)", project: project)
                    try await VMNetworkInterface(
                        vmID: vm.id!, network: network.name,
                        macAddress: VMNetworkInterface.generateMACAddress()
                    ).save(on: app.db)
                }
            }
            try await addNetwork(0, nics: 2)

            func queriesToList(expecting expected: Int) async throws -> Int {
                try await measure(on: app, as: user, path: "/api/networks") { req in
                    // The seeded default network rides along in the page; the
                    // assertions are about the ones this test made.
                    let networks = try await NetworkController().listNetworks(req: req)
                        .filter { $0.name.hasPrefix("net-") }
                    #expect(networks.count == expected)
                    #expect(networks.first(where: { $0.name == "net-000" })?.attachedInterfaceCount == 2)
                    #expect(networks.filter { $0.attachedInterfaceCount == 0 }.count == expected - 1)
                }
            }

            for index in 1..<5 { try await addNetwork(index) }
            let five = try await queriesToList(expecting: 5)

            for index in 5..<40 { try await addNetwork(index) }
            let forty = try await queriesToList(expecting: 40)

            #expect(
                forty == five,
                "GET /api/networks issued \(forty) queries for 40 networks but \(five) for 5")
        }
    }

    // MARK: - Floating IP pools

    @Test("GET /api/floating-ip-pools costs the same however many pools it lists")
    func poolListDoesNotCountPerPool() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "pooluser", email: "pool@example.com", isSystemAdmin: true)
            let org = try await builder.createOrganization(name: "Pool Count Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            let project = try await builder.createProject(
                name: "Pool Count Project", description: "d", organization: org)

            func addPool(_ index: Int, allocations: Int = 0) async throws {
                let pool = FloatingIPPool(
                    name: "pool-\(String(format: "%03d", index))",
                    cidr: "203.0.\(index).0/24", gateway: "203.0.\(index).1",
                    organizationScope: .organization(org.id!))
                try await pool.save(on: app.db)
                for allocation in 0..<allocations {
                    try await FloatingIP(
                        poolID: pool.id!, address: "203.0.\(index).\(allocation + 2)",
                        projectID: project.id!
                    ).save(on: app.db)
                }
            }
            try await addPool(0, allocations: 2)

            func queriesToList(expecting expected: Int) async throws -> Int {
                try await measure(on: app, as: user, path: "/api/floating-ip-pools") { req in
                    let pools = try await FloatingIPController().listPools(req: req)
                    #expect(pools.count == expected)
                    #expect(pools.first(where: { $0.name == "pool-000" })?.allocatedCount == 2)
                    #expect(pools.filter { $0.allocatedCount == 0 }.count == expected - 1)
                }
            }

            for index in 1..<5 { try await addPool(index) }
            let five = try await queriesToList(expecting: 5)

            for index in 5..<40 { try await addPool(index) }
            let forty = try await queriesToList(expecting: 40)

            #expect(
                forty == five,
                "GET /api/floating-ip-pools issued \(forty) queries for 40 pools but \(five) for 5")
        }
    }

    // MARK: - Groups

    @Test("Listing an organization's groups costs the same however many there are")
    func groupListDoesNotCountPerGroup() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(username: "groupuser", email: "group@example.com")
            let org = try await builder.createOrganization(name: "Group Count Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")

            let first = try await builder.createGroup(
                name: "group-000", description: "with members", organization: org)
            for index in 0..<2 {
                let member = try await builder.createUser(
                    username: "member-\(index)", email: "member-\(index)@example.com")
                try await first.$users.attach(member, on: app.db)
            }

            func queriesToList(expecting expected: Int) async throws -> Int {
                try await measure(
                    on: app, as: user, path: "/api/organizations/\(org.id!)/groups",
                    parameters: ["organizationID": org.id!.uuidString]
                ) { req in
                    let groups = try await GroupController().index(req: req)
                    #expect(groups.count == expected)
                    #expect(groups.first(where: { $0.name == "group-000" })?.memberCount == 2)
                    #expect(groups.filter { $0.memberCount == 0 }.count == expected - 1)
                }
            }

            for index in 1..<5 {
                _ = try await builder.createGroup(
                    name: "group-\(String(format: "%03d", index))", description: "d", organization: org)
            }
            let five = try await queriesToList(expecting: 5)

            for index in 5..<40 {
                _ = try await builder.createGroup(
                    name: "group-\(String(format: "%03d", index))", description: "d", organization: org)
            }
            let forty = try await queriesToList(expecting: 40)

            #expect(
                forty == five,
                "Listing groups issued \(forty) queries for 40 groups but \(five) for 5")
        }
    }

    // MARK: - Folders

    @Test("Listing an organization's folders costs the same however many there are")
    func folderListDoesNotCountPerFolder() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(username: "foldruser", email: "foldr@example.com")
            let org = try await builder.createOrganization(name: "Folder Count Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")

            // The first folder has both a child folder and a project, so the
            // two grouped counts have something to distinguish.
            let first = try await builder.createOU(
                name: "folder-000", description: "populated", organization: org)
            _ = try await builder.createOU(
                name: "child", description: "d", organization: org, parentOU: first)
            _ = try await builder.createProject(name: "in-folder", description: "d", ou: first)

            func queriesToList(expecting expected: Int) async throws -> Int {
                try await measure(
                    on: app, as: user, path: "/api/organizations/\(org.id!)/ous",
                    parameters: ["organizationID": org.id!.uuidString]
                ) { req in
                    let folders = try await OrganizationalUnitController().index(req: req)
                    #expect(folders.count == expected)
                    let populated = folders.first { $0.name == "folder-000" }
                    #expect(populated?.childOuCount == 1)
                    #expect(populated?.projectCount == 1)
                    #expect(folders.filter { $0.childOuCount == 0 && $0.projectCount == 0 }.count == expected - 1)
                }
            }

            for index in 1..<5 {
                _ = try await builder.createOU(
                    name: "folder-\(String(format: "%03d", index))", description: "d", organization: org)
            }
            let five = try await queriesToList(expecting: 5)

            for index in 5..<40 {
                _ = try await builder.createOU(
                    name: "folder-\(String(format: "%03d", index))", description: "d", organization: org)
            }
            let forty = try await queriesToList(expecting: 40)

            #expect(
                forty == five,
                "Listing folders issued \(forty) queries for 40 folders but \(five) for 5")
        }
    }

    @Test("The folder tree costs the same however deep and wide the subtree is")
    func folderTreeDoesNotQueryPerFolder() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(username: "treeuser", email: "tree@example.com")
            let org = try await builder.createOrganization(name: "Folder Tree Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")

            let root = try await builder.createOU(name: "root", description: "d", organization: org)
            _ = try await builder.createProject(name: "at-root", description: "d", ou: root)

            /// A chain under `root`, so the recursion this replaced would pay
            /// per level as well as per sibling.
            func growChain(from parent: OrganizationalUnit, depth: Int, prefix: String) async throws {
                var current = parent
                for level in 0..<depth {
                    current = try await builder.createOU(
                        name: "\(prefix)-\(level)", description: "d", organization: org, parentOU: current)
                }
            }

            func queriesForTree(expecting expected: Int) async throws -> Int {
                try await measure(
                    on: app, as: user, path: "/api/organizations/\(org.id!)/ous/\(root.id!)/tree",
                    parameters: [
                        "organizationID": org.id!.uuidString,
                        "ouID": root.id!.uuidString,
                    ]
                ) { req in
                    let tree = try await OrganizationalUnitController().getTree(req: req)
                    #expect(tree.projectCount == 1)
                    #expect(Self.folderCount(in: tree) == expected)
                }
            }

            try await growChain(from: root, depth: 3, prefix: "small")
            let small = try await queriesForTree(expecting: 4)

            try await growChain(from: root, depth: 20, prefix: "big")
            let big = try await queriesForTree(expecting: 24)

            #expect(
                big == small,
                "The folder tree issued \(big) queries for 24 folders but \(small) for 4")
        }
    }

    /// The folder and every descendant in the assembled tree.
    private static func folderCount(in tree: OrganizationalUnitTreeResponse) -> Int {
        1 + tree.children.reduce(0) { $0 + folderCount(in: $1) }
    }

    // MARK: - Organizations

    @Test("Listing the caller's organizations costs the same however many they belong to")
    func organizationListDoesNotLookUpPerOrganization() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(username: "orguser", email: "org@example.com")

            let admin = try await builder.createOrganization(name: "org-000")
            try await builder.addUserToOrganization(user: user, organization: admin, role: "admin")

            func queriesToList(expecting expected: Int) async throws -> Int {
                try await measure(on: app, as: user, path: "/api/organizations") { req in
                    let organizations = try await OrganizationController().index(req: req)
                    #expect(organizations.count == expected)
                    #expect(organizations.first { $0.name == "org-000" }?.userRole == "admin")
                    #expect(organizations.filter { $0.userRole == "member" }.count == expected - 1)
                }
            }

            for index in 1..<5 {
                let org = try await builder.createOrganization(name: "org-\(String(format: "%03d", index))")
                try await builder.addUserToOrganization(user: user, organization: org, role: "member")
            }
            let five = try await queriesToList(expecting: 5)

            for index in 5..<40 {
                let org = try await builder.createOrganization(name: "org-\(String(format: "%03d", index))")
                try await builder.addUserToOrganization(user: user, organization: org, role: "member")
            }
            let forty = try await queriesToList(expecting: 40)

            #expect(
                forty == five,
                "Listing organizations issued \(forty) queries for 40 orgs but \(five) for 5")
        }
    }
}
