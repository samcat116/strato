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
/// same list at two sizes must cost the same number of queries.
///
/// **What has to vary is the number of distinct nodes decided, not the number
/// of rows.** The request memo (#686) already collapses a per-row loop to one
/// evaluation per distinct node, so a hundred pools sharing one organization
/// were never the expensive case and a test that grew only the row count would
/// pass against the very loop it means to forbid. What batching buys is the
/// step after that: the distinct nodes are decided *together*, over one
/// entity-slice load, instead of one full evaluation apiece. So the pool and
/// enrollment tests below grow the number of owning scopes, and the directory
/// test grows the account count — a user record being its own node, that is the
/// same thing there.
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

    /// A pool's read action follows the kind of scope owning it — `org:read`
    /// for an org-owned pool, `folder:read` for a folder-owned one — so the
    /// page costs two batched decisions here regardless of how many folders own
    /// pools. The org-owned pool is present throughout so the second action is
    /// always in play; what grows is the number of folders, which is what the
    /// old loop paid a full evaluation for.
    ///
    /// One viewer binding on the organization covers every folder beneath it,
    /// so growing the folder count adds nodes to decide without adding grants
    /// to read — the decisions are the only thing that could scale.
    @Test("GET /api/floating-ip-pools issues the same number of queries however many scopes own pools")
    func poolListQueryCountStaysBounded() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "pooluser", email: "pool@example.com", isSystemAdmin: false)
            let org = try await builder.createOrganization(name: "Pool Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "member")
            try await RoleBindingService.grant(
                principalType: .user, principalID: user.id!, role: .viewer,
                nodeType: .organization, nodeID: org.id!, createdBy: nil, on: app.db)

            // Allocated addresses need a project and a creator to hang on.
            let project = try await builder.createProject(
                name: "Pool Project", description: "d", organization: org)

            /// One /30 per pool, walked through 203.0.0.0/23 so no two pools
            /// overlap and every address stays a valid octet.
            func addPool(_ index: Int, scope: OrganizationScope) async throws {
                let base = index * 4
                let prefix = "203.0.\(base / 256)"
                let pool = FloatingIPPool(
                    name: "pool-\(String(format: "%03d", index))",
                    cidr: "\(prefix).\(base % 256)/30",
                    organizationScope: scope)
                try await pool.save(on: app.db)
                try await FloatingIP(
                    poolID: pool.id!,
                    address: "\(prefix).\(base % 256 + 1)",
                    projectID: project.id!,
                    createdByID: user.id!
                ).save(on: app.db)
            }

            // Pool 0 is org-owned; every later pool gets a folder of its own.
            try await addPool(0, scope: .organization(org.id!))
            var created = 1
            func addFolderPools(_ count: Int) async throws {
                for _ in 0..<count {
                    let index = created
                    created += 1
                    let folder = try await builder.createOU(
                        name: "Pool Folder \(index)", description: "d", organization: org)
                    try await addPool(index, scope: .organizationalUnit(folder.id!))
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

            try await addFolderPools(9)
            let ten = try await queriesToList(expecting: 10)
            try await addFolderPools(110)
            let oneTwenty = try await queriesToList(expecting: 120)

            #expect(
                oneTwenty == ten,
                "GET /api/floating-ip-pools issued \(oneTwenty) queries for 120 pools across 120 scopes but \(ten) for 10; authorization is scaling with the number of scopes"
            )
        }
    }

    /// Enrollments carry their scope as plain columns rather than parent
    /// relations, and `manage_agents` translates to `agent:manage` for either
    /// kind of owner — so org- and folder-owned rows share a single batch
    /// however many folders are involved.
    @Test("GET /api/agent-enrollments issues the same number of queries however many scopes own rows")
    func enrollmentListQueryCountStaysBounded() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "enrolluser", email: "enroll@example.com", isSystemAdmin: false)
            let org = try await builder.createOrganization(name: "Enroll Org")
            // `agent:manage` is an admin action, and the org admin binding
            // covers every folder beneath it.
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")

            func addEnrollment(_ index: Int, scope: OrganizationScope) async throws {
                try await AgentEnrollment(
                    agentName: "enroll-node-\(index)",
                    spiffeID: "spiffe://example.org/agent/enroll-node-\(index)",
                    organizationScope: scope
                ).save(on: app.db)
            }

            // Enrollment 0 is org-owned; every later one gets its own folder.
            try await addEnrollment(0, scope: .organization(org.id!))
            var created = 1
            func addFolderEnrollments(_ count: Int) async throws {
                for _ in 0..<count {
                    let index = created
                    created += 1
                    let folder = try await builder.createOU(
                        name: "Enroll Folder \(index)", description: "d", organization: org)
                    try await addEnrollment(index, scope: .organizationalUnit(folder.id!))
                }
            }

            func queriesToList(expecting expected: Int) async throws -> Int {
                try await queryCount(
                    as: user, path: "/api/agent-enrollments", on: app,
                    running: { try await AgentController().listEnrollments(req: $0) },
                    expecting: { $0.count == expected })
            }

            try await addFolderEnrollments(9)
            let ten = try await queriesToList(expecting: 10)
            try await addFolderEnrollments(110)
            let oneTwenty = try await queriesToList(expecting: 120)

            #expect(
                oneTwenty == ten,
                "GET /api/agent-enrollments issued \(oneTwenty) queries for 120 enrollments across 120 scopes but \(ten) for 10; authorization is scaling with the number of scopes"
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
