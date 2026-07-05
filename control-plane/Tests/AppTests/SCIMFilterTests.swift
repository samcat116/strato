import Testing
import Foundation
import Vapor
import Fluent
import VaporTesting
import SwiftSCIM
@testable import App

/// Tests for SCIM search/filter handling.
///
/// These exercise the `co`/`sw`/`ew`/`eq` operators through the real
/// `UserSCIMHandler`/`GroupSCIMHandler` search paths. Case-insensitive matching must
/// work on whichever database the test harness runs against (SQLite locally, and
/// PostgreSQL when `STRATO_TEST_DATABASE` selects it) — the previous implementation
/// used Postgres-only `ILIKE`, which is a syntax error on SQLite.
@Suite("SCIM Filter Tests", .serialized)
final class SCIMFilterTests: BaseTestCase {

    // MARK: - Helpers

    private func makeContext() -> SCIMRequestContext {
        SCIMRequestContext(
            auth: .anonymous,
            baseURL: URL(string: "http://localhost:8080/scim/v2")!,
            request: SCIMRequest(method: .GET, path: "/Users")
        )
    }

    private func userQuery(_ filter: SCIMFilterExpression) -> SCIMServerQuery {
        SCIMServerQuery(filter: filter)
    }

    /// Search users in `org` with a single-attribute filter, returning the matched usernames.
    private func searchUsernames(
        _ app: Application,
        org: Organization,
        path: String,
        op: SCIMFilterOperator,
        value: String
    ) async throws -> [String] {
        let handler = UserSCIMHandler(db: app.db, organizationID: org.id!, spicedb: try app.spicedb)
        let query = userQuery(.attribute(path, op, value))
        let response = try await handler.search(query: query, context: makeContext())
        return response.Resources.map(\.userName).sorted()
    }

    /// Search groups in `org` with a single-attribute filter, returning the matched display names.
    private func searchGroupNames(
        _ app: Application,
        org: Organization,
        path: String,
        op: SCIMFilterOperator,
        value: String
    ) async throws -> [String] {
        let handler = GroupSCIMHandler(db: app.db, organizationID: org.id!, spicedb: try app.spicedb)
        let query = SCIMServerQuery(filter: .attribute(path, op, value))
        let response = try await handler.search(query: query, context: makeContext())
        return response.Resources.map(\.displayName).sorted()
    }

    @discardableResult
    private func createUser(
        _ builder: TestDataBuilder,
        username: String,
        displayName: String,
        org: Organization
    ) async throws -> User {
        let user = try await builder.createUser(
            username: username,
            email: "\(username.lowercased())@example.com",
            displayName: displayName
        )
        try await builder.addUserToOrganization(user: user, organization: org)
        return user
    }

    // MARK: - User username filters

