import Fluent
import Testing
import Vapor
import VaporTesting

@testable import App

/// The `VMListScalingTests` property, applied to the three list endpoints that
/// still looped a per-row `req.can` after #687 batched the rest: floating IP
/// pools, agent enrollments, and the user directory.
///
/// Same shape, same assertion: the property under test is the *number of
/// queries*, not wall-clock, and it is an equality rather than a budget — the
/// same list at two sizes must cost the same number of queries. Any per-row
/// authorization check or per-row `COUNT` that creeps back in fails it by a
/// margin equal to the size difference.
///
/// Each endpoint is driven with a request the test owns, so Fluent's
/// per-request query history (enabled on the request, not the application)
/// records exactly the database work the handler does, and a fresh request per
/// measurement keeps a memo from carrying between them.
@Suite("List Authorization Scaling Tests", .serialized)
final class ListAuthorizationScalingTests {

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

    /// Queries issued by one run of `handler`, on a request authenticated as
    /// `user`.
    private func queryCount<Result>(
        as user: User,
        path: String,
        on app: Application,
        running handler: (Request) async throws -> Result,
        expecting check: (Result) -> Bool
    ) async throws -> Int {
        let req = Request(
            application: app, method: .GET, url: URI(path: path), on: app.eventLoopGroup.next())
        req.auth.login(user)
        req.fluent.history.start()
        let result = try await handler(req)
        req.fluent.history.stop()
        #expect(check(result))
        return req.fluent.history.queries.count
    }

