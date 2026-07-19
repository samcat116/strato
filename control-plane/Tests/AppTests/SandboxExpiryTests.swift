import Fluent
import StratoShared
import Testing
import Vapor
import VaporTesting

@testable import App

/// Tests for sandbox TTL and auto-expiry (issue #424): the expiry sweep
/// deletes sandboxes past their lifetime budget, reaps terminal records once
/// the retention window closes, and does both down the user-initiated delete
/// path — so quota releases exactly as it would on `DELETE /api/sandboxes/:id`.
@Suite("Sandbox Expiry Tests", .serialized)
final class SandboxExpiryTests {

    /// Same harness shape as `SandboxTests`: full stack, one org/project, and
    /// one unplaced sandbox. Unplaced is the interesting default here — with no
    /// agent to converge on, expiry takes the direct-deletion path and the row
    /// goes without an agent report.
    private func withSandboxTestApp(
        _ test: (Application, User, Project, Sandbox) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "expiryuser",
                email: "expiry@example.com",
                displayName: "Expiry User",
                isSystemAdmin: false
            )
            let org = try await builder.createOrganization(name: "Expiry Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "member")
            user.currentOrganizationId = org.id
            try await user.save(on: app.db)

            let project = try await builder.createProject(
                name: "Expiry Project",
                description: "Project for sandbox expiry tests",
                organization: org
            )
            let sandbox = try await builder.createSandbox(name: "expiry-sandbox", project: project)

            try await test(app, user, project, sandbox)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }

