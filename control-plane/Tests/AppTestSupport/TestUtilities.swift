import Fluent
import FluentPostgresDriver
import NIOCore
import NIOPosix
import PostgresNIO
import SQLKit
import StratoShared
import Vapor
import VaporTesting

@testable import App

// MARK: - Test Database Templates
//
// The suite runs against Postgres — the engine production uses — so migrations
// and Postgres-specific SQL are validated everywhere, not just in CI (issue
// #195; the former SQLite backend was removed because nothing used it and its
// CI leg doubled suite runtime). Connection parameters come from the standard
// `DATABASE_*` env vars, defaulting to localhost:5432, strato/strato_password,
// anchor database strato_test — matching `docker run -e POSTGRES_DB=strato_test
// -e POSTGRES_USER=strato -e POSTGRES_PASSWORD=strato_password ...`.
//
// Migrations run once per test process into a template database. Every test
// receives a cheap server-side clone via `CREATE DATABASE ... TEMPLATE ...`.

private let testProcessID = ProcessInfo.processInfo.processIdentifier

/// Whether the test process that embedded `pid` in a leftover database's name
/// is still alive on this machine (a parallel run in another worktree we must
/// not disturb). Anything else is debris from a finished or crashed run.
private func isTestProcessAlive(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
}

/// Builds the per-process Postgres template database and hands out per-test
/// clones of it, serializing all CREATE/DROP DATABASE statements through a
/// single admin connection: `CREATE DATABASE ... TEMPLATE` requires that the
/// template has no other users, so clones must be minted one at a time.
package actor PostgresTestDatabases {
    package static let shared = PostgresTestDatabases()

    /// Small event-loop group shared by every test app in the suite.
    /// The pool opens at most two connections per event loop by default, so
    /// this caps each app at four connections (unless a test passes a larger
    /// `maxConnectionsPerEventLoop` to `makeForTesting`) and keeps the fully
    /// parallel suite well under the server's default max_connections=100 —
    /// the constraint that used to force CI's Postgres run to be --no-parallel.
    package static let appEventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)

    /// Connection parameters from the environment. `DATABASE_NAME` is only the
    /// anchor database the admin connection logs into — tests themselves run
    /// in throwaway clones of the template.
    package static func configuration(database: String) -> SQLPostgresConfiguration {
        SQLPostgresConfiguration(
            hostname: Environment.get("DATABASE_HOST") ?? "localhost",
            port: Environment.get("DATABASE_PORT").flatMap(Int.init(_:))
                ?? SQLPostgresConfiguration.ianaPortNumber,
            username: Environment.get("DATABASE_USERNAME") ?? "strato",
            password: Environment.get("DATABASE_PASSWORD") ?? "strato_password",
            database: database,
            tls: .disable
        )
    }

    private static let logger: Logger = {
        var logger = Logger(label: "strato.test.pg-admin")
        logger.logLevel = .error
        return logger
    }()

    private let templateName = "strato_test_tpl_\(testProcessID)"
    private var connection: PostgresConnection?
    private var template: Task<Void, Error>?
    /// FIFO chain serializing admin statements; actor methods interleave at
    /// suspension points, so ordering needs an explicit chain, not just `self`.
    private var lastAdminOperation: Task<Void, Never>?

    /// Mint a fresh clone of the migrated template for one test.
    package func createDatabaseForTest() async throws -> String {
        if template == nil {
            template = Task { try await self.buildTemplate() }
        }
        try await template!.value

        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let name = "strato_test_db_\(testProcessID)_\(suffix)"
        try await run(#"CREATE DATABASE "\#(name)" TEMPLATE "\#(templateName)""#)
        return name
    }

    /// Mint an EMPTY database (no migrations applied) for tests that need to
    /// build legacy schemas by hand before running a single migration — the
    /// migrated template has every migration pre-applied, which makes
    /// before/after tests impossible. Shares the clone namespace so teardown
    /// (`dropDatabase`) and the dead-run sweep cover these too.
    package func createBareDatabaseForTest() async throws -> String {
        // Await the template build even though its result is unused: every
        // other admin statement is serialized behind it, and buildTemplate()'s
        // internal queries (`allDatabaseNames`) run outside the FIFO chain.
        // Racing it here would mint a second admin connection and drop the
        // first unclosed — PostgresNIO asserts on that.
        if template == nil {
            template = Task { try await self.buildTemplate() }
        }
        try await template!.value

        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let name = "strato_test_db_\(testProcessID)_\(suffix)"
        try await run(#"CREATE DATABASE "\#(name)""#)
        return name
    }

    /// Destroy one test's clone. Best effort — leftovers are swept by the
    /// next run's buildTemplate().
    package func dropDatabase(_ name: String) async {
        try? await run(#"DROP DATABASE IF EXISTS "\#(name)" WITH (FORCE)"#)
    }

    private func buildTemplate() async throws {
        // On a disposable CI Postgres, trade durability for speed. Each test mints a
        // clone via CREATE DATABASE ... TEMPLATE, which is checkpoint/fsync-bound;
        // these settings remove the syncs. Safe because a crashed CI Postgres is just
        // a rerun. (All three are SIGHUP-reloadable; strato is a superuser.)
        //
        // ALTER SYSTEM is cluster-wide and persists in postgresql.auto.conf, so it is
        // gated behind an explicit opt-in that only the ephemeral CI service sets — a
        // developer pointing DATABASE_* at a local/shared cluster must never silently
        // disable durability for unrelated databases.
        if Environment.get("STRATO_TEST_DISPOSABLE_POSTGRES") == "1" {
            try await run("ALTER SYSTEM SET fsync = off")
            try await run("ALTER SYSTEM SET synchronous_commit = off")
            try await run("ALTER SYSTEM SET full_page_writes = off")
            try await run("SELECT pg_reload_conf()")
        }

        // Sweep templates and clones left by dead runs (crashed teardowns,
        // killed processes); skip names whose embedded pid is still alive —
        // that's a parallel run in another worktree sharing this server.
        for name in try await allDatabaseNames() {
            let pidText: Substring
            if name.hasPrefix("strato_test_tpl_") {
                pidText = name.dropFirst("strato_test_tpl_".count)
            } else if name.hasPrefix("strato_test_db_") {
                pidText = name.dropFirst("strato_test_db_".count).prefix(while: { $0 != "_" })
            } else {
                continue
            }
            if let pid = Int32(pidText), pid != testProcessID, isTestProcessAlive(pid) { continue }
            try await run(#"DROP DATABASE IF EXISTS "\#(name)" WITH (FORCE)"#)
        }

        try await run(#"CREATE DATABASE "\#(templateName)""#)

        // Boot a throwaway app against the template so `configure()` applies the
        // schema. Shut it down before cloning so the template has no live sessions.
        var env = Environment.testing
        env.arguments = ["vapor"]
        let app = try await Application.make(env, .shared(Self.appEventLoopGroup))
        app.logger.logLevel = .error
        app.databases.use(
            .postgres(
                configuration: Self.configuration(database: templateName),
                maxConnectionsPerEventLoop: 2),
            as: .psql)
        do {
            try await configure(app)
            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }

    private func allDatabaseNames() async throws -> [String] {
        let connection = try await adminConnection()
        let rows = try await connection.query(
            PostgresQuery(unsafeSQL: "SELECT datname FROM pg_database WHERE NOT datistemplate"),
            logger: Self.logger
        )
        var names: [String] = []
        for try await row in rows {
            names.append(try row.decode(String.self))
        }
        return names
    }

    /// Run one admin statement strictly after every previously enqueued one.
    private func run(_ sql: String) async throws {
        let previous = lastAdminOperation
        let operation = Task {
            await previous?.value
            let connection = try await self.adminConnection()
            let rows = try await connection.query(PostgresQuery(unsafeSQL: sql), logger: Self.logger)
            for try await _ in rows {}  // drain to completion
        }
        lastAdminOperation = Task { try? await operation.value }
        do {
            try await operation.value
        } catch {
            // The connection may have died; discard it so the next statement
            // reconnects. (Plain SQL failures pay a harmless reconnect.)
            if let connection {
                self.connection = nil
                try? await connection.close()
            }
            throw error
        }
    }

    private func adminConnection() async throws -> PostgresConnection {
        if let connection, !connection.isClosed { return connection }
        let configuration = PostgresConnection.Configuration(
            host: Environment.get("DATABASE_HOST") ?? "localhost",
            port: Environment.get("DATABASE_PORT").flatMap(Int.init(_:))
                ?? SQLPostgresConfiguration.ianaPortNumber,
            username: Environment.get("DATABASE_USERNAME") ?? "strato",
            password: Environment.get("DATABASE_PASSWORD") ?? "strato_password",
            database: Environment.get("DATABASE_NAME") ?? "strato_test",
            tls: .disable
        )
        let connection = try await PostgresConnection.connect(
            on: Self.appEventLoopGroup.next(),
            configuration: configuration,
            id: 0,
            logger: Self.logger
        )
        self.connection = connection
        return connection
    }
}

// MARK: - Test Extensions

extension Application {
    /// `maxConnectionsPerEventLoop` stays small by default to keep the fully
    /// parallel suite under Postgres's max_connections. A test that holds a
    /// transaction open while other tasks need connections of their own must
    /// raise it: the transactions can all land on the same event loop of the
    /// shared two-loop group, and each extra one then waits forever for a pool
    /// slot the parked transaction is holding.
    package static func makeForTesting(
        _ environment: Environment = .testing,
        maxConnectionsPerEventLoop: Int = 2
    ) async throws -> Application {
        var env = environment
        env.arguments = ["vapor"]

        // Each test gets its own server-side clone of the migrated template
        // database.
        let databaseName = try await PostgresTestDatabases.shared.createDatabaseForTest()
        return try await make(
            env, database: databaseName, maxConnectionsPerEventLoop: maxConnectionsPerEventLoop)
    }

    /// Like `makeForTesting`, but on an EMPTY database with no migrations
    /// applied — for migration before/after tests that hand-build legacy
    /// schemas. Tear down with `shutdownForTesting()` as usual.
    package static func makeForBareDatabaseTesting(_ environment: Environment = .testing) async throws
        -> Application
    {
        var env = environment
        env.arguments = ["vapor"]

        let databaseName = try await PostgresTestDatabases.shared.createBareDatabaseForTest()
        return try await make(env, database: databaseName)
    }

    /// Boot an application against a database the caller already minted, so more
    /// than one application can share one schema — what a concurrent-boot test
    /// needs and what every other fixture deliberately prevents.
    ///
    /// Exactly one application should be the `owningDatabase` one: only that
    /// one's `shutdownForTesting()` drops the clone, and it must be the last to
    /// go (the drop is `WITH (FORCE)`, so it would kill a sibling's connections).
    /// Shut the others down with plain `asyncShutdown()` first.
    package static func makeForTesting(
        database databaseName: String,
        owningDatabase: Bool,
        _ environment: Environment = .testing
    ) async throws -> Application {
        var env = environment
        env.arguments = ["vapor"]
        return try await make(env, database: databaseName, owningDatabase: owningDatabase)
    }

    private static func make(
        _ env: Environment,
        database databaseName: String,
        owningDatabase: Bool = true,
        maxConnectionsPerEventLoop: Int = 2
    ) async throws -> Application {
        let app = try await Application.make(env, .shared(PostgresTestDatabases.appEventLoopGroup))
        app.logger.logLevel = .debug
        app.databases.use(
            .postgres(
                configuration: PostgresTestDatabases.configuration(database: databaseName),
                maxConnectionsPerEventLoop: maxConnectionsPerEventLoop),
            as: .psql
        )
        if owningDatabase {
            app.storage[TestDatabaseNameKey.self] = databaseName
        }
        return app
    }
}

// Storage key for the per-test Postgres database clone's name
package struct TestDatabaseNameKey: StorageKey {
    package typealias Value = String
}

extension Application {
    /// Tear down an app made by `makeForTesting`: shut Vapor down (closing its
    /// database pool), then destroy the test's database clone.
    package func shutdownForTesting() async throws {
        let databaseName = storage[TestDatabaseNameKey.self]

        try await asyncShutdown()

        if let databaseName {
            await PostgresTestDatabases.shared.dropDatabase(databaseName)
        }
    }
}

/// A symbolic analyzer that proves nothing and objects to nothing.
///
/// Installed by `withTestApp` so the suites that merely *write bindings* do
/// not each need an SMT solver on the machine. Tests that are about the
/// write-time ceiling check replace it with the real `SymCCGuardrailAnalyzer`;
/// production never sees it, since the only construction site is here.
package struct PermissiveGuardrailAnalyzer: GuardrailAnalyzer {
    package init() {}

    package func disjoint(
        schemaText: String,
        _ a: [CedarPolicySource],
        _ b: [CedarPolicySource],
        in environment: CedarRequestEnvironment
    ) async throws -> GuardrailAnalysis {
        GuardrailAnalysis(holds: true, counterexample: nil)
    }

    package func implies(
        schemaText: String,
        _ a: [CedarPolicySource],
        _ b: [CedarPolicySource],
        in environment: CedarRequestEnvironment
    ) async throws -> GuardrailAnalysis {
        GuardrailAnalysis(holds: true, counterexample: nil)
    }
}

package func withTestApp(_ test: (Application) async throws -> Void) async throws {
    let app = try await Application.makeForTesting()

    do {
        try await configure(app)
        app.guardrailAnalyzer = PermissiveGuardrailAnalyzer()
        try await test(app)
    } catch {
        try? await app.shutdownForTesting()
        throw error
    }

    try await app.shutdownForTesting()
}

extension User {
    package func generateAPIKey(
        on db: Database,
        name: String = "Test API Key",
        restriction: CredentialRestriction = .unrestricted
    ) async throws -> String {
        // Generate a proper API key for testing
        let apiKeyString = APIKey.generateAPIKey()
        let keyHash = APIKey.hashAPIKey(apiKeyString)
        let keyPrefix = String(apiKeyString.prefix(16))

        let apiKey = APIKey(
            userID: self.id!,
            name: name,
            keyHash: keyHash,
            keyPrefix: keyPrefix,
            restriction: restriction,
            isActive: true
        )
        try await apiKey.save(on: db)

        return apiKeyString
    }
}

// MARK: - Test Data Builders

package struct TestDataBuilder {
    package let db: Database

    package init(db: Database) { self.db = db }

    @discardableResult
    package func registerAgent(
        on app: Application,
        named name: String,
        hostname: String? = nil,
        version: String = "1.0.0",
        resources: AgentResources = AgentResources(
            totalCPU: 16,
            availableCPU: 16,
            totalMemory: 1 << 34,
            availableMemory: 1 << 34,
            totalDisk: 1 << 40,
            availableDisk: 1 << 40),
        architecture: CPUArchitecture? = nil,
        hypervisors: [HypervisorSupport]? = [
            HypervisorSupport(type: .qemu, available: true, accelerated: true)
        ],
        networkCapability: NetworkCapability? = .overlay,
        protocolVersion: Int = WireProtocol.currentVersion,
        sandboxCapable: Bool? = nil,
        sandboxNetworkingCapable: Bool? = nil,
        tpmCapable: Bool? = nil,
        operatingSystem: OperatingSystem? = nil,
        hostInfo: HostInfo? = nil,
        resolverCapable: Bool? = nil,
        metadataServiceCapable: Bool? = nil,
        dependencyObservations: [NodeDependencyObservation]? = nil,
        trustDomain: String = "strato.local",
        siteID requestedSiteID: UUID? = nil,
        organizationScope requestedScope: OrganizationScope? = nil
    ) async throws -> String {
        let (scope, siteID) = try await agentPlacement(
            siteID: requestedSiteID, organizationScope: requestedScope)

        let effectiveDependencyObservations =
            dependencyObservations
            ?? Self.healthyDependencyObservations(
                hypervisors: hypervisors,
                networkCapability: networkCapability,
                sandboxNetworkingCapable: sandboxNetworkingCapable,
                resolverCapable: resolverCapable)
        let message = AgentRegisterMessage(
            agentId: name,
            hostname: hostname ?? "host-\(name)",
            version: version,
            resources: resources,
            architecture: architecture ?? .x86_64,
            hypervisors: hypervisors ?? [],
            networkCapability: networkCapability,
            protocolVersion: protocolVersion,
            sandboxCapable: sandboxCapable ?? false,
            sandboxNetworkingCapable: sandboxNetworkingCapable ?? false,
            tpmCapable: tpmCapable ?? false,
            operatingSystem: operatingSystem ?? .current,
            hostInfo: hostInfo,
            resolverCapable: resolverCapable ?? false,
            metadataServiceCapable: metadataServiceCapable ?? false,
            dependencyObservations: effectiveDependencyObservations)
        let id = try await app.agentService.registerAgent(
            message,
            identity: AgentIdentity(trustDomain: trustDomain, name: name),
            siteID: siteID,
            organizationScope: scope)
        return id.uuidString
    }

    /// The registration fixture defaults to a usable QEMU/OVN node, so its
    /// dependency snapshot must substantiate the capabilities it advertises.
    /// Passing an explicit empty array still models a legacy or unhealthy
    /// registration whose dependency health is unknown.
    private static func healthyDependencyObservations(
        hypervisors: [HypervisorSupport]?,
        networkCapability: NetworkCapability?,
        sandboxNetworkingCapable: Bool?,
        resolverCapable: Bool?
    ) -> [NodeDependencyObservation] {
        let checkedAt = Date()
        var observations: [NodeDependencyObservation] = []

        if hypervisors?.contains(where: { $0.type == .qemu && $0.available }) == true {
            observations.append(
                NodeDependencyObservation(
                    id: .libvirt,
                    role: .compute,
                    desiredState: .required,
                    ownership: .observeOnly,
                    supervisorState: .active,
                    compatibility: .compatible,
                    functionalState: .healthy,
                    checkedAt: checkedAt,
                    lastHealthyAt: checkedAt,
                    affectedCapabilities: [.qemuPlacement]))
        }

        if networkCapability == .overlay
            || sandboxNetworkingCapable == true
            || resolverCapable == true
        {
            observations.append(
                NodeDependencyObservation(
                    id: .ovnOvs,
                    role: .networking,
                    desiredState: .required,
                    ownership: .observeOnly,
                    supervisorState: .active,
                    compatibility: .compatible,
                    functionalState: .healthy,
                    checkedAt: checkedAt,
                    lastHealthyAt: checkedAt,
                    affectedCapabilities: [
                        .overlayNetworking, .sandboxNetworking, .networkResolver,
                    ]))
        }

        return observations
    }

    package func createAgent(
        named name: String,
        trustDomain: String = "strato.local",
        hostname: String? = nil,
        version: String = "1.0.0",
        status: AgentStatus = .online,
        resources: AgentResources = AgentResources(
            totalCPU: 16,
            availableCPU: 16,
            totalMemory: 1 << 34,
            availableMemory: 1 << 34,
            totalDisk: 1 << 40,
            availableDisk: 1 << 40),
        architecture: CPUArchitecture? = nil,
        hypervisors: [HypervisorSupport] = [],
        networkCapability: NetworkCapability? = nil,
        sandboxCapable: Bool = false,
        sandboxNetworkingCapable: Bool = false,
        tpmCapable: Bool = false,
        resolverCapable: Bool = false,
        metadataServiceCapable: Bool = false,
        dependencyObservations: [NodeDependencyObservation] = [],
        dependencyObservationsReceivedAt: Date? = nil,
        lastHeartbeat: Date? = nil,
        siteID requestedSiteID: UUID? = nil,
        organizationScope requestedScope: OrganizationScope? = nil
    ) async throws -> Agent {
        let (scope, siteID) = try await agentPlacement(
            siteID: requestedSiteID, organizationScope: requestedScope)
        let agent = Agent(
            name: name,
            trustDomain: trustDomain,
            hostname: hostname ?? "host-\(name)",
            version: version,
            siteID: siteID,
            status: status,
            resources: resources,
            architecture: architecture,
            hypervisors: hypervisors,
            networkCapability: networkCapability,
            sandboxCapable: sandboxCapable,
            sandboxNetworkingCapable: sandboxNetworkingCapable,
            tpmCapable: tpmCapable,
            resolverCapable: resolverCapable,
            metadataServiceCapable: metadataServiceCapable,
            dependencyObservations: dependencyObservations,
            dependencyObservationsReceivedAt: dependencyObservationsReceivedAt,
            lastHeartbeat: lastHeartbeat)
        agent.organizationScope = scope
        try await agent.save(on: db)
        return agent
    }

    private func agentPlacement(
        siteID requestedSiteID: UUID?, organizationScope requestedScope: OrganizationScope?
    ) async throws -> (OrganizationScope, UUID) {
        let scope: OrganizationScope
        if let requestedScope {
            scope = requestedScope
        } else if let organizationID = try await Organization.query(on: db)
            .sort(\.$createdAt)
            .first()?.id
        {
            scope = .organization(organizationID)
        } else {
            throw TestSetupError.message("Agent fixture requires an organization")
        }

        if let requestedSiteID { return (scope, requestedSiteID) }

        guard let organizationID = try await scope.rootOrganizationID(on: db) else {
            throw TestSetupError.message("Agent fixture scope has no root organization")
        }
        if let existing = try await Site.query(on: db)
            .filter(\.$organization.$id == organizationID)
            .sort(\.$createdAt)
            .first()
        {
            return (scope, try existing.requireID())
        }
        let site = Site(
            name: "Test Site \(organizationID.uuidString)",
            organizationScope: .organization(organizationID))
        try await site.save(on: db)
        return (scope, try site.requireID())
    }

    package func createUser(
        username: String = "testuser",
        email: String = "test@example.com",
        displayName: String = "Test User",
        isSystemAdmin: Bool = false
    ) async throws -> User {
        let user = User(
            username: username,
            email: email,
            displayName: displayName,
            isSystemAdmin: isSystemAdmin
        )
        try await user.save(on: db)
        return user
    }

    package func createOrganization(
        name: String = "Test Organization",
        description: String = "Test organization"
    ) async throws -> Organization {
        let org = Organization(
            name: name,
            description: description
        )
        try await org.save(on: db)
        return org
    }

    package func addUserToOrganization(
        user: User,
        organization: Organization,
        role: String = "member"
    ) async throws {
        let roleID: UUID?
        switch role {
        case "member": roleID = nil
        case "viewer": roleID = IAMRole.viewer.seededID
        case "operator": roleID = IAMRole.operator.seededID
        case "editor": roleID = IAMRole.editor.seededID
        case "admin": roleID = IAMRole.admin.seededID
        default:
            guard let customRoleID = UUID(uuidString: role) else {
                throw TestSetupError.message("Unknown organization role fixture '\(role)'")
            }
            roleID = customRoleID
        }
        let userOrg = UserOrganization(
            userID: user.id!,
            organizationID: organization.id!,
            roleID: roleID
        )
        try await userOrg.save(on: db)

        // Organization membership remains relational, while any role grant is
        // represented only by its authoritative binding.
        if let roleID {
            try await RoleBindingService.grant(
                principalType: .user,
                principalID: user.id!,
                roleID: roleID,
                nodeType: .organization,
                nodeID: organization.id!,
                createdBy: nil,
                on: db
            )
        }
    }

    package func createOU(
        name: String,
        description: String,
        organization: Organization,
        parentOU: OrganizationalUnit? = nil
    ) async throws -> OrganizationalUnit {
        let ou = OrganizationalUnit(
            name: name,
            description: description,
            organizationID: organization.id!,
            parentOUID: parentOU?.id,
            path: "",
            depth: parentOU != nil ? (parentOU!.depth + 1) : 0
        )
        try await ou.save(on: db)
        ou.path = try await ou.buildPath(on: db)
        try await ou.save(on: db)
        return ou
    }

    /// Reuses an organization's test site, or creates one when the fixture has
    /// not needed site-scoped infrastructure yet.
    package func placementSite(for project: Project) async throws -> Site {
        guard let organizationID = try await project.getRootOrganizationId(on: db) else {
            throw Abort(.internalServerError, reason: "Test project has no owning organization")
        }
        if let existing = try await Site.query(on: db)
            .filter(\.$organization.$id == organizationID)
            .first()
        {
            return existing
        }
        let site = Site(
            name: "Test Site \(organizationID.uuidString)",
            organizationScope: .organization(organizationID)
        )
        try await site.save(on: db)
        return site
    }

    /// A logical network in `project`. Nothing provisions one automatically
    /// (issue #765), so any fixture whose workloads need a network must make
    /// one — and two projects may safely share a name and a subnet.
    @discardableResult
    package func createNetwork(
        name: String = "default",
        project: Project,
        subnet: String = "192.168.1.0/24",
        gateway: String? = "192.168.1.1",
        subnet6: String? = nil,
        gateway6: String? = nil,
        dhcpEnabled: Bool = true,
        externalAccess: Bool = true,
        site: Site? = nil
    ) async throws -> LogicalNetwork {
        let resolvedSite: Site
        if let site {
            resolvedSite = site
        } else {
            resolvedSite = try await placementSite(for: project)
        }
        let network = LogicalNetwork(
            name: name,
            subnet: subnet,
            gateway: gateway,
            subnet6: subnet6,
            gateway6: gateway6,
            projectID: try project.requireID(),
            dhcpEnabled: dhcpEnabled,
            externalAccess: externalAccess,
            siteID: try resolvedSite.requireID()
        )
        try await network.save(on: db)
        return network
    }

    package func createProject(
        name: String,
        description: String,
        organization: Organization? = nil,
        ou: OrganizationalUnit? = nil,
        environments: [String] = ["development", "staging", "production"],
        defaultEnvironment: String = "development"
    ) async throws -> Project {
        let project = Project(
            name: name,
            description: description,
            organizationID: organization?.id,
            organizationalUnitID: ou?.id,
            path: "",
            defaultEnvironment: defaultEnvironment,
            environments: environments
        )
        try await project.save(on: db)
        project.path = try await project.buildPath(on: db)
        try await project.save(on: db)
        return project
    }

    package func createGroup(
        name: String,
        description: String,
        organization: Organization
    ) async throws -> Group {
        let group = Group(
            name: name,
            description: description,
            organizationID: organization.id!
        )
        try await group.save(on: db)
        return group
    }

    package func createResourceQuota(
        name: String,
        maxVCPUs: Int = 10,
        maxMemoryGB: Double = 20.0,
        maxStorageGB: Double = 100.0,
        maxVMs: Int = 5,
        maxNetworks: Int = 10,
        organization: Organization? = nil,
        ou: OrganizationalUnit? = nil,
        project: Project? = nil,
        environment: String? = nil
    ) async throws -> ResourceQuota {
        let quota = ResourceQuota(
            name: name,
            organizationID: organization?.id,
            organizationalUnitID: ou?.id,
            projectID: project?.id,
            maxVCPUs: maxVCPUs,
            maxMemory: Int64(maxMemoryGB * 1024 * 1024 * 1024),
            maxStorage: Int64(maxStorageGB * 1024 * 1024 * 1024),
            maxVMs: maxVMs,
            maxNetworks: maxNetworks,
            environment: environment
        )
        try await quota.save(on: db)
        return quota
    }

    package func createVM(
        name: String,
        project: Project,
        environment: String = "development",
        image: String = "test-image"
    ) async throws -> VM {
        let vm = VM(
            name: name,
            description: "Test VM",
            image: image,
            projectID: project.id!,
            environment: environment,
            cpu: 2,
            memory: 2 * 1024 * 1024 * 1024,
            disk: 10 * 1024 * 1024 * 1024
        )
        try await vm.save(on: db)
        return vm
    }

    package func createSandbox(
        name: String,
        project: Project,
        environment: String = "development",
        image: String = "ghcr.io/acme/worker:v1"
    ) async throws -> Sandbox {
        let sandbox = Sandbox(
            name: name,
            projectID: project.id!,
            environment: environment,
            image: image,
            cpus: 1,
            memory: 1024 * 1024 * 1024
        )
        try await sandbox.save(on: db)
        return sandbox
    }

    /// A saved volume, for the suites that only need one to exist (STR-181's
    /// quota accounting, mostly). Suites that drive convergence keep their own
    /// richer builders — this one sets no agent, path or attachment.
    package func createVolume(
        name: String,
        project: Project,
        environment: String = "development",
        sizeGB: Int = 10,
        status: VolumeStatus = .available,
        createdBy: User
    ) async throws -> Volume {
        let volume = Volume(
            name: name,
            description: "Test volume",
            projectID: try project.requireID(),
            environment: environment,
            size: Int64(sizeGB) * 1024 * 1024 * 1024,
            status: status,
            createdByID: try createdBy.requireID()
        )
        try await volume.save(on: db)
        return volume
    }

    package func createImage(
        name: String = "Test Image",
        description: String = "Test image description",
        project: Project,
        filename: String = "test.qcow2",
        size: Int64 = 10 * 1024 * 1024,
        format: ImageFormat = .qcow2,
        status: ImageStatus = .ready,
        uploadedBy: User,
        storagePath: String? = nil,
        sourceURL: String? = nil,
        checksum: String? = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    ) async throws -> Image {
        let projectID = try project.requireID()
        let image = Image(
            name: name,
            description: description,
            projectID: projectID,
            status: status,
            uploadedByID: uploadedBy.id!
        )
        try await image.save(on: db)

        if status == .ready || storagePath != nil || sourceURL != nil {
            let imageID = try image.requireID()
            let artifact = ImageArtifact(
                imageID: imageID,
                kind: .diskImage,
                format: format,
                architecture: image.architecture,
                filename: filename,
                size: size,
                checksum: checksum ?? "",
                storagePath: storagePath
                    ?? ImageObjectKey.artifact(
                        projectId: projectID,
                        imageId: imageID,
                        kind: "disk-image",
                        filename: filename),
                status: status == .ready ? .ready : .pending,
                sourceURL: sourceURL,
                expectedChecksum: status == .ready ? nil : checksum
            )
            try await artifact.save(on: db)
            image.$artifacts.value = [artifact]
        }
        return image
    }
}

// MARK: - Mock Image Fetch Service

/// Mock ImageFetchService that does nothing (prevents real HTTP requests in tests)
package actor MockImageFetchService: ImageFetchServiceProtocol {
    package var startedArtifactFetches: [UUID] = []

    package init() {}

    package func startArtifactFetch(artifactId: UUID) async throws {
        startedArtifactFetches.append(artifactId)
        // No-op: don't actually fetch anything
    }
}

// MARK: - Conditioned role bindings

/// Run `body` with the STR-108 write boundary lifted, then put it back.
///
/// Conditions are not implemented, so the evaluator skips a conditioned binding
/// and it grants nothing. That skip is the defence in depth behind the
/// constraint, and the only way to exercise it is to reproduce the one way such
/// a row can still appear: a write against a database whose constraint predates
/// or outlives this deployment. Dropping the constraint is safe because every
/// test runs against its own clone of the migrated template, which teardown
/// destroys.
///
/// The restore is what makes it scoped rather than remembered: leaving the
/// boundary down for the rest of the test would let a later assertion that a
/// conditioned write is refused pass vacuously. It comes back `NOT VALID`,
/// since any row `body` wrote would fail the re-scan a validating `ADD
/// CONSTRAINT` performs — which is exactly the state being simulated: new
/// writes refused, one legacy row already present.
///
/// (`Application.makeForBareDatabaseTesting()` is the house pattern for
/// migration before/after tests that hand-build a legacy schema. This does not
/// use it: the only difference from the current schema is one constraint, and
/// dropping it in place also exercises the migration's idempotent
/// drop-then-add.)
package func withConditionedRoleBindingsAllowed<T>(
    on db: any Database,
    _ body: () async throws -> T
) async throws -> T {
    let sql = try sqlDatabaseForTest(db)
    let constraint = RoleBinding.conditionConstraintName
    try await sql.raw(
        "ALTER TABLE \"role_bindings\" DROP CONSTRAINT IF EXISTS \(unsafeRaw: constraint)"
    ).run()

    func restore() async throws {
        try await sql.raw(
            """
            ALTER TABLE "role_bindings" ADD CONSTRAINT \(unsafeRaw: constraint)
            CHECK ("condition" IS NULL) NOT VALID
            """
        ).run()
    }

    do {
        let result = try await body()
        try await restore()
        return result
    } catch {
        try? await restore()
        throw error
    }
}

/// Write a `role_bindings` row carrying a `condition` — which the schema
/// otherwise refuses (STR-108) — leaving the
/// boundary in place for everything after it. See
/// `withConditionedRoleBindingsAllowed`.
package func insertConditionedRoleBinding(
    principalType: IAMPrincipalType,
    principalID: UUID,
    role: IAMRole,
    nodeType: IAMNodeType,
    nodeID: UUID,
    condition: String,
    on db: any Database
) async throws {
    try await withConditionedRoleBindingsAllowed(on: db) {
        let binding = RoleBinding(
            principalType: principalType,
            principalID: principalID,
            role: role,
            nodeType: nodeType,
            nodeID: nodeID
        )
        binding.condition = condition
        try await binding.save(on: db)
    }
}

/// The state of the STR-108 write boundary on `role_bindings`.
package enum ConditionedRoleBindingConstraintState: Equatable, Sendable {
    /// No constraint: a conditioned row can be written.
    case absent
    /// Present but unvalidated — new writes are refused, existing rows were
    /// never scanned. What `withConditionedRoleBindingsAllowed` restores.
    case notValidated
    /// Present and validated, which Postgres only permits when no conditioned
    /// row survives.
    case validated
}

package func conditionedRoleBindingConstraint(
    on db: any Database
) async throws -> ConditionedRoleBindingConstraintState {
    let sql = try sqlDatabaseForTest(db)
    let rows = try await sql.raw(
        """
        SELECT convalidated FROM pg_constraint
        WHERE conrelid = 'role_bindings'::regclass
          AND conname = \(bind: RoleBinding.conditionConstraintName)
        """
    ).all()
    guard let row = rows.first else { return .absent }
    return try row.decode(column: "convalidated", as: Bool.self) ? .validated : .notValidated
}

/// Whether the schema refuses a conditioned write — either constraint state
/// does, validated or not.
package func conditionedRoleBindingsAreRefused(on db: any Database) async throws -> Bool {
    try await conditionedRoleBindingConstraint(on: db) != .absent
}

/// Give a saved test volume its authoritative physical placement. Passing no
/// agent deliberately leaves the volume unplaced for tests that exercise that
/// state.
@discardableResult
package func placeVolume(
    _ volume: Volume,
    on agentID: String?,
    at filePath: String? = "/var/lib/strato/volumes/test/volume.qcow2",
    state: VolumeReplicaState = .healthy,
    using db: any Database
) async throws -> VolumeReplica? {
    guard let agentID else { return nil }
    let replica = VolumeReplica(
        volumeID: try volume.requireID(),
        agentId: agentID,
        diskAttachment: filePath.map {
            .file(
                path: $0,
                format: $0.lowercased().hasSuffix(".raw") ? .raw : .qcow2)
        },
        state: state,
        generation: volume.observedGeneration
    )
    try await replica.create(on: db)
    return replica
}

/// Attach the canonical managed boot volume to a saved test VM and place it on
/// the agent. Every live VM must carry exactly one such volume (writable disk0
/// at boot order 0) or `VMSpecBuilder` refuses to assemble it — since STR-287
/// the assembler then omits the VM from the sync instead of failing it, so a
/// test that expects its VM to appear in assembled desired state needs this.
@discardableResult
package func attachBootVolume(
    to vm: VM, on agentID: String?, using db: any Database
) async throws -> Volume {
    let ownerID: UUID
    if let owner = try await User.query(on: db).sort(\.$createdAt).first() {
        ownerID = try owner.requireID()
    } else {
        let owner = try await TestDataBuilder(db: db).createUser(
            username: "boot-volume-owner", email: "boot-volume-owner@example.com")
        ownerID = try owner.requireID()
    }
    // Placement admission requires the boot volume to name its pool; the
    // schema baseline seeds the default pool in every test database.
    let poolID = try await StoragePool.defaultPool(on: db).requireID()
    // An unplaced volume is still converging: `.attached` and an owning
    // `attachedAgentId` only once a host actually holds it, matching what
    // placement writes — adoption repoints ownership by that field.
    let boot = Volume(
        name: "\(vm.name)-boot", description: "", projectID: vm.$project.id,
        environment: vm.environment, size: vm.disk, format: .qcow2,
        volumeType: .boot, status: agentID == nil ? .creating : .attached,
        createdByID: ownerID, poolID: poolID)
    boot.attachedAgentId = agentID
    boot.$vm.id = try vm.requireID()
    boot.deviceName = VolumeDeviceName.disk(0).rawValue
    boot.bootOrder = 0
    boot.generation = 1
    boot.observedGeneration = 1
    try await boot.save(on: db)
    try await placeVolume(
        boot, on: agentID,
        at: "/var/lib/strato/volumes/\(try boot.requireID())/volume.qcow2",
        state: .healthy, using: db)
    return boot
}

private func sqlDatabaseForTest(_ db: any Database) throws -> any SQLDatabase {
    guard let sql = db as? any SQLDatabase else {
        throw TestSetupError.message("conditioned binding fixtures need a SQL database")
    }
    return sql
}

package enum TestSetupError: Error, CustomStringConvertible {
    case message(String)

    package var description: String {
        switch self {
        case .message(let text): return text
        }
    }
}

// MARK: - Agent identity keys

/// The key an agent registered under the bare name `name` is stored beneath in
/// the connection map, the coordination presence/route keys, and console/exec
/// session ownership: its full SPIFFE ID in the platform trust domain
/// (issue #613). Tests that register an agent by name and then assert on one of
/// those registries must go through this rather than the bare name.
package func agentKey(_ name: String) -> String {
    AgentIdentity(trustDomain: PlatformTrustDomain.current, name: name).key
}