    /// Pools are scoped infrastructure, so the page costs one batched decision
    /// per distinct scope action — `org:read` for an org-owned pool,
    /// `folder:read` for a folder-owned one — plus one grouped `COUNT` for
    /// every pool's allocated addresses. Both kinds of owner are present here,
    /// so a regression that split the decisions back out per pool shows up as a
    /// difference of 110.
    ///
    /// The grouped `COUNT` goes out as raw SQL, which Fluent's history does not
    /// record — so what guards it here is the returned `allocatedCount` of
    /// every pool, while the query equality guards the per-pool `COUNT` this
    /// replaced (that one *was* a Fluent query, and would reappear in the
    /// history if it came back).
    @Test("GET /api/floating-ip-pools issues the same number of queries however many pools it returns")
    func poolListQueryCountStaysBounded() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "pooluser", email: "pool@example.com", isSystemAdmin: false)
            let org = try await builder.createOrganization(name: "Pool Org")
            // Bare membership already grants `org:read`; the folder needs a
            // binding, so viewer on the folder supplies `folder:read`.
            try await builder.addUserToOrganization(user: user, organization: org, role: "member")
            let folder = try await builder.createOU(
                name: "Pool Folder", description: "d", organization: org)
            try await RoleBindingService.grant(
                principalType: .user, principalID: user.id!, role: .viewer,
                nodeType: .organizationalUnit, nodeID: folder.id!, createdBy: nil, on: app.db)

            // Allocated addresses need a project and a creator to hang on.
            let project = try await builder.createProject(
                name: "Pool Project", description: "d", organization: org)

            /// Create `count` pools, alternating owner between the org and the
            /// folder, each carrying one allocated address.
            var created = 0
            func addPools(_ count: Int) async throws {
                for _ in 0..<count {
                    let index = created
                    created += 1
                    let scope: OrganizationScope =
                        index.isMultiple(of: 2) ? .organization(org.id!) : .organizationalUnit(folder.id!)
                    // One /30 per pool, walked through 203.0.0.0/23 so no two
                    // pools overlap and every address stays a valid octet.
                    let base = index * 4
                    let prefix = "203.0.\(base / 256)"
                    let pool = FloatingIPPool(
                        name: "pool-\(index)",
                        cidr: "\(prefix).\(base % 256)/30",
                        organizationScope: scope)
                    try await pool.save(on: app.db)
                    let floatingIP = FloatingIP(
                        poolID: pool.id!,
                        address: "\(prefix).\(base % 256 + 1)",
                        projectID: project.id!,
                        createdByID: user.id!)
                    try await floatingIP.save(on: app.db)
                }
            }

            func queriesToList(expecting expected: Int) async throws -> Int {
                try await queryCount(
                    as: user, path: "/api/floating-ip-pools", on: app,
                    running: { try await FloatingIPController().listPools(req: $0) },
                    expecting: { pools in
                        pools.count == expected && pools.allSatisfy { $0.allocatedCount == 1 }
                    })
            }

            try await addPools(10)
            let ten = try await queriesToList(expecting: 10)
            try await addPools(110)
            let oneTwenty = try await queriesToList(expecting: 120)

            #expect(
                oneTwenty == ten,
                "GET /api/floating-ip-pools issued \(oneTwenty) queries for 120 pools but \(ten) for 10; authorization or the allocation counts are scaling with list size"
            )
        }
    }

    /// Enrollments carry their scope as plain columns rather than parent
    /// relations, and `manage_agents` translates to `agent:manage` for either
    /// kind of owner — so org- and folder-owned rows share a single batch.
    @Test("GET /api/agent-enrollments issues the same number of queries however many rows it returns")
    func enrollmentListQueryCountStaysBounded() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "enrolluser", email: "enroll@example.com", isSystemAdmin: false)
            let org = try await builder.createOrganization(name: "Enroll Org")
            // `agent:manage` is an admin action, and the org admin binding
            // covers the folder beneath it too.
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            let folder = try await builder.createOU(
                name: "Enroll Folder", description: "d", organization: org)

            var created = 0
            func addEnrollments(_ count: Int) async throws {
                for _ in 0..<count {
                    let index = created
                    created += 1
                    let scope: OrganizationScope =
                        index.isMultiple(of: 2) ? .organization(org.id!) : .organizationalUnit(folder.id!)
                    let enrollment = AgentEnrollment(
                        agentName: "enroll-node-\(index)",
                        spiffeID: "spiffe://example.org/agent/enroll-node-\(index)",
                        organizationScope: scope)
                    try await enrollment.save(on: app.db)
                }
            }

            func queriesToList(expecting expected: Int) async throws -> Int {
                try await queryCount(
                    as: user, path: "/api/agent-enrollments", on: app,
                    running: { try await AgentController().listEnrollments(req: $0) },
                    expecting: { $0.count == expected })
            }

            try await addEnrollments(10)
            let ten = try await queriesToList(expecting: 10)
            try await addEnrollments(110)
            let oneTwenty = try await queriesToList(expecting: 120)

            #expect(
                oneTwenty == ten,
                "GET /api/agent-enrollments issued \(oneTwenty) queries for 120 enrollments but \(ten) for 10; authorization is scaling with list size"
            )
        }
    }

    /// The directory as a system admin sees it: every account is a real
    /// (allowed) `user:read` decision through `platform-system-admin`, so the
    /// whole page rides on one batch.
    @Test("GET /api/users issues the same number of queries however many accounts it returns")
    func userListQueryCountStaysBounded() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let admin = try await builder.createUser(
                username: "diradmin", email: "diradmin@example.com", isSystemAdmin: true)

            var created = 0
            func addUsers(_ count: Int) async throws {
                for _ in 0..<count {
                    let index = created
                    created += 1
                    _ = try await builder.createUser(
                        username: "dir-\(index)", email: "dir-\(index)@example.com")
                }
            }

            func queriesToList(expecting expected: Int) async throws -> Int {
                try await queryCount(
                    as: admin, path: "/api/users", on: app,
                    running: { try await UserController().index(req: $0) },
                    expecting: { $0.count == expected })
            }

            // +1 for the admin's own record.
            try await addUsers(10)
            let ten = try await queriesToList(expecting: 11)
            try await addUsers(110)
            let oneTwenty = try await queriesToList(expecting: 121)

            #expect(
                oneTwenty == ten,
                "GET /api/users issued \(oneTwenty) queries for 121 accounts but \(ten) for 11; authorization is scaling with list size"
            )
        }
    }

    /// The other half of the directory change: a caller who is not an admin
    /// and holds no binding on anyone's record reaches exactly their own, so
    /// the narrowing keeps the row query off every other account rather than
    /// fetching the installation and denying it one row at a time.
    @Test("GET /api/users narrows to the caller's own record and does not grow with the directory")
    func userListNarrowsForNonAdmin() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "diruser", email: "diruser@example.com", isSystemAdmin: false)
            let org = try await builder.createOrganization(name: "Dir Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")

            func queriesToList() async throws -> Int {
                try await queryCount(
                    as: user, path: "/api/users", on: app,
                    running: { try await UserController().index(req: $0) },
                    expecting: { $0.map(\.username) == ["diruser"] })
            }

            for index in 0..<10 {
                _ = try await builder.createUser(
                    username: "other-\(index)", email: "other-\(index)@example.com")
            }
            let ten = try await queriesToList()

            for index in 10..<120 {
                _ = try await builder.createUser(
                    username: "other-\(index)", email: "other-\(index)@example.com")
            }
            let oneTwenty = try await queriesToList()

            #expect(
                oneTwenty == ten,
                "GET /api/users issued \(oneTwenty) queries against a 120-account directory but \(ten) against a 10-account one; the narrowing is not holding"
            )
        }
    }

    /// The narrowing must never be the thing that denies: a binding on another
    /// account's record is the one way a non-admin could hold `user:read` on
    /// someone else (through a custom role — no seeded role carries the
    /// identity actions), so that record has to survive narrowing and reach the
    /// evaluator, whatever the evaluator then says about it.
    ///
    /// Asserted on the candidate set rather than on the endpoint's output
    /// precisely because the two differ here: with only seeded roles in play
    /// the evaluator denies the bound record, so a test on the response could
    /// not tell "narrowed away" from "evaluated and denied" — and that is the
    /// confusion under which the narrowing could quietly start deciding.
    @Test("A binding on another user's record survives the directory narrowing")
    func narrowingAdmitsBoundRecords() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "boundcaller", email: "boundcaller@example.com", isSystemAdmin: false)
            let subject = try await builder.createUser(
                username: "boundsubject", email: "boundsubject@example.com", isSystemAdmin: false)
            let unrelated = try await builder.createUser(
                username: "unrelated", email: "unrelated@example.com", isSystemAdmin: false)

            try await RoleBindingService.grant(
                principalType: .user, principalID: user.id!, role: .admin,
                nodeType: .user, nodeID: subject.id!, createdBy: nil, on: app.db)

            let req = Request(
                application: app, method: .GET, url: URI(path: "/api/users"),
                on: app.eventLoopGroup.next())
            req.auth.login(user)
            let visibility = try await UserDirectoryVisibility.resolve(on: req)

            let candidates = try #require(visibility.candidateUserIDs)
            #expect(Set(candidates) == [user.id!, subject.id!])
            #expect(!candidates.contains(unrelated.id!))
        }
    }

    /// A group's bindings are the caller's own, so a record bound to a group
    /// they belong to is a candidate too.
    @Test("A group binding on another user's record survives the directory narrowing")
    func narrowingAdmitsGroupBoundRecords() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "groupcaller", email: "groupcaller@example.com", isSystemAdmin: false)
            let subject = try await builder.createUser(
                username: "groupsubject", email: "groupsubject@example.com", isSystemAdmin: false)
            let org = try await builder.createOrganization(name: "Group Org")
            let group = try await builder.createGroup(
                name: "Directory Readers", description: "d", organization: org)
            try await UserGroup(userID: user.id!, groupID: group.id!).save(on: app.db)

            try await RoleBindingService.grant(
                principalType: .group, principalID: group.id!, role: .admin,
                nodeType: .user, nodeID: subject.id!, createdBy: nil, on: app.db)

            let req = Request(
                application: app, method: .GET, url: URI(path: "/api/users"),
                on: app.eventLoopGroup.next())
            req.auth.login(user)
            let visibility = try await UserDirectoryVisibility.resolve(on: req)

            #expect(Set(try #require(visibility.candidateUserIDs)) == [user.id!, subject.id!])
        }
    }

    /// A system admin is not narrowed at all: their reach is the tier-1 policy
    /// rather than a binding, so a bindings-derived candidate set would be just
    /// their own record and would hide the directory the evaluator allows.
    @Test("A system admin's directory is not narrowed")
    func narrowingSkipsSystemAdmins() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let admin = try await builder.createUser(
                username: "nonarrowadmin", email: "nonarrowadmin@example.com", isSystemAdmin: true)

            let req = Request(
                application: app, method: .GET, url: URI(path: "/api/users"),
                on: app.eventLoopGroup.next())
            req.auth.login(admin)
            let visibility = try await UserDirectoryVisibility.resolve(on: req)

            #expect(visibility.candidateUserIDs == nil)
        }
    }
}