    @Test("User co (contains) is case-insensitive")
    func testUserContainsCaseInsensitive() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "Org A")
            try await createUser(builder, username: "Alice", displayName: "Alice Anderson", org: org)
            try await createUser(builder, username: "bob", displayName: "Bob Builder", org: org)
            try await createUser(builder, username: "CAROL", displayName: "Carol Danvers", org: org)

            // Lowercase query must match the mixed-case "Alice".
            #expect(try await searchUsernames(app, org: org, path: "userName", op: .contains, value: "lic") == ["Alice"])
            // Uppercase query must match the lowercase "bob".
            #expect(try await searchUsernames(app, org: org, path: "userName", op: .contains, value: "OB") == ["bob"])
        }
    }

    @Test("User sw (startsWith) is case-insensitive")
    func testUserStartsWithCaseInsensitive() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "Org A")
            try await createUser(builder, username: "Alice", displayName: "Alice Anderson", org: org)
            try await createUser(builder, username: "bob", displayName: "Bob Builder", org: org)
            try await createUser(builder, username: "CAROL", displayName: "Carol Danvers", org: org)

            #expect(try await searchUsernames(app, org: org, path: "userName", op: .startsWith, value: "ALI") == ["Alice"])
            // "car" should match "CAROL" but not "Alice"/"bob".
            #expect(try await searchUsernames(app, org: org, path: "userName", op: .startsWith, value: "car") == ["CAROL"])
        }
    }

    @Test("User ew (endsWith) is case-insensitive")
    func testUserEndsWithCaseInsensitive() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "Org A")
            try await createUser(builder, username: "Alice", displayName: "Alice Anderson", org: org)
            try await createUser(builder, username: "CAROL", displayName: "Carol Danvers", org: org)

            #expect(try await searchUsernames(app, org: org, path: "userName", op: .endsWith, value: "ROL") == ["CAROL"])
            #expect(try await searchUsernames(app, org: org, path: "userName", op: .endsWith, value: "ICE") == ["Alice"])
        }
    }

    @Test("User eq (equal) matches exactly")
    func testUserEqualExact() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "Org A")
            try await createUser(builder, username: "Alice", displayName: "Alice Anderson", org: org)
            try await createUser(builder, username: "bob", displayName: "Bob Builder", org: org)

            #expect(try await searchUsernames(app, org: org, path: "userName", op: .equal, value: "Alice") == ["Alice"])
            #expect(try await searchUsernames(app, org: org, path: "userName", op: .equal, value: "nobody").isEmpty)
        }
    }

    // MARK: - User displayName filters

    @Test("User displayName co/sw/ew are case-insensitive")
    func testUserDisplayNameFilters() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "Org A")
            try await createUser(builder, username: "alice", displayName: "Alice Anderson", org: org)
            try await createUser(builder, username: "bob", displayName: "Bob Builder", org: org)

            #expect(try await searchUsernames(app, org: org, path: "displayName", op: .contains, value: "BUILD") == ["bob"])
            #expect(try await searchUsernames(app, org: org, path: "displayName", op: .startsWith, value: "alice") == ["alice"])
            #expect(try await searchUsernames(app, org: org, path: "displayName", op: .endsWith, value: "anderson") == ["alice"])
        }
    }

    // MARK: - Escaping & scoping

    @Test("User co escapes LIKE wildcards so they match literally")
    func testUserContainsEscapesWildcards() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "Org A")
            try await createUser(builder, username: "tenPercent", displayName: "No Symbol", org: org)
            try await createUser(builder, username: "ten%off", displayName: "Has Percent", org: org)

            // A literal "%" must be escaped: it should match only the username that
            // actually contains "%", not every row (which is what an unescaped
            // wildcard would do).
            #expect(try await searchUsernames(app, org: org, path: "userName", op: .contains, value: "%") == ["ten%off"])
        }
    }

    @Test("User filter is scoped to the organization")
    func testUserFilterRespectsOrganizationScope() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let orgA = try await builder.createOrganization(name: "Org A")
            let orgB = try await builder.createOrganization(name: "Org B")
            try await createUser(builder, username: "Alice", displayName: "Alice Anderson", org: orgA)
            try await createUser(builder, username: "AliceClone", displayName: "Alice Clone", org: orgB)

            // "alice" matches both usernames case-insensitively, but only Org A's user
            // should be returned when searching Org A.
            #expect(try await searchUsernames(app, org: orgA, path: "userName", op: .contains, value: "alice") == ["Alice"])
            #expect(try await searchUsernames(app, org: orgB, path: "userName", op: .contains, value: "alice") == ["AliceClone"])
        }
    }

    // MARK: - Group displayName filters

    @Test("Group displayName co/sw/ew/eq behave correctly and case-insensitively")
    func testGroupDisplayNameFilters() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "Org A")
            _ = try await builder.createGroup(name: "Platform", description: "", organization: org)
            _ = try await builder.createGroup(name: "platform-eng", description: "", organization: org)
            _ = try await builder.createGroup(name: "Design", description: "", organization: org)

            #expect(try await searchGroupNames(app, org: org, path: "displayName", op: .contains, value: "PLAT") == ["Platform", "platform-eng"])
            #expect(try await searchGroupNames(app, org: org, path: "displayName", op: .startsWith, value: "plat") == ["Platform", "platform-eng"])
            #expect(try await searchGroupNames(app, org: org, path: "displayName", op: .endsWith, value: "ENG") == ["platform-eng"])
            #expect(try await searchGroupNames(app, org: org, path: "displayName", op: .equal, value: "Design") == ["Design"])
        }
    }

    @Test("Group filter is scoped to the organization")
    func testGroupFilterRespectsOrganizationScope() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let orgA = try await builder.createOrganization(name: "Org A")
            let orgB = try await builder.createOrganization(name: "Org B")
            _ = try await builder.createGroup(name: "Platform", description: "", organization: orgA)
            _ = try await builder.createGroup(name: "PlatformClone", description: "", organization: orgB)

            #expect(try await searchGroupNames(app, org: orgA, path: "displayName", op: .contains, value: "platform") == ["Platform"])
            #expect(try await searchGroupNames(app, org: orgB, path: "displayName", op: .contains, value: "platform") == ["PlatformClone"])
        }
    }
}
