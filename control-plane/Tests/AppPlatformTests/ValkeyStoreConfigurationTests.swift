import Testing
import Valkey
import Vapor

@testable import App

// These tests use the same immutable startup snapshot as production rather than
// mutating the process environment, which would race the parallel test suite.
@Suite("Valkey Store Configuration")
struct ValkeyStoreConfigurationTests {

    private func resolve(_ env: [String: String]) async throws -> ValkeyStoreConfiguration? {
        let configuration = try await ControlPlaneConfiguration.load(
            environmentVariables: env, for: .testing)
        return ValkeyStoreConfiguration.fromConfiguration(configuration)
    }

    @Test("Nothing configured resolves to nil")
    func nothingConfigured() async throws {
        #expect(try await resolve([:]) == nil)
    }

    @Test("An empty host counts as unset")
    func emptyHostIsUnset() async throws {
        #expect(try await resolve(["VALKEY_HOST": ""]) == nil)
    }

    /// The upgrade case: a deployment that only ever set VALKEY_HOST must keep
    /// one endpoint *and* one client, so its connection count is unchanged.
    @Test("VALKEY_HOST alone serves both stores from one instance")
    func legacyHostServesBothRoles() async throws {
        let config = try #require(try await resolve(["VALKEY_HOST": "valkey"]))
        #expect(config.coordination.hostname == "valkey")
        #expect(config.session == config.coordination)
        #expect(config.sharesOneInstance)
        #expect(config.warnings.isEmpty)
    }

    @Test("Coordination reads all four VALKEY_ variables")
    func coordinationReadsEveryField() async throws {
        let config = try #require(
            try await resolve([
                "VALKEY_HOST": "coord",
                "VALKEY_PORT": "7000",
                "VALKEY_PASSWORD": "pw",
                "VALKEY_DATABASE": "3",
            ]))
        #expect(config.coordination == ValkeyConfiguration(hostname: "coord", port: 7000, password: "pw", database: 3))
    }

    /// The safety-critical property. Fallback is wholesale, so naming a session
    /// host does not drag the coordination password or port along with it — one
    /// variable can never produce a half-merged endpoint.
    @Test("SESSION_VALKEY_HOST alone inherits nothing from the coordination endpoint")
    func sessionFallbackIsWholesaleNotPerField() async throws {
        let config = try #require(
            try await resolve([
                "VALKEY_HOST": "coord",
                "VALKEY_PORT": "7000",
                "VALKEY_PASSWORD": "pw",
                "VALKEY_DATABASE": "3",
                "SESSION_VALKEY_HOST": "sessions",
            ]))
        #expect(config.session.hostname == "sessions")
        #expect(config.session.port == 6379)
        #expect(config.session.password == nil)
        #expect(config.session.database == 0)
        #expect(!config.sharesOneInstance)
    }

    @Test("A session endpoint spelled out identically still shares one instance")
    func identicalSessionConfigSharesTheInstance() async throws {
        let config = try #require(
            try await resolve([
                "VALKEY_HOST": "valkey",
                "VALKEY_PORT": "7000",
                "VALKEY_PASSWORD": "pw",
                "SESSION_VALKEY_HOST": "valkey",
                "SESSION_VALKEY_PORT": "7000",
                "SESSION_VALKEY_PASSWORD": "pw",
            ]))
        #expect(config.sharesOneInstance)
    }

    /// The cheap middle ground: same server, separate keyspace. It must produce
    /// two clients, because `databaseNumber` is baked into the client config.
    @Test("A differing database alone splits the client")
    func differingDatabaseSplitsTheClient() async throws {
        let config = try #require(
            try await resolve([
                "VALKEY_HOST": "valkey",
                "SESSION_VALKEY_HOST": "valkey",
                "SESSION_VALKEY_DATABASE": "1",
            ]))
        #expect(config.session.hostname == "valkey")
        #expect(config.session.database == 1)
        #expect(!config.sharesOneInstance)
    }

    /// Guards the synthesized `Equatable` against a future hand-written `==`
    /// that drops a field — sharing a client on a password mismatch would
    /// authenticate sessions with the wrong credential.
    @Test("A differing password alone splits the client")
    func differingPasswordSplitsTheClient() async throws {
        let config = try #require(
            try await resolve([
                "VALKEY_HOST": "valkey",
                "VALKEY_PASSWORD": "coordination",
                "SESSION_VALKEY_HOST": "valkey",
                "SESSION_VALKEY_PASSWORD": "sessions",
            ]))
        #expect(!config.sharesOneInstance)
    }

    /// The mirror hazard of the all-or-nothing rule: without a host, the rest of
    /// the session group is inert. Silently ignoring it would leave an operator
    /// believing their keyspace was separated when it wasn't.
    @Test("Session variables set without a host are reported as ignored")
    func orphanedSessionVariablesWarn() async throws {
        let config = try #require(
            try await resolve([
                "VALKEY_HOST": "valkey",
                "SESSION_VALKEY_DATABASE": "2",
            ]))
        #expect(config.sharesOneInstance)
        #expect(config.warnings.count == 1)
        let warning = try #require(config.warnings.first)
        #expect(warning.contains("SESSION_VALKEY_DATABASE"))
        #expect(warning.contains("SESSION_VALKEY_HOST"))
    }

    @Test("A malformed port fails configuration rather than using a default")
    func malformedPortFailsConfiguration() async {
        await #expect(throws: ControlPlaneConfigurationError.self) {
            _ = try await resolve([
                "VALKEY_HOST": "valkey",
                "SESSION_VALKEY_HOST": "sessions",
                "SESSION_VALKEY_PORT": "not-a-number",
            ])
        }
    }

    @Test("configuration(for:) returns each role's endpoint")
    func configurationForRole() async throws {
        let config = try #require(
            try await resolve([
                "VALKEY_HOST": "coord",
                "SESSION_VALKEY_HOST": "sessions",
            ]))
        #expect(config.configuration(for: .coordination).hostname == "coord")
        #expect(config.configuration(for: .session).hostname == "sessions")
    }
}

