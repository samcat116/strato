import Fluent
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

/// Free function so the concurrency test can fire requests from a task group
/// without capturing the (non-Sendable) test case.
private func registerConcurrently(_ app: Application, username: String) async throws -> HTTPStatus {
    var status = HTTPStatus.internalServerError
    try await app.test(.POST, "/api/users/register") { req in
        try req.content.encode(
            CreateUserRequest(
                username: username, email: "\(username)@example.com", displayName: username))
    } afterResponse: { res in
        status = res.status
    }
    return status
}

@Suite("Self-registration policy", .serialized)
final class RegistrationPolicyTests: BaseTestCase {

    private func register(
        _ app: Application,
        username: String,
        expect status: HTTPStatus
    ) async throws {
        try await app.test(.POST, "/api/users/register") { req in
            try req.content.encode(
                CreateUserRequest(
                    username: username, email: "\(username)@example.com", displayName: username))
        } afterResponse: { res in
            #expect(res.status == status)
        }
    }

    // MARK: - Setting parsing

    @Test(
        "the setting uses Swift Configuration's Boolean grammar",
        arguments: [
            ("true", true), ("TRUE", true), ("yes", true), ("1", true),
            ("false", false), ("FALSE", false), ("no", false), ("0", false),
        ])
    func testBooleanGrammar(raw: String, expected: Bool) async throws {
        let configuration = try await ControlPlaneConfiguration.load(
            environmentVariables: [RegistrationPolicy.environmentKey: raw], for: .testing)
        #expect(
            RegistrationPolicy.fromConfiguration(configuration).selfRegistrationEnabled == expected)
    }

    @Test(
        "unsupported Boolean spellings fail configuration",
        arguments: ["", "off", "on", " true ", "banana"])
    func testUnsupportedBooleanSpelling(raw: String) async {
        await #expect(throws: ControlPlaneConfigurationError.self) {
            _ = try await ControlPlaneConfiguration.load(
                environmentVariables: [RegistrationPolicy.environmentKey: raw], for: .testing)
        }
    }

    @Test("the setting defaults open when absent")
    func testDefault() async throws {
        let configuration = try await ControlPlaneConfiguration.load(
            environmentVariables: [:], for: .testing)
        #expect(RegistrationPolicy.fromConfiguration(configuration).selfRegistrationEnabled)
    }

    // MARK: - The public endpoint

    @Test("the policy endpoint is public")
    func testEndpointIsPublic() {
        #expect(AuthorizationMiddleware.classify(path: "/api/public/registration") == .isPublic)
    }

    @Test("an empty deployment reports bootstrap, whatever the setting")
    func testBootstrapReported() async throws {
        try await withApp { app in
            app.registrationPolicy = RegistrationPolicy(selfRegistrationEnabled: false)

            try await app.test(.GET, "/api/public/registration") { res in
                #expect(res.status == .ok)
                let body = try res.content.decode(RegistrationPolicyResponse.self)
                #expect(body.bootstrapRequired == true)
                #expect(body.selfRegistrationEnabled == true)
            }
        }
    }

    @Test("once a user exists the disabled setting takes effect")
    func testDisabledOnceUsersExist() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            app.registrationPolicy = RegistrationPolicy(selfRegistrationEnabled: false)

            try await app.test(.GET, "/api/public/registration") { res in
                #expect(res.status == .ok)
                let body = try res.content.decode(RegistrationPolicyResponse.self)
                #expect(body.bootstrapRequired == false)
                #expect(body.selfRegistrationEnabled == false)
            }
        }
    }

    @Test("the default deployment reports registration open")
    func testEnabledByDefault() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            app.registrationPolicy = RegistrationPolicy(selfRegistrationEnabled: true)

            try await app.test(.GET, "/api/public/registration") { res in
                #expect(res.status == .ok)
                let body = try res.content.decode(RegistrationPolicyResponse.self)
                #expect(body.bootstrapRequired == false)
                #expect(body.selfRegistrationEnabled == true)
            }
        }
    }

    // MARK: - Enforcement

    /// Hiding the login page's link is cosmetic; the endpoint is what an
    /// attacker would call.
    @Test("register is refused when self-registration is disabled")
    func testRegisterForbiddenWhenDisabled() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            app.registrationPolicy = RegistrationPolicy(selfRegistrationEnabled: false)

            try await register(app, username: "neo", expect: .forbidden)

            let created = try await User.query(on: app.db).filter(\.$username == "neo").first()
            #expect(created == nil)
        }
    }

    /// A closed install still has to be installable: with no users there is no
    /// admin who could invite anyone, so the first account is always allowed.
    @Test("the first account may be created even when disabled")
    func testBootstrapAccountAllowedWhenDisabled() async throws {
        try await withApp { app in
            app.registrationPolicy = RegistrationPolicy(selfRegistrationEnabled: false)

            try await register(app, username: "first", expect: .ok)

            let created = try await User.query(on: app.db).filter(\.$username == "first").first()
            #expect(created?.isSystemAdmin == true)

            // ...and the door closes again behind it.
            try await register(app, username: "second", expect: .forbidden)
            let second = try await User.query(on: app.db).filter(\.$username == "second").first()
            #expect(second == nil)
        }
    }

    @Test("register still works when self-registration is enabled")
    func testRegisterAllowedWhenEnabled() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            app.registrationPolicy = RegistrationPolicy(selfRegistrationEnabled: true)

            try await register(app, username: "neo", expect: .ok)

            let created = try await User.query(on: app.db).filter(\.$username == "neo").first()
            #expect(created != nil)
            // Not the first account, so no free system-admin bit.
            #expect(created?.isSystemAdmin == false)
        }
    }

    /// The bootstrap exemption is a predicate over rows that do not exist yet,
    /// so it cannot be held by a row lock: without serializing the check with
    /// the insert, concurrent requests each read an empty table, each pass a
    /// *disabled* gate, and each land as a system admin.
    @Test("concurrent bootstrap registrations produce exactly one account")
    func testConcurrentBootstrapRegistrationsSerialize() async throws {
        try await withApp { app in
            app.registrationPolicy = RegistrationPolicy(selfRegistrationEnabled: false)

            let attempts = 8
            let statuses = try await withThrowingTaskGroup(of: HTTPStatus.self) { group in
                for index in 0..<attempts {
                    group.addTask { try await registerConcurrently(app, username: "racer\(index)") }
                }
                var collected: [HTTPStatus] = []
                for try await status in group { collected.append(status) }
                return collected
            }

            #expect(statuses.filter { $0 == .ok }.count == 1)
            #expect(statuses.filter { $0 == .forbidden }.count == attempts - 1)

            let users = try await User.query(on: app.db).all()
            #expect(users.count == 1)
            #expect(users.first?.isSystemAdmin == true)
        }
    }

    /// A disabled install must not double as a username oracle: the refusal has
    /// to come before the conflict check, so taken and free names look alike.
    @Test("refusal does not reveal whether a username is taken")
    func testDisabledDoesNotLeakExistingUsernames() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            app.registrationPolicy = RegistrationPolicy(selfRegistrationEnabled: false)

            try await register(app, username: "testuser", expect: .forbidden)
            try await register(app, username: "nobody", expect: .forbidden)
        }
    }
}
