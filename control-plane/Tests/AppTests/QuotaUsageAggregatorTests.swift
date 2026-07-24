import Fluent
import StratoShared
import Testing
import Vapor

@testable import App

/// Tests that the SQL aggregates behind quota accounting (issue #692) report
/// exactly what loading every in-scope workload and reducing in Swift used to
/// report — for each scope shape, with and without an environment filter.
///
/// The reduce each test compares against is deliberately spelled out rather
/// than factored away: it is the previous implementation, and it is the thing
/// the aggregate has to stay equal to.
@Suite("Quota Usage Aggregator Tests", .serialized)
struct QuotaUsageAggregatorTests {

    /// An organization with a folder subtree, projects at both levels, and
    /// workloads spread across two environments.
    private struct Fixture {
        let organization: Organization
        /// Root folder of the subtree: Engineering → TeamA.
        let engineering: OrganizationalUnit
        let teamA: OrganizationalUnit
        /// A sibling folder whose workloads must never land in Engineering's scope.
        let marketing: OrganizationalUnit
        /// Hangs directly off the organization.
        let directProject: Project
        let teamAProject: Project
        let marketingProject: Project
    }

    private func seed(on db: Database) async throws -> Fixture {
        let builder = TestDataBuilder(db: db)
        let org = try await builder.createOrganization(name: "Aggregate Org \(UUID().uuidString)")

        let engineering = try await builder.createOU(
            name: "Engineering", description: "d", organization: org)
        let teamA = try await builder.createOU(
            name: "TeamA", description: "d", organization: org, parentOU: engineering)
        let marketing = try await builder.createOU(
            name: "Marketing", description: "d", organization: org)

        let directProject = try await builder.createProject(
            name: "Direct", description: "p", organization: org)
        let teamAProject = try await builder.createProject(name: "TeamA App", description: "p", ou: teamA)
        let marketingProject = try await builder.createProject(name: "Campaigns", description: "p", ou: marketing)

        // VMs: two environments in the nested project, one apiece elsewhere.
        _ = try await builder.createVM(name: "direct-dev", project: directProject)
        _ = try await builder.createVM(name: "team-dev", project: teamAProject)
        _ = try await builder.createVM(
            name: "team-prod", project: teamAProject, environment: "production")
        _ = try await builder.createVM(name: "mkt-dev", project: marketingProject)

        // Sandboxes draw from the same vCPU/memory pools.
        _ = try await builder.createSandbox(name: "team-sbx", project: teamAProject)
        _ = try await builder.createSandbox(
            name: "team-sbx-prod", project: teamAProject, environment: "production")
        _ = try await builder.createSandbox(name: "mkt-sbx", project: marketingProject)

        return Fixture(
            organization: org,
            engineering: engineering,
            teamA: teamA,
            marketing: marketing,
            directProject: directProject,
            teamAProject: teamAProject,
            marketingProject: marketingProject
        )
    }

    /// The pre-#692 measurement: hydrate every workload in scope, reduce in Swift.
    private func reduceUsage(
        projectIDs: [UUID], environment: String?, on db: Database
    ) async throws -> QuotaMeasuredUsage {
        guard !projectIDs.isEmpty else { return .none }

        let vmQuery = VM.query(on: db).filter(\.$project.$id ~~ projectIDs)
        let sandboxQuery = Sandbox.query(on: db).filter(\.$project.$id ~~ projectIDs)
        let snapshotQuery = SandboxSnapshot.query(on: db)
            .filter(\.$project.$id ~~ projectIDs)
            .filter(\.$status != .error)
        if let environment {
            vmQuery.filter(\.$environment == environment)
            sandboxQuery.filter(\.$environment == environment)
            snapshotQuery.filter(\.$environment == environment)
        }
        let vms = try await vmQuery.all()
        let sandboxes = try await sandboxQuery.all()
        let snapshots = try await snapshotQuery.all()

        let snapshotBytes = snapshots.reduce(Int64(0)) { total, snapshot in
            let exported = (snapshot.exportedArtifacts ?? []).reduce(Int64(0)) { $0 + $1.sizeBytes }
            return total + (snapshot.size ?? 0) + exported
        }

        return QuotaMeasuredUsage(
            vcpus: vms.reduce(0) { $0 + $1.cpu } + sandboxes.reduce(0) { $0 + $1.cpus },
            memoryBytes: vms.reduce(Int64(0)) { $0 + $1.memory }
                + sandboxes.reduce(Int64(0)) { $0 + $1.memory },
            storageBytes: vms.reduce(Int64(0)) { $0 + $1.disk } + snapshotBytes,
            vmCount: vms.count,
            sandboxCount: sandboxes.count
        )
    }

    private func expectMatchesReduce(
        quota: ResourceQuota, projectIDs: [UUID], on db: Database, _ label: Comment
    ) async throws {
        let expected = try await reduceUsage(
            projectIDs: projectIDs, environment: quota.environment, on: db)
        let measured = try await QuotaUsageAggregator.measure(quota: quota, on: db)

        #expect(measured.vcpus == expected.vcpus, label)
        #expect(measured.memoryBytes == expected.memoryBytes, label)
        #expect(measured.storageBytes == expected.storageBytes, label)
        #expect(measured.vmCount == expected.vmCount, label)
        #expect(measured.sandboxCount == expected.sandboxCount, label)
    }