        try await app.shutdownForTesting()
    }

    /// `@Timestamp(on: .create)` overwrites `createdAt` on insert, so ageing a
    /// row means saving it first and backdating afterwards.
    private func backdateCreation(_ sandbox: Sandbox, bySeconds seconds: TimeInterval, on db: any Database)
        async throws
    {
        sandbox.createdAt = Date().addingTimeInterval(-seconds)
        try await sandbox.save(on: db)
    }

    /// The direct deletion runs in a background task, so the row disappears
    /// asynchronously after the sweep returns.
    private func pollSandboxDeleted(_ sandboxID: UUID, on db: any Database) async throws {
        for _ in 0..<100 {
            if try await Sandbox.find(sandboxID, on: db) == nil { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("Sandbox \(sandboxID) was never deleted")
    }

    private func deleteOperation(for sandboxID: UUID, on db: any Database) async throws -> ResourceOperation? {
        try await ResourceOperation.query(on: db)
            .filter(\.$resourceKind == .sandbox)
            .filter(\.$resourceID == sandboxID)
            .filter(\.$kind == .delete)
            .first()
    }

    /// Waits for the sandbox's delete operation to reach a verdict. The record
    /// is removed *before* the operation is completed, so a test that polls on
    /// the row's absence can still catch the operation mid-flight.
    private func pollDeleteOperationCompleted(
        for sandboxID: UUID, on db: any Database
    ) async throws -> ResourceOperation? {
        for _ in 0..<100 {
            if let operation = try await deleteOperation(for: sandboxID, on: db), operation.status != .pending {
                return operation
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("Delete operation for sandbox \(sandboxID) never completed")
        return nil
    }

    // MARK: - expiresAt

    @Test("expiresAt is the creation anchor plus the TTL, and nil without one")
    func expiresAtDerivation() async throws {
        try await withSandboxTestApp { app, _, _, sandbox in
            #expect(sandbox.expiresAt == nil)
            #expect(sandbox.isExpired() == false)

            sandbox.ttlSeconds = 3600
            try await sandbox.save(on: app.db)

            let createdAt = try #require(sandbox.createdAt)
            let expiresAt = try #require(sandbox.expiresAt)
            #expect(abs(expiresAt.timeIntervalSince(createdAt) - 3600) < 1)
            #expect(sandbox.isExpired() == false)

            // A sandbox created before its own budget elapsed is expired now.
            try await backdateCreation(sandbox, bySeconds: 7200, on: app.db)
            #expect(sandbox.isExpired())
        }
    }

    @Test("The response DTO surfaces expiresAt for clients to count down from")
    func detailResponseCarriesExpiresAt() async throws {
        try await withSandboxTestApp { app, _, _, sandbox in
            #expect(SandboxDetailResponse(from: sandbox).expiresAt == nil)

            sandbox.ttlSeconds = 600
            try await sandbox.save(on: app.db)

            let response = SandboxDetailResponse(from: sandbox)
            #expect(response.ttlSeconds == 600)
            #expect(response.expiresAt == sandbox.expiresAt)
        }
    }

    // MARK: - TTL expiry

    @Test("The sweep deletes a sandbox past its TTL, recording a delete operation")
    func sweepDeletesExpiredSandbox() async throws {
        try await withSandboxTestApp { app, _, _, sandbox in
            let sandboxID = try sandbox.requireID()
            sandbox.ttlSeconds = 60
            try await backdateCreation(sandbox, bySeconds: 120, on: app.db)

            await app.agentService.sweepExpiredSandboxes()

            try await pollSandboxDeleted(sandboxID, on: app.db)

            // The operation outlives the row it removed — that is what makes an
            // unattended deletion auditable.
            let operation = try #require(await pollDeleteOperationCompleted(for: sandboxID, on: app.db))
            #expect(operation.status == .succeeded)
            #expect(operation.userID == ResourceOperation.systemUserID)
        }
    }

    @Test("The sweep leaves a sandbox still inside its TTL alone")
    func sweepKeepsUnexpiredSandbox() async throws {
        try await withSandboxTestApp { app, _, _, sandbox in
            let sandboxID = try sandbox.requireID()
            sandbox.ttlSeconds = 3600
            try await backdateCreation(sandbox, bySeconds: 60, on: app.db)

            await app.agentService.sweepExpiredSandboxes()

            let refreshed = try #require(await Sandbox.find(sandboxID, on: app.db))
            #expect(refreshed.desiredStatus == .stopped)
            let operation = try await deleteOperation(for: sandboxID, on: app.db)
            #expect(operation == nil)
        }
    }

    @Test("A sandbox with no TTL never expires, however old it is")
    func sweepIgnoresSandboxWithoutTTL() async throws {
        try await withSandboxTestApp { app, _, _, sandbox in
            let sandboxID = try sandbox.requireID()
            try await backdateCreation(sandbox, bySeconds: 86400 * 30, on: app.db)

            await app.agentService.sweepExpiredSandboxes()

            let survivor = try await Sandbox.find(sandboxID, on: app.db)
            #expect(survivor != nil)
            let operation = try await deleteOperation(for: sandboxID, on: app.db)
            #expect(operation == nil)
        }
    }

    @Test(
        "TTL and retention expiry preserve snapshot sources with live forks",
        arguments: [true, false])
    func sweepPreservesSnapshotSourceWithLiveFork(useTTL: Bool) async throws {
        try await withSandboxTestApp { app, user, project, sandbox in
            let sandboxID = try sandbox.requireID()
            let snapshot = SandboxSnapshot(
                name: "expiry-lineage-source",
                sandboxID: sandboxID,
                projectID: try project.requireID(),
                environment: sandbox.environment,
                agentId: nil,
                createdByID: try user.requireID())
            snapshot.status = .ready
            try await snapshot.save(on: app.db)

            let fork = Sandbox(
                name: "expiry-lineage-fork",
                projectID: try project.requireID(),
                environment: sandbox.environment,
                image: sandbox.image,
                cpus: sandbox.cpus,
                memory: sandbox.memory,
                restoredFromSnapshotId: try snapshot.requireID())
            try await fork.save(on: app.db)

            if useTTL {
                sandbox.ttlSeconds = 60
                try await backdateCreation(sandbox, bySeconds: 120, on: app.db)
            } else {
                let window = TimeInterval(AgentService.defaultSandboxRetentionHours) * 3600
                sandbox.setStatus(.exited, at: Date().addingTimeInterval(-window - 60))
                try await sandbox.save(on: app.db)
            }

            await app.agentService.sweepExpiredSandboxes()

            let source = try #require(await Sandbox.find(sandboxID, on: app.db))
            #expect(source.desiredStatus != .absent)
            #expect(try await SandboxSnapshot.find(snapshot.requireID(), on: app.db) != nil)
            #expect(try await Sandbox.find(fork.requireID(), on: app.db) != nil)
            #expect(try await deleteOperation(for: sandboxID, on: app.db) == nil)
        }
    }

    // MARK: - Retention

    @Test("Terminal sandboxes are reaped once the retention window closes", arguments: [SandboxStatus.exited, .error])
    func sweepReapsTerminalSandboxPastRetention(status: SandboxStatus) async throws {
        try await withSandboxTestApp { app, _, _, sandbox in
            let sandboxID = try sandbox.requireID()
            let window = TimeInterval(AgentService.defaultSandboxRetentionHours) * 3600
            sandbox.setStatus(status, at: Date().addingTimeInterval(-window - 60))
            sandbox.exitCode = 0
            try await sandbox.save(on: app.db)

            await app.agentService.sweepExpiredSandboxes()

            try await pollSandboxDeleted(sandboxID, on: app.db)
            let operation = try #require(await pollDeleteOperationCompleted(for: sandboxID, on: app.db))
            #expect(operation.status == .succeeded)
        }
    }

    @Test("A recently exited sandbox keeps its terminal record for inspection")
    func sweepKeepsRecentTerminalSandbox() async throws {
        try await withSandboxTestApp { app, _, _, sandbox in
            let sandboxID = try sandbox.requireID()
            sandbox.setStatus(.exited, at: Date().addingTimeInterval(-3600))
            sandbox.exitCode = 137
            try await sandbox.save(on: app.db)

            await app.agentService.sweepExpiredSandboxes()

            // The whole point of the retention window: status and exit code
            // stay readable after the workload is gone.
            let refreshed = try #require(await Sandbox.find(sandboxID, on: app.db))
            #expect(refreshed.status == .exited)
            #expect(refreshed.exitCode == 137)
            #expect(refreshed.desiredStatus != .absent)
        }
    }

    @Test("A running sandbox is never reaped by retention, however old")
    func sweepKeepsOldRunningSandbox() async throws {
        try await withSandboxTestApp { app, _, _, sandbox in
            let sandboxID = try sandbox.requireID()
            sandbox.setStatus(.running, at: Date().addingTimeInterval(-86400 * 30))
            try await sandbox.save(on: app.db)

            await app.agentService.sweepExpiredSandboxes()

            let survivor = try await Sandbox.find(sandboxID, on: app.db)
            #expect(survivor != nil)
        }
    }

    // MARK: - Quota

    @Test("TTL-driven deletion releases quota the same way a user delete does")
    func expiryReleasesQuota() async throws {
        try await withSandboxTestApp { app, _, project, sandbox in
            let sandboxID = try sandbox.requireID()
            let builder = TestDataBuilder(db: app.db)
            let quota = try await builder.createResourceQuota(
                name: "expiry-quota", maxVCPUs: 10, project: project)

            // The state the create endpoint's reservation leaves behind: with
            // the sandbox row present, correct accounting is one sandbox
            // holding its vCPUs and memory. Set directly rather than via
            // `reserveSandbox`, which admits a sandbox *before* its row exists
            // and so would count this one twice.
            quota.reservedVCPUs = sandbox.cpus
            quota.reservedMemory = sandbox.memory
            quota.sandboxCount = 1
            try await quota.save(on: app.db)

            sandbox.ttlSeconds = 60
            try await backdateCreation(sandbox, bySeconds: 120, on: app.db)

            await app.agentService.sweepExpiredSandboxes()
            try await pollSandboxDeleted(sandboxID, on: app.db)

            let released = try #require(await ResourceQuota.find(quota.id, on: app.db))
            #expect(released.sandboxCount == 0)
            #expect(released.reservedVCPUs == 0)
            #expect(released.reservedMemory == 0)
        }
    }

    // MARK: - Coordination

    @Test("The expiry sweep is a cluster singleton")
    func sweepRespectsSingletonLock() async throws {
        try await withSandboxTestApp { app, _, _, sandbox in
            let sandboxID = try sandbox.requireID()
            sandbox.ttlSeconds = 60
            try await backdateCreation(sandbox, bySeconds: 120, on: app.db)

            // Stand in for another replica's in-flight pass.
            let acquired = await app.coordination.acquireSweepLock("sandbox_expiry")
            #expect(acquired)

            await app.agentService.sweepExpiredSandboxes()

            let survivor = try await Sandbox.find(sandboxID, on: app.db)
            #expect(survivor != nil)
            let operation = try await deleteOperation(for: sandboxID, on: app.db)
            #expect(operation == nil)
        }
    }

    @Test("A sandbox with a pending operation is deferred, not double-deleted")
    func sweepDefersToPendingOperation() async throws {
        try await withSandboxTestApp { app, user, _, sandbox in
            let sandboxID = try sandbox.requireID()
            sandbox.ttlSeconds = 60
            try await backdateCreation(sandbox, bySeconds: 120, on: app.db)

            // A user action already owns the sandbox.
            let userID = try user.requireID()
            let pending = try await ResourceOperation.begin(
                .boot, resourceKind: .sandbox, resourceID: sandboxID,
                userID: userID, on: app.db)

            await app.agentService.sweepExpiredSandboxes()

            // Left intact, and the in-flight operation is untouched.
            let refreshed = try #require(await Sandbox.find(sandboxID, on: app.db))
            #expect(refreshed.desiredStatus != .absent)
            let stillPending = try #require(await ResourceOperation.find(pending.id, on: app.db))
            #expect(stillPending.status == .pending)
            let operation = try await deleteOperation(for: sandboxID, on: app.db)
            #expect(operation == nil)
        }
    }
}
