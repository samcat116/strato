import Foundation
import Fluent
import SQLKit
import StratoShared
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

/// Tests for sandbox TTL and auto-expiry (issue #424): the expiry sweep
/// deletes sandboxes past their lifetime budget, reaps terminal records once
/// the retention window closes, and does both down the user-initiated delete
/// path — so quota releases exactly as it would on `DELETE /api/sandboxes/:id`.
@Suite("Sandbox Expiry Tests", .serialized, .postgresFixture)
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

    /// Whether the sweep recorded a deletion for the sandbox at all — the
    /// `resource_events` row an expiry appends, which replaced the operation
    /// row it used to insert (STR-147).
    private func deletionRequested(for sandboxID: UUID, on db: any Database) async throws -> Bool {
        try await ResourceEvent.query(on: db)
            .filter(\.$resourceKind == .sandbox)
            .filter(\.$resourceID == sandboxID)
            .filter(\.$mutation == .delete)
            .first() != nil
    }

    /// The `resource_events` rows recording the sandbox's deletion: the
    /// `requested` row the expiry appended, and the `completed` row the reap
    /// appended once the last finalizer cleared (STR-147). Together they are
    /// what makes an unattended deletion auditable after its row is gone.
    private func deletionEvents(
        for sandboxID: UUID, on db: any Database
    ) async throws -> (requested: ResourceEvent?, completed: ResourceEvent?) {
        for _ in 0..<100 {
            let requested = try await ResourceEvent.latest(
                .requested, resourceKind: .sandbox, resourceID: sandboxID, on: db)
            let completed = try await ResourceEvent.latest(
                .completed, resourceKind: .sandbox, resourceID: sandboxID, on: db)
            if requested != nil, completed != nil { return (requested, completed) }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("Deletion of sandbox \(sandboxID) was never recorded end to end")
        return (nil, nil)
    }

    // MARK: - expiresAt

    @Test("expiresAt starts at creation plus the idle TTL, and nil without one")
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

    @Test("Idle TTL extends monotonically and uses inclusive boundaries")
    func activityExtendsExpiry() async throws {
        try await withSandboxTestApp { app, _, _, sandbox in
            let anchor = Date(timeIntervalSince1970: 1_700_000_000)
            sandbox.createdAt = anchor
            sandbox.lastActiveAt = anchor
            sandbox.ttlSeconds = 60
            SandboxActivityService.touch(sandbox, at: .testing(anchor.addingTimeInterval(30)))
            SandboxActivityService.touch(sandbox, at: .testing(anchor.addingTimeInterval(10)))
            #expect(sandbox.expiresAt == anchor.addingTimeInterval(90))
            #expect(!sandbox.isExpired(at: .testing(anchor.addingTimeInterval(89.999))))
            #expect(sandbox.isExpired(at: .testing(anchor.addingTimeInterval(90))))
            try await sandbox.save(on: app.db)
            let restarted = try #require(await Sandbox.find(sandbox.requireID(), on: app.db))
            #expect(restarted.expiresAt == sandbox.expiresAt)
            sandbox.lastActiveAt = anchor
            try await sandbox.save(on: app.db)
            let afterStaleWriter = try #require(await Sandbox.find(sandbox.requireID(), on: app.db))
            #expect(afterStaleWriter.lastActiveAt == restarted.lastActiveAt)
        }
    }

    @Test("Expiry rechecks an admitted mutation after selecting a stale candidate")
    func staleExpiryCandidateCannotDeleteActiveRow() async throws {
        try await withSandboxTestApp { app, _, _, sandbox in
            let id = try sandbox.requireID()
            let now = Date()
            sandbox.ttlSeconds = 60
            sandbox.createdAt = now.addingTimeInterval(-120)
            sandbox.lastActiveAt = sandbox.createdAt
            try await sandbox.save(on: app.db)
            let stale = try #require(await Sandbox.find(id, on: app.db))
            try await SandboxActivityService.touch(id: id, on: app.db)
            await app.agentMaintenance.expireSandbox(stale, reason: .ttl(seconds: 60), at: .testing(now), on: app.db)
            #expect(try await !deletionRequested(for: id, on: app.db))
            let current = try #require(await Sandbox.find(id, on: app.db))
            #expect(current.desiredStatus != .absent)
            #expect(current.expiresAt! > now)
        }
    }

    @Test("Pending commands have an exact boundary; active or interrupted admissions survive restart")
    func durableCommandAdmission() async throws {
        try await withSandboxTestApp { app, _, _, sandbox in
            let agent = try await TestDataBuilder(db: app.db).createAgent(named: "idle-admission")
            let id = try sandbox.requireID()
            let agentID = try agent.requireID()
            sandbox.hypervisorId = agentID.uuidString
            sandbox.status = .running
            sandbox.desiredStatus = .running
            sandbox.generation = 1
            sandbox.observedGeneration = 1
            try await sandbox.save(on: app.db)
            let sessionID = UUID()
            let admitted = try await SandboxActivityService.admitPending(
                id: id, sessionID: sessionID, agentID: agentID, agentKey: agent.identity.key, on: app.db)
            let boundary = admitted.addingTimeInterval(GuestExecSessionManager.pendingSessionTTL)
            #expect(
                try await SandboxActivityService.hasAdmittedActivity(
                    id: id, at: .testing(boundary.addingTimeInterval(-0.001)), on: app.db))
            #expect(try await !SandboxActivityService.hasAdmittedActivity(id: id, at: .testing(boundary), on: app.db))
            try await SandboxActivityService.activate(id: id, sessionID: sessionID, on: app.db)
            let farFuture = ClusterInstant.testing(boundary.addingTimeInterval(86400))
            // A new replica/process reads the same row; wall time never clears an active lease.
            #expect(try await SandboxActivityService.hasAdmittedActivity(id: id, at: farFuture, on: app.db))
            try await SandboxActivityService.endFromAgent(sessionID: sessionID, agentKey: "wrong-agent", on: app.db)
            #expect(try await SandboxActivityService.hasAdmittedActivity(id: id, at: farFuture, on: app.db))
            try await SandboxActivityService.endFromAgent(
                sessionID: sessionID, agentKey: agent.identity.key, on: app.db)
            #expect(try await !SandboxActivityService.hasAdmittedActivity(id: id, at: farFuture, on: app.db))
            let afterEnd = try #require(await Sandbox.find(id, on: app.db)).lastActiveAt
            try await SandboxActivityService.endFromAgent(
                sessionID: sessionID, agentKey: agent.identity.key, on: app.db)
            #expect(try await Sandbox.find(id, on: app.db)?.lastActiveAt == afterEnd)
            sandbox.desiredStatus = .absent
            try await sandbox.save(on: app.db)
            await #expect(throws: Abort.self) {
                try await SandboxActivityService.admitPending(
                    id: id, sessionID: UUID(), agentID: agentID, agentKey: agent.identity.key, on: app.db)
            }
        }
    }

    @Test(
        "Unmeasured guests and unverified suspension never imply idle",
        arguments: [
            SandboxStatus.running, .starting, .stopping, .unknown, .error, .suspended,
        ])
    func unknownGuestActivityDefersExpiry(status: SandboxStatus) async throws {
        try await withSandboxTestApp { app, _, _, sandbox in
            let id = try sandbox.requireID()
            sandbox.ttlSeconds = 60
            sandbox.createdAt = Date().addingTimeInterval(-120)
            sandbox.lastActiveAt = sandbox.createdAt
            sandbox.status = status
            sandbox.statusChangedAt = Date()
            try await sandbox.save(on: app.db)
            await app.agentMaintenance.sweepExpiredSandboxes()
            #expect(try await !deletionRequested(for: id, on: app.db))
            #expect(try await Sandbox.find(id, on: app.db) != nil)
        }
    }

    @Test("An admission racing a locked delete cannot mint a pending command")
    func deleteWinsAdmissionRace() async throws {
        try await withSandboxTestApp { app, _, _, sandbox in
            let agent = try await TestDataBuilder(db: app.db).createAgent(named: "idle-delete-race")
            let id = try sandbox.requireID()
            let agentID = try agent.requireID()
            let key = agent.identity.key
            sandbox.hypervisorId = agentID.uuidString
            sandbox.status = .running
            sandbox.desiredStatus = .running
            sandbox.generation = 1
            sandbox.observedGeneration = 1
            try await sandbox.save(on: app.db)
            let (locked, didLock) = AsyncStream.makeStream(of: Void.self)
            let (release, releaseLock) = AsyncStream.makeStream(of: Void.self)
            let delete = Task {
                try await app.db.transaction { db in
                    let current = try #require(await Sandbox.find(id, on: db))
                    #expect(try await current.lockAndRefresh(on: db))
                    didLock.yield(())
                    didLock.finish()
                    for await _ in release { break }
                    current.desiredStatus = .absent
                    try await current.save(on: db)
                }
            }
            for await _ in locked { break }
            let admission = Task {
                try await SandboxActivityService.admitPending(
                    id: id, sessionID: UUID(), agentID: agentID, agentKey: key, on: app.db)
            }
            releaseLock.yield(())
            releaseLock.finish()
            try await delete.value
            await #expect(throws: Abort.self) { try await admission.value }
            #expect(try await !SandboxActivityService.hasAdmittedActivity(id: id, at: .testing(Date()), on: app.db))
        }
    }

    @Test("Retention refreshes the legacy updated-at fallback under the row lock")
    func staleRetentionCandidateCannotDeleteRefreshedRow() async throws {
        try await withSandboxTestApp { app, _, _, sandbox in
            let id = try sandbox.requireID()
            let now = Date()
            sandbox.status = .exited
            sandbox.statusChangedAt = nil
            try await sandbox.save(on: app.db)
            let sql = try #require(app.db as? any SQLDatabase)
            let old = now.addingTimeInterval(-48 * 3600)
            try await sql.raw("UPDATE sandboxes SET updated_at = \(bind: old) WHERE id = \(bind: id)").run()
            let stale = try #require(await Sandbox.find(id, on: app.db))
            try await SandboxActivityService.touch(id: id, on: app.db)
            await app.agentMaintenance.expireSandbox(
                stale, reason: .retention(hours: 24), at: .testing(now), on: app.db)
            #expect(try await !deletionRequested(for: id, on: app.db))
        }
    }

    // MARK: - TTL expiry

    @Test("The sweep deletes a sandbox past its TTL, recording the deletion end to end")
    func sweepDeletesExpiredSandbox() async throws {
        try await withSandboxTestApp { app, _, _, sandbox in
            let sandboxID = try sandbox.requireID()
            sandbox.ttlSeconds = 60
            try await backdateCreation(sandbox, bySeconds: 120, on: app.db)

            await app.agentMaintenance.sweepExpiredSandboxes()

            try await pollSandboxDeleted(sandboxID, on: app.db)

            // The events outlive the row they name — that is what makes an
            // unattended deletion auditable, and what a client polling the
            // delete reads as "done".
            let events = try await deletionEvents(for: sandboxID, on: app.db)
            let requested = try #require(events.requested)
            #expect(requested.mutation == .delete)
            #expect(requested.actorType == .system)
            #expect(events.completed?.mutation == .delete)
        }
    }

    @Test("The sweep leaves a sandbox still inside its TTL alone")
    func sweepKeepsUnexpiredSandbox() async throws {
        try await withSandboxTestApp { app, _, _, sandbox in
            let sandboxID = try sandbox.requireID()
            sandbox.ttlSeconds = 3600
            try await backdateCreation(sandbox, bySeconds: 60, on: app.db)

            await app.agentMaintenance.sweepExpiredSandboxes()

            let refreshed = try #require(await Sandbox.find(sandboxID, on: app.db))
            #expect(refreshed.desiredStatus == .stopped)
            #expect(try await deletionRequested(for: sandboxID, on: app.db) == false)
        }
    }

    @Test("A sandbox with no TTL never expires, however old it is")
    func sweepIgnoresSandboxWithoutTTL() async throws {
        try await withSandboxTestApp { app, _, _, sandbox in
            let sandboxID = try sandbox.requireID()
            try await backdateCreation(sandbox, bySeconds: 86400 * 30, on: app.db)

            await app.agentMaintenance.sweepExpiredSandboxes()

            let survivor = try await Sandbox.find(sandboxID, on: app.db)
            #expect(survivor != nil)
            #expect(try await deletionRequested(for: sandboxID, on: app.db) == false)
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
                let window = TimeInterval(AgentMaintenanceLoop.defaultSandboxRetentionHours) * 3600
                sandbox.setStatus(.exited, at: Date().addingTimeInterval(-window - 60))
                try await sandbox.save(on: app.db)
            }

            await app.agentMaintenance.sweepExpiredSandboxes()

            let source = try #require(await Sandbox.find(sandboxID, on: app.db))
            #expect(source.desiredStatus != .absent)
            #expect(try await SandboxSnapshot.find(snapshot.requireID(), on: app.db) != nil)
            #expect(try await Sandbox.find(fork.requireID(), on: app.db) != nil)
            #expect(try await deletionRequested(for: sandboxID, on: app.db) == false)
        }
    }

    // MARK: - Retention

    @Test("Terminal sandboxes are reaped once the retention window closes", arguments: [SandboxStatus.exited, .error])
    func sweepReapsTerminalSandboxPastRetention(status: SandboxStatus) async throws {
        try await withSandboxTestApp { app, _, _, sandbox in
            let sandboxID = try sandbox.requireID()
            let window = TimeInterval(AgentMaintenanceLoop.defaultSandboxRetentionHours) * 3600
            sandbox.setStatus(status, at: Date().addingTimeInterval(-window - 60))
            sandbox.exitCode = 0
            try await sandbox.save(on: app.db)

            await app.agentMaintenance.sweepExpiredSandboxes()

            try await pollSandboxDeleted(sandboxID, on: app.db)
            let events = try await deletionEvents(for: sandboxID, on: app.db)
            #expect(events.requested?.mutation == .delete)
            #expect(events.completed?.mutation == .delete)
        }
    }

    @Test("A recently exited sandbox keeps its terminal record for inspection")
    func sweepKeepsRecentTerminalSandbox() async throws {
        try await withSandboxTestApp { app, _, _, sandbox in
            let sandboxID = try sandbox.requireID()
            sandbox.setStatus(.exited, at: Date().addingTimeInterval(-3600))
            sandbox.exitCode = 137
            try await sandbox.save(on: app.db)

            await app.agentMaintenance.sweepExpiredSandboxes()

            // The whole point of the retention window: status and exit code
            // stay readable after the workload is gone.
            let refreshed = try #require(await Sandbox.find(sandboxID, on: app.db))
            #expect(refreshed.status == .exited)
            #expect(refreshed.exitCode == 137)
            #expect(refreshed.desiredStatus != .absent)
        }
    }

    @Test("A terminal sandbox with no status timestamp is aged off updatedAt")
    func sweepAgesTerminalSandboxOffUpdatedAtWhenStatusTimestampIsMissing() async throws {
        try await withSandboxTestApp { app, _, _, sandbox in
            let sandboxID = try sandbox.requireID()
            sandbox.setStatus(.exited)
            sandbox.exitCode = 0
            try await sandbox.save(on: app.db)

            // Rows predating `status_changed_at` carry NULL. The retention
            // window is a SQL predicate now, so this fallback branch is what
            // keeps those rows from being retained forever.
            let sql = try #require(app.db as? any SQLDatabase)
            let window = TimeInterval(AgentMaintenanceLoop.defaultSandboxRetentionHours) * 3600
            let past = Date().addingTimeInterval(-window - 60)
            try await sql.raw(
                """
                UPDATE sandboxes SET status_changed_at = NULL, updated_at = \(bind: past)
                WHERE id = \(bind: sandboxID)
                """
            ).run()

            await app.agentMaintenance.sweepExpiredSandboxes()

            try await pollSandboxDeleted(sandboxID, on: app.db)
        }
    }

    @Test("A running sandbox is never reaped by retention, however old")
    func sweepKeepsOldRunningSandbox() async throws {
        try await withSandboxTestApp { app, _, _, sandbox in
            let sandboxID = try sandbox.requireID()
            sandbox.setStatus(.running, at: Date().addingTimeInterval(-86400 * 30))
            try await sandbox.save(on: app.db)

            await app.agentMaintenance.sweepExpiredSandboxes()

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

            await app.agentMaintenance.sweepExpiredSandboxes()
            try await pollSandboxDeleted(sandboxID, on: app.db)

            let released = try #require(await ResourceQuota.find(quota.id, on: app.db))
            #expect(released.sandboxCount == 0)
            #expect(released.reservedVCPUs == 0)
            #expect(released.reservedMemory == 0)
        }
    }

    // MARK: - Coordination

    @Test("large replica skew fences sandbox deletion")
    func sweepFencesDeletionUnderLargeClockOffset() async throws {
        try await withSandboxTestApp { app, _, _, sandbox in
            let sandboxID = try sandbox.requireID()
            sandbox.ttlSeconds = 60
            try await backdateCreation(sandbox, bySeconds: 120, on: app.db)
            let databaseNow = try await ClusterClock.read(on: app.db)
            let skewed = ClusterInstant.testing(
                databaseNow.date,
                localClockOffsetSeconds:
                    ClusterClock.destructiveSweepOffsetLimitSeconds + 1)

            await app.agentMaintenance.sweepExpiredSandboxes(at: skewed)

            #expect(try await Sandbox.find(sandboxID, on: app.db) != nil)
            #expect(try await deletionRequested(for: sandboxID, on: app.db) == false)
        }
    }

    @Test("The expiry sweep is a cluster singleton")
    func sweepRespectsSingletonLock() async throws {
        try await withSandboxTestApp { app, _, _, sandbox in
            let sandboxID = try sandbox.requireID()
            sandbox.ttlSeconds = 60
            try await backdateCreation(sandbox, bySeconds: 120, on: app.db)

            // Stand in for another replica's in-flight pass.
            let acquired = await app.coordination.acquireSweepLock("sandbox_expiry")
            #expect(acquired)

            await app.agentMaintenance.sweepExpiredSandboxes()

            let survivor = try await Sandbox.find(sandboxID, on: app.db)
            #expect(survivor != nil)
            #expect(try await deletionRequested(for: sandboxID, on: app.db) == false)
        }
    }

    @Test("Idle expiry waits for an in-flight snapshot operation")
    func sweepDefersAnInFlightSnapshot() async throws {
        try await withSandboxTestApp { app, user, _, sandbox in
            let sandboxID = try sandbox.requireID()
            sandbox.ttlSeconds = 60
            try await backdateCreation(sandbox, bySeconds: 120, on: app.db)

            // Snapshot creation is authoritative in-flight activity even
            // though it has its own generation and resource row.
            let snapshot = SandboxSnapshot(
                name: "in-flight",
                sandboxID: sandboxID,
                projectID: sandbox.$project.id,
                environment: sandbox.environment,
                agentId: nil,
                createdByID: try user.requireID())
            try await snapshot.save(on: app.db)

            await app.agentMaintenance.sweepExpiredSandboxes()

            #expect(try await Sandbox.find(sandboxID, on: app.db) != nil)
            #expect(try await !deletionRequested(for: sandboxID, on: app.db))
            snapshot.status = .ready
            try await snapshot.save(on: app.db)
            // Drive the candidate boundary directly; the cluster sweep lock
            // deliberately prevents a second immediate maintenance pass.
            await app.agentMaintenance.expireSandbox(
                sandbox, reason: .ttl(seconds: 60), at: .testing(Date()), on: app.db)
            try await pollSandboxDeleted(sandboxID, on: app.db)
            let events = try await deletionEvents(for: sandboxID, on: app.db)
            #expect(events.requested?.actorType == .system)
        }
    }
    @Test("Automatic fence owns quota/generation and new admitted activity revokes it durably")
    func automaticAdmissionAndCancellation() async throws {
        try await withSandboxTestApp { app, _, _, sandbox in
            let id = try sandbox.requireID()
            let agent = try await TestDataBuilder(db: app.db).createAgent(named: "idle-fence")
            let owner = try agent.requireID()
            let inventory = UUID()
            try await InventorySessionFence.replace(inventory, agentID: owner, on: app.db)
            sandbox.hypervisorId = owner.uuidString
            sandbox.status = .running; sandbox.desiredStatus = .running
            sandbox.generation = 7; sandbox.observedGeneration = 7
            sandbox.suspensionStorageEstimateBytes = 1024
            try await sandbox.save(on: app.db)
            var policy = SandboxIdlePolicy(); policy.enabled = true; policy.idleSeconds = 0.000001
            let incarnation = UUID(), connection = UUID(), residency = UUID(), monitor = UUID()
            let resolvedPolicy = policy
            @Sendable func report(_ sequence: UInt64, revision: Int64 = 0) -> SandboxIdleActivityReport {
                let guest = SandboxGuestIdleActivity(
                    sandboxId: id.uuidString, nonce: "fixture", probeId: UUID(),
                    monitorIncarnation: monitor, sampleSequence: sequence, activityEpoch: 1,
                    quietForMilliseconds: 400_000, coverage: .complete, trusted: true,
                    activeExecSessionIds: [], anonymousExecCount: 0, pendingExecCount: 0,
                    workloadCpuMicroseconds: 0, workloadReadBytes: 0, workloadWriteBytes: 0,
                    externalSocketCount: 0, nicCount: 0)
                return SandboxIdleActivityReport(
                    agentIncarnation: incarnation, connectionEpoch: connection,
                    residencyEpoch: residency, sequence: sequence, generation: 7, activityEpoch: 1,
                    evidenceAgeMilliseconds: 0, residentForMilliseconds: 400_000, guest: guest,
                    activeExecSessionIds: [], pendingCommandCount: 0, snapshotOrRestoreInProgress: false,
                    idleFenceSupported: true, hostQuietMilliseconds: 400_000, policy: resolvedPolicy,
                    hostPendingCommandCount: 0, controlPlaneActivityRevision: revision)
            }
            try await app.db.transaction { db in
                _ = try await SandboxActivityService.locked(id: id, on: db)
                let now = try await ClusterClock.read(on: db)
                try await SandboxIdleFenceService.observe(report(1), sandbox: sandbox, at: now, on: db)
                try await SandboxIdleFenceService.observe(report(2), sandbox: sandbox, at: now, on: db)
            }
            let started = UUID(), undispatched = UUID(), logQuery = UUID()
            for session in [started, undispatched] {
                _ = try await SandboxActivityService.admitPending(
                    id: id, sessionID: session,
                    agentID: owner, agentKey: agent.identity.key, on: app.db)
                try await SandboxActivityService.activate(id: id, sessionID: session, on: app.db)
            }
            try await SandboxActivityService.startedFromAgent(
                sessionID: started, agentKey: agent.identity.key, on: app.db)
            try await SandboxActivityService.admitLogQuery(id: id, queryID: logQuery, on: app.db)
            let acknowledgedRevision = try #require(try await SandboxIdleFenceService.state(id: id, on: app.db))
                .activity_revision
            try await app.db.transaction { db in
                _ = try await SandboxActivityService.locked(id: id, on: db)
                let now = try await ClusterClock.read(on: db)
                // Empty probes collected before dispatch/started admission may
                // not release a newly active command's durable claim.
                try await SandboxIdleFenceService.observe(report(3), sandbox: sandbox, at: now, on: db)
            }
            let sql = try #require(app.db as? any SQLDatabase)
            struct LeaseCount: Decodable { let count: Int }
            #expect(
                try await sql.raw(
                    "SELECT count(*)::int AS count FROM sandbox_activity_leases WHERE sandbox_id = \(bind: id)"
                ).first(decoding: LeaseCount.self)?.count == 3)
            try await app.db.transaction { db in
                _ = try await SandboxActivityService.locked(id: id, on: db)
                let now = try await ClusterClock.read(on: db)
                try await SandboxIdleFenceService.observe(
                    report(4, revision: acknowledgedRevision), sandbox: sandbox, at: now, on: db)
                try await SandboxIdleFenceService.observe(
                    report(5, revision: acknowledgedRevision), sandbox: sandbox, at: now, on: db)
            }
            // Two current-source proofs reconcile only the guest-started lease;
            // a still-dispatching command and CP log query remain protected.
            #expect(
                try await sql.raw(
                    "SELECT count(*)::int AS count FROM sandbox_activity_leases WHERE sandbox_id = \(bind: id)"
                ).first(decoding: LeaseCount.self)?.count == 2)
            try await SandboxActivityService.endFromAgent(
                sessionID: undispatched, agentKey: agent.identity.key, on: app.db)
            try await SandboxActivityService.end(id: id, sessionID: logQuery, on: app.db)
            let idleRevision = try #require(try await SandboxIdleFenceService.state(id: id, on: app.db))
                .activity_revision
            try await app.db.transaction { db in
                _ = try await SandboxActivityService.locked(id: id, on: db)
                let now = try await ClusterClock.read(on: db)
                try await SandboxIdleFenceService.observe(
                    report(6, revision: idleRevision), sandbox: sandbox, at: now, on: db)
                try await SandboxIdleFenceService.observe(
                    report(7, revision: idleRevision), sandbox: sandbox, at: now, on: db)
            }
            // Default CP activation is off even when the root agent opted in.
            #expect(!app.controlPlaneConfiguration.bool(.sandboxIdleSuspendEnabled))
            try await SandboxIdleFenceService.nominate(sandbox, app: app, at: try await ClusterClock.read(on: app.db))
            #expect(try await SandboxIdleFenceService.state(id: id, on: app.db)?.decodedFence == nil)
            var env = ProcessInfo.processInfo.environment
            env["SANDBOX_IDLE_SUSPEND_ENABLED"] = "true"
            app.controlPlaneConfiguration = try await .load(environmentVariables: env, for: .testing)
            let mutation = ResourceMutation(agentDispatch: FakeAgentDispatch(), logger: app.logger)
            try await SandboxIdleFenceService.nominate(
                sandbox, app: app,
                at: try await ClusterClock.read(on: app.db), mutation: mutation)
            let fence = try #require(try await SandboxIdleFenceService.state(id: id, on: app.db)?.decodedFence)
            #expect(fence.generation == 8)
            #expect(sandbox.suspensionStorageBytes == 1024)
            try await SandboxIdleFenceService.validate(id: id, owner: owner.uuidString, fence: fence, on: app.db)
            await #expect(throws: Abort.self) {
                try await SandboxIdleFenceService.validate(id: id, owner: UUID().uuidString, fence: fence, on: app.db)
            }
            let idleAnchor = sandbox.lastActiveAt
            let suspended = ObservedSandboxState(
                sandboxId: id, status: .suspended, observedGeneration: fence.generation,
                suspension: SandboxSuspensionEvidence(
                    checkpointId: UUID(), generation: fence.generation,
                    storageBytes: 900, vmmDestroyed: true, verified: true))
            try await app.db.transaction { db in
                _ = try await SandboxActivityService.locked(id: id, on: db)
                try await app.observedStateApplier.applyObservedSandboxState(
                    sandbox: sandbox,
                    observed: suspended, at: try await ClusterClock.read(on: db), on: db)
            }
            // Internal reclamation preserves the user's activity-based TTL.
            let reclaimed = try #require(try await Sandbox.find(id, on: app.db))
            #expect(reclaimed.lastActiveAt == idleAnchor && reclaimed.hasQuiescentIdleExpiryState)
            #expect(!reclaimed.suspensionComputeReserved && reclaimed.suspensionStorageBytes == 900)
            let issuedState = try #require(try await SandboxIdleFenceService.state(id: id, on: app.db))
            try await app.db.transaction { db in
                _ = try await SandboxActivityService.locked(id: id, on: db)
                // Replayed evidence never refreshes receipt time or revokes a
                // current fence; it is not a new observation.
                try await SandboxIdleFenceService.observe(
                    report(2), sandbox: sandbox,
                    at: try await ClusterClock.read(on: db), on: db)
            }
            #expect(try await SandboxIdleFenceService.state(id: id, on: app.db)?.received_at == issuedState.received_at)
            let wrongToken = SandboxAutomaticSuspensionFence(
                operationId: fence.operationId,
                generation: fence.generation, activityRevision: fence.activityRevision,
                admissionToken: UUID(), guestProtocolVersion: 5)
            await #expect(throws: Abort.self) {
                try await SandboxIdleFenceService.validate(
                    id: id, owner: owner.uuidString, fence: wrongToken, on: app.db)
            }
            // Source replacement revokes persisted ownership independently of
            // an old replica or agent's cached activity revision.
            try await InventorySessionFence.replace(UUID(), agentID: owner, on: app.db)
            #expect(try await SandboxIdleFenceService.state(id: id, on: app.db)?.valid == false)
            #expect(try await SandboxIdleFenceService.state(id: id, on: app.db)?.decodedReport == nil)
            await #expect(throws: Abort.self) {
                try await SandboxIdleFenceService.validate(id: id, owner: owner.uuidString, fence: fence, on: app.db)
            }
            // A fresh service/replica reads the persisted claim; no local cache.
            try await SandboxActivityService.touch(id: id, on: app.db)
            let awakened = try #require(try await Sandbox.find(id, on: app.db))
            #expect(awakened.desiredStatus == .running && awakened.generation == 9)
            await #expect(throws: Abort.self) {
                try await SandboxIdleFenceService.validate(id: id, owner: owner.uuidString, fence: fence, on: app.db)
            }
        }
    }

    @Test("An in-flight user log query protects TTL across replica restart")
    func logQueryAdmissionSurvivesRestart() async throws {
        try await withSandboxTestApp { app, _, _, sandbox in
            let id = try sandbox.requireID(), queryID = UUID()
            try await SandboxActivityService.admitLogQuery(id: id, queryID: queryID, on: app.db)
            let farFuture = ClusterInstant.testing(Date().addingTimeInterval(86400))
            #expect(try await SandboxActivityService.hasAdmittedActivity(id: id, at: farFuture, on: app.db))
            try await SandboxActivityService.endFromAgent(sessionID: queryID, agentKey: "guest", on: app.db)
            #expect(try await SandboxActivityService.hasAdmittedActivity(id: id, at: farFuture, on: app.db))
            try await SandboxActivityService.end(id: id, sessionID: queryID, on: app.db)
            #expect(try await !SandboxActivityService.hasAdmittedActivity(id: id, at: farFuture, on: app.db))
            let anchor = try #require(try await Sandbox.find(id, on: app.db)).lastActiveAt
            try await SandboxActivityService.end(id: id, sessionID: queryID, on: app.db)
            #expect(try await Sandbox.find(id, on: app.db)?.lastActiveAt == anchor)
        }
    }

}