    @Test("Aggregates match a full-row reduce for every scope shape")
    func aggregatesMatchReduce() async throws {
        try await withTestApp { app in
            let fixture = try await seed(on: app.db)
            let builder = TestDataBuilder(db: app.db)

            let projectQuota = try await builder.createResourceQuota(
                name: "project", project: fixture.teamAProject)
            try await expectMatchesReduce(
                quota: projectQuota,
                projectIDs: [try fixture.teamAProject.requireID()],
                on: app.db,
                "project scope")

            // A folder quota measures its whole subtree, so the grandchild
            // project counts and the sibling folder's does not (issue #645).
            let folderQuota = try await builder.createResourceQuota(
                name: "folder", ou: fixture.engineering)
            try await expectMatchesReduce(
                quota: folderQuota,
                projectIDs: [try fixture.teamAProject.requireID()],
                on: app.db,
                "folder subtree scope")

            let orgQuota = try await builder.createResourceQuota(
                name: "org", organization: fixture.organization)
            try await expectMatchesReduce(
                quota: orgQuota,
                projectIDs: [
                    try fixture.directProject.requireID(),
                    try fixture.teamAProject.requireID(),
                    try fixture.marketingProject.requireID(),
                ],
                on: app.db,
                "organization scope")
        }
    }

    @Test("An environment-scoped quota measures only that environment")
    func environmentScopedQuotaMeasuresOneEnvironment() async throws {
        try await withTestApp { app in
            let fixture = try await seed(on: app.db)
            let builder = TestDataBuilder(db: app.db)

            let prodQuota = try await builder.createResourceQuota(
                name: "prod", organization: fixture.organization, environment: "production")
            try await expectMatchesReduce(
                quota: prodQuota,
                projectIDs: [
                    try fixture.directProject.requireID(),
                    try fixture.teamAProject.requireID(),
                    try fixture.marketingProject.requireID(),
                ],
                on: app.db,
                "production-only organization scope")

            // Only the production VM and sandbox of TeamA exist in that environment.
            let measured = try await QuotaUsageAggregator.measure(quota: prodQuota, on: app.db)
            #expect(measured.vmCount == 1)
            #expect(measured.sandboxCount == 1)
        }
    }

    @Test("Snapshot storage counts stored and exported bytes once each")
    func snapshotStorageCountsBothCopies() async throws {
        try await withTestApp { app in
            let fixture = try await seed(on: app.db)
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "snap-\(UUID().uuidString.prefix(8))", email: "snap-\(UUID().uuidString)@example.com")
            let sandbox = try await builder.createSandbox(name: "snapped", project: fixture.teamAProject)

            let ready = SandboxSnapshot(
                name: "ready",
                sandboxID: try sandbox.requireID(),
                projectID: try fixture.teamAProject.requireID(),
                environment: sandbox.environment,
                agentId: "agent-1",
                createdByID: try user.requireID())
            ready.status = .ready
            ready.size = 3 * 1024 * 1024 * 1024
            ready.exportedArtifacts = [
                SandboxSnapshotExportedArtifact(
                    kind: SandboxSnapshotArtifactKind.allCases[0],
                    sizeBytes: 512 * 1024 * 1024,
                    sha256: String(repeating: "0", count: 64))
            ]
            try await ready.save(on: app.db)

            // A failed checkpoint removes its partial artifacts: not counted.
            let errored = SandboxSnapshot(
                name: "errored",
                sandboxID: try sandbox.requireID(),
                projectID: try fixture.teamAProject.requireID(),
                environment: sandbox.environment,
                agentId: "agent-1",
                createdByID: try user.requireID())
            errored.status = .error
            errored.size = 9 * 1024 * 1024 * 1024
            try await errored.save(on: app.db)

            let folderQuota = try await builder.createResourceQuota(
                name: "folder", ou: fixture.engineering)
            let scope = try await QuotaUsageAggregator.scope(of: folderQuota, on: app.db)
            let snapshotBytes = try await QuotaUsageAggregator.snapshotStorageBytes(in: scope, on: app.db)
            #expect(snapshotBytes == 3 * 1024 * 1024 * 1024 + 512 * 1024 * 1024)

            // And the same bytes show up in the quota's storage total.
            try await expectMatchesReduce(
                quota: folderQuota,
                projectIDs: [try fixture.teamAProject.requireID()],
                on: app.db,
                "folder scope with snapshots")
        }
    }

    @Test("A quota whose folder is gone measures nothing, not everything")
    func danglingScopeMeasuresNothing() async throws {
        try await withTestApp { app in
            _ = try await seed(on: app.db)

            // The scoping folder was deleted out from under the quota. The
            // scope must collapse to nothing — a predicate that degenerated to
            // "no folder filter" would sweep in every project in the database.
            let quota = ResourceQuota(
                name: "dangling",
                organizationalUnitID: UUID(),
                maxVCPUs: 8,
                maxMemory: 8 << 30,
                maxStorage: 8 << 30,
                maxVMs: 4)

            let measured = try await QuotaUsageAggregator.measure(quota: quota, on: app.db)
            #expect(measured.vcpus == 0)
            #expect(measured.vmCount == 0)
            #expect(measured.sandboxCount == 0)
            #expect(measured.storageBytes == 0)
        }
    }

    @Test("The VM breakdown counts the same VMs the totals do")
    func vmBreakdownMatchesTotals() async throws {
        try await withTestApp { app in
            let fixture = try await seed(on: app.db)
            let builder = TestDataBuilder(db: app.db)
            let quota = try await builder.createResourceQuota(
                name: "org", organization: fixture.organization)

            let scope = try await QuotaUsageAggregator.scope(of: quota, on: app.db)
            let measured = try await QuotaUsageAggregator.measure(scope, on: app.db)
            let breakdown = try await QuotaUsageAggregator.vmBreakdown(in: scope, on: app.db)

            #expect(breakdown.byEnvironment.values.reduce(0, +) == measured.vmCount)
            #expect(breakdown.byStatus.values.reduce(0, +) == measured.vmCount)
            #expect(breakdown.byEnvironment["development"] == 3)
            #expect(breakdown.byEnvironment["production"] == 1)
        }
    }
}
