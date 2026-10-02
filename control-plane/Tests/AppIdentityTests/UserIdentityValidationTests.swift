import AppTestSupport
import Fluent
import Testing
import Vapor
import VaporTesting

@testable import App

@Suite("Account identity boundaries", .serialized)
final class UserIdentityValidationTests: BaseTestCase {
    @Test("Both creation routes reject malformed and oversized identities", arguments: [false, true])
    func invalidCreation(admin: Bool) async throws {
        try await withTestApp { app in
            let token: String?
            if admin {
                let user = User(
                    username: "admin", email: "admin@example.com", displayName: "Admin", isSystemAdmin: true)
                try await user.save(on: app.db)
                token = try await user.generateAPIKey(on: app.db)
            } else {
                token = nil
            }
            let invalid: [(String, String, String)] = [
                ("", "alice@example.com", "Alice"),
                (" \n ", "alice@example.com", "Alice"),
                ("al", "alice@example.com", "Alice"),
                (String(repeating: "a", count: 65), "alice@example.com", "Alice"),
                (String(repeating: "a", count: 3000), "alice@example.com", "Alice"),
                ("alice/evil", "alice@example.com", "Alice"),
                ("alice", "invalid", "Alice"),
                ("alice", "ali\tce@example.com", "Alice"),
                ("alice", String(repeating: "e", count: 243) + "@example.com", "Alice"),
                ("alice", "alice@example.com", " "),
                ("alice", "alice@example.com", String(repeating: "a", count: 129)),
                ("alice", "alice@example.com", String(repeating: "e\u{301}", count: 65)),
            ]
            for (username, email, displayName) in invalid {
                try await app.test(.POST, admin ? "/api/users" : "/api/users/register") { req in
                    if let token { req.headers.bearerAuthorization = BearerAuthorization(token: token) }
                    try req.content.encode(
                        AdminCreateUserRequest(
                            username: username, email: email, displayName: displayName, isSystemAdmin: false))
                } afterResponse: { res in
                    #expect(res.status == .badRequest)
                }
            }
            #expect(try await User.query(on: app.db).count() == (admin ? 1 : 0))
        }
    }

    @Test("Both creation routes accept exact limits and persist normalized identities", arguments: [false, true])
    func limitsAndNormalization(admin: Bool) async throws {
        try await withTestApp { app in
            app.registrationPolicy = RegistrationPolicy(selfRegistrationEnabled: true)
            var token: String?
            if admin {
                let user = User(
                    username: "admin", email: "admin@example.com", displayName: "Admin", isSystemAdmin: true)
                try await user.save(on: app.db)
                token = try await user.generateAPIKey(on: app.db)
            }
            let username = String(repeating: "a", count: 64)
            let email = String(repeating: "e", count: 242) + "@example.com"
            let displayName = String(repeating: "e\u{301}", count: 64)
            let body = AdminCreateUserRequest(
                username: " \(username) ", email: " \(email) ",
                displayName: " \(displayName) ", isSystemAdmin: false)
            for expected in [HTTPStatus.ok, .conflict] {
                try await app.test(.POST, admin ? "/api/users" : "/api/users/register") { req in
                    if let token { req.headers.bearerAuthorization = BearerAuthorization(token: token) }
                    try req.content.encode(body)
                } afterResponse: { res in
                    #expect(res.status == expected)
                }
            }
            let user = try #require(try await User.query(on: app.db).filter(\.$username == username).first())
            #expect(user.email == email)
            #expect(user.displayName == displayName)
        }
    }

    @Test("Model writes cannot bypass the shared grammar")
    func modelBackstop() async throws {
        try await withTestApp { app in
            let invalid = User(username: "bad/name", email: "valid@example.com", displayName: "Valid")
            await #expect(throws: Abort.self) { try await invalid.save(on: app.db) }
            let valid = User(username: " valid ", email: " valid@example.com ", displayName: " Valid ")
            try await valid.save(on: app.db)
            #expect(valid.username == "valid")
            valid.displayName = String(repeating: "e\u{301}", count: 65)
            await #expect(throws: Abort.self) { try await valid.save(on: app.db) }
        }
    }
}