/// `ValkeyClient.run()` traps on a second call, so when both roles share an
/// endpoint the lifecycle handler must spawn exactly one loop. Building clients
/// here is safe: `init` allocates state but connects nothing — the pool is only
/// driven by `run()`, which these tests never call.
@Suite("Valkey Client Registry")
struct ValkeyClientRegistryTests {

    private func makeClient() -> ValkeyClient {
        ValkeyClient(.hostname("127.0.0.1", port: 6379), logger: Logger(label: "test"))
    }

    private func registry(coordination: ValkeyClient, session: ValkeyClient) -> ValkeyClients {
        let endpoint = ValkeyConfiguration(hostname: "valkey")
        ValkeyClients(
            coordination: coordination,
            session: session,
            configuration: ValkeyStoreConfiguration(
                coordination: endpoint, session: endpoint, warnings: [])
        )
    }

    @Test("One shared client yields one run loop")
    func sharedClientIsListedOnce() {
        let client = makeClient()
        let distinct = registry(coordination: client, session: client).distinctClients
        #expect(distinct.count == 1)
        #expect(distinct.first?.role == .coordination)
    }

    @Test("Separate clients are both listed, in role order")
    func separateClientsAreBothListed() {
        let distinct = registry(coordination: makeClient(), session: makeClient()).distinctClients
        #expect(distinct.count == 2)
        #expect(distinct.map(\.role) == [.coordination, .session])
    }

    @Test("client(for:) returns the client registered for each role")
    func clientForRole() {
        let coordination = makeClient()
        let session = makeClient()
        let clients = registry(coordination: coordination, session: session)
        #expect(clients.client(for: .coordination) === coordination)
        #expect(clients.client(for: .session) === session)
    }
}
