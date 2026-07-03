import Testing
import Vapor
import Fluent
import VaporTesting
@testable import App

@Suite("User API Authorization Tests", .serialized)
final class UserControllerTests: BaseTestCase {

    /// Create an additional user (distinct from `testUser`) plus a bearer token for it.
    private func makeUser(
        on db: Database,
        username: String,
        email: String,
        isSystemAdmin: Bool = false
    ) async throws -> (user: User, token: String) {
        let user = User(
            username: username,
            email: email,
            displayName: username,
            isSystemAdmin: isSystemAdmin
        )
        try await user.save(on: db)
        let token = try await user.generateAPIKey(on: db)
        return (user, token)
    }

    // MARK: - index

    @Test("index is forbidden for non-admins")
    func testIndexForbiddenForNonAdmin() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)

            try await app.test(.GET, "/api/users") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test("index succeeds for system admins")
    func testIndexAllowedForAdmin() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            let admin = try await makeUser(
                on: app.db, username: "admin", email: "admin@example.com", isSystemAdmin: true
            )

            try await app.test(.GET, "/api/users") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: admin.token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let users = try res.content.decode([User.Public].self)
                #expect(users.count >= 2)
            }
        }
    }

    // MARK: - show

    @Test("show is allowed for self")
    func testShowSelf() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)

            try await app.test(.GET, "/api/users/\(testUser.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let user = try res.content.decode(User.Public.self)
                #expect(user.id == testUser.id)
            }
        }
    }

    @Test("show another user is forbidden for non-admins")
    func testShowOtherForbidden() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            let other = try await makeUser(
                on: app.db, username: "other", email: "other@example.com"
            )

            try await app.test(.GET, "/api/users/\(other.user.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test("show another user is allowed for system admins")
    func testShowOtherAllowedForAdmin() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            let admin = try await makeUser(
                on: app.db, username: "admin", email: "admin@example.com", isSystemAdmin: true
            )

            try await app.test(.GET, "/api/users/\(testUser.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: admin.token)
            } afterResponse: { res in
                #expect(res.status == .ok)
            }
        }
    }

    // MARK: - update

    @Test("update self is allowed")
    func testUpdateSelf() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)

            try await app.test(.PUT, "/api/users/\(testUser.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(UpdateUserRequest(displayName: "New Name", email: nil))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let user = try res.content.decode(User.Public.self)
                #expect(user.displayName == "New Name")
            }
        }
    }

    @Test("update another user is forbidden for non-admins")
    func testUpdateOtherForbidden() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            let other = try await makeUser(
                on: app.db, username: "other", email: "other@example.com"
            )

            try await app.test(.PUT, "/api/users/\(other.user.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(UpdateUserRequest(displayName: "Hijacked", email: nil))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }

            // Confirm the target was not modified
            let reloaded = try await User.find(other.user.id, on: app.db)
            #expect(reloaded?.displayName == "other")
        }
    }

    // MARK: - delete

    @Test("delete another user is forbidden for non-admins")
    func testDeleteOtherForbidden() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            let other = try await makeUser(
                on: app.db, username: "other", email: "other@example.com"
            )

            try await app.test(.DELETE, "/api/users/\(other.user.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }

            // Confirm the target still exists
            let reloaded = try await User.find(other.user.id, on: app.db)
            #expect(reloaded != nil)
        }
    }

    @Test("delete another user is allowed for system admins")
    func testDeleteOtherAllowedForAdmin() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            let admin = try await makeUser(
                on: app.db, username: "admin", email: "admin@example.com", isSystemAdmin: true
            )
            let other = try await makeUser(
                on: app.db, username: "other", email: "other@example.com"
            )

            try await app.test(.DELETE, "/api/users/\(other.user.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: admin.token)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            let reloaded = try await User.find(other.user.id, on: app.db)
            #expect(reloaded == nil)
        }
    }
}
