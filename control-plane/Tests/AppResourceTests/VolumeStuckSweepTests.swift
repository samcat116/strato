import ControlPlanePostgres
import Testing
import Vapor
import VaporTesting
import StratoShared
import AppTestSupport
@testable import App

/// The volume backstop after STR-148.
///
/// This suite used to test a status-and-timestamp sweep that guessed which
/// transitional status had been abandoned and how long each one deserved,
/// because volumes carried no operation row to judge against. Both halves are
/// gone: a volume now stamps a `convergence_deadline` on every accepted
/// mutation, and `sweepStuckConvergence` — the same lock-free, exactly-once
/// pass VMs and sandboxes use — degrades it past that deadline.
@Suite("Volume Stuck Sweep Tests", .serialized)
final class VolumeStuckSweepTests {

    private func withVolumeTestApp(
        _ test: (Application, User, Project) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)

            let builder = TestDataBuilder(db: app.testPostgres)
            let user = try await builder.createUser(
                username: "voluser",
                email: "vol@example.com",
                displayName: "Volume User",
                isSystemAdmin: false
            )
            let org = try await builder.createOrganization(name: "Vol Org")
            let project = try await builder.createProject(
                name: "Vol Project",
                description: "Project for volume sweep tests",
                organization: org
            )

            try await test(app, user, project)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    /// Persists a volume with an outstanding mutation whose deadline is
    /// `overdueBy` seconds in the past.
    @discardableResult
    private func makeVolume(
        deadlineOverdueBy overdueBy: TimeInterval?,
        status: VolumeStatus = .creating,
        desired: DesiredVolumeStatus = .present,
        generation: Int64 = 1,
        observedGeneration: Int64 = 0,
        vmID: UUID? = nil,
        on app: Application,
        user: User,
        project: Project
    ) async throws -> Volume {
        let volume = Volume(
            name: "vol-\(UUID().uuidString.prefix(8))",
            description: "",
            projectID: project.id!, environment: "development",
            size: 10 * 1024 * 1024 * 1024,
            status: status,
            desiredStatus: desired,
            generation: generation,
            observedGeneration: observedGeneration,
            convergenceDeadline: overdueBy.map { Date().addingTimeInterval(-$0) },
            createdByID: user.id!,
            vmID: vmID,
            deviceName: vmID == nil ? nil : "disk0"
        )
        try await volume.save(on: app.testPostgres)
        return volume
    }

    // MARK: - Degrading overdue volumes

    @Test("A volume past its convergence deadline is degraded with a reason")
    func overdueVolumeIsDegraded() async throws {
        try await withVolumeTestApp { app, user, project in
            let volume = try await makeVolume(
                deadlineOverdueBy: 60, on: app, user: user, project: project)

            await app.agentService.sweepStuckConvergence()

            let swept = try await #require(try await Volume.find(volume.id, on: app.testPostgres))
            #expect(swept.conditions.degraded != nil)
            #expect(swept.errorMessage?.isEmpty == false)
            // Claimed: the deadline is cleared, so a second pass finds nothing.
            #expect(swept.convergenceDeadline == nil)
        }
    }

    @Test("A volume inside its deadline is left alone")
    func liveVolumeIsUntouched() async throws {
        try await withVolumeTestApp { app, user, project in
            let volume = try await makeVolume(
                deadlineOverdueBy: -300, on: app, user: user, project: project)

            await app.agentService.sweepStuckConvergence()

            let swept = try await #require(try await Volume.find(volume.id, on: app.testPostgres))
            #expect(swept.conditions.degraded == nil)
            #expect(swept.convergenceDeadline != nil)
        }
    }

    /// Nil means "nothing outstanding". A resting volume that has never had a
    /// mutation — or whose last one converged — is not the sweep's business,
    /// and the SQL `NULL` comparison is what keeps it out of the query.
    @Test("A volume with no deadline is never swept")
    func volumeWithoutDeadlineIsNeverSwept() async throws {
        try await withVolumeTestApp { app, user, project in
            let volume = try await makeVolume(
                deadlineOverdueBy: nil, status: .available, observedGeneration: 1,
                on: app, user: user, project: project)

            await app.agentService.sweepStuckConvergence()

            let swept = try await #require(try await Volume.find(volume.id, on: app.testPostgres))
            #expect(swept.conditions.degraded == nil)
            #expect(swept.status == .available)
        }
    }

    /// The deadline is a backstop, not a verdict: a volume that converged
    /// between the query and the claim is left alone, since the claim has
    /// already dropped the deadline, which is all that was owed.
    @Test("A volume that converged before the claim is not degraded")
    func convergedVolumeIsNotDegraded() async throws {
        try await withVolumeTestApp { app, user, project in
            let volume = try await makeVolume(
                deadlineOverdueBy: 60, status: .available, generation: 1, observedGeneration: 1,
                on: app, user: user, project: project)

            await app.agentService.sweepStuckConvergence()

            let swept = try await #require(try await Volume.find(volume.id, on: app.testPostgres))
            #expect(swept.conditions.degraded == nil)
            #expect(swept.convergenceDeadline == nil)
        }
    }

    /// A terminating volume never reports converged — it is on its way out, not
    /// converging on anything — so a delete blocked on a finalizer falls
    /// through and degrades, which is what a stuck delete should look like.
    @Test("A stuck delete degrades rather than reading as converged")
    func stuckDeleteDegrades() async throws {
        try await withVolumeTestApp { app, user, project in
            let volume = try await makeVolume(
                deadlineOverdueBy: 60, status: .available, desired: .absent,
                generation: 2, observedGeneration: 2, on: app, user: user, project: project
            ).replacing(finalizers: [ResourceFinalizer.agentAbsent.rawValue])
            try await volume.save(on: app.testPostgres)

            await app.agentService.sweepStuckConvergence()

            let swept = try await #require(try await Volume.find(volume.id, on: app.testPostgres))
            #expect(swept.conditions.degraded != nil)
            #expect(!swept.conditions.converged)
            // The delete's intent survives: reverting it would resurrect a
            // volume the user deleted.
            #expect(swept.desiredStatus == .absent)
        }
    }

    /// `degradeOverdue` skips a converged resource. Since STR-191 a volume
    /// already degraded at its current generation is no longer converged, so it
    /// falls through — and lands on `recordFailure`'s own
    /// `failedGeneration == generation` guard, which is the same condition. The
    /// deadline claim still happens; nothing else does.
    @Test("A volume already degraded at its current generation is not degraded twice")
    func alreadyDegradedVolumeIsNotDegradedAgain() async throws {
        try await withVolumeTestApp { app, user, project in
            let volume = try await makeVolume(
                deadlineOverdueBy: 60, status: .available, generation: 3, observedGeneration: 3,
                on: app, user: user, project: project
            ).replacing(
                errorMessage: "resize failed: no space left on device", failedGeneration: 3)
            try await volume.save(on: app.testPostgres)

            await app.agentService.sweepStuckConvergence()

            let swept = try await #require(try await Volume.find(volume.id, on: app.testPostgres))
            // The agent's reason survives — not overwritten with "Timed out…".
            #expect(swept.errorMessage == "resize failed: no space left on device")
            #expect(swept.conditions.degraded?.sinceGeneration == 3)
            #expect(swept.convergenceDeadline == nil)
        }
    }

    // MARK: - Orphaned terminating volumes

    /// The other backstop: a terminating volume whose finalizers all cleared
    /// but whose row survived — a crash between the last clear and the reap.
    @Test("A terminating volume with no finalizers left is reaped")
    func orphanedTerminatingVolumeIsReaped() async throws {
        try await withVolumeTestApp { app, user, project in
            let volume = try await makeVolume(
                deadlineOverdueBy: nil, status: .available, desired: .absent,
                generation: 2, observedGeneration: 2, on: app, user: user, project: project)
            let volumeID = try #require(volume.id)

            let sql = try #require(Optional(app.testPostgres))
            let past = Date().addingTimeInterval(-3600)
            try await sql.raw("UPDATE volumes SET updated_at = \(bind: past) WHERE id = \(bind: volumeID)")
                .run()

            await app.agentService.sweepOrphanedTerminatingResources()

            #expect(try await Volume.find(volumeID, on: app.testPostgres) == nil)
        }
    }

    @Test("A terminating volume still holding a finalizer survives the sweep")
    func heldTerminatingVolumeSurvives() async throws {
        try await withVolumeTestApp { app, user, project in
            let volume = try await makeVolume(
                deadlineOverdueBy: nil, status: .available, desired: .absent,
                generation: 2, observedGeneration: 2, on: app, user: user, project: project
            ).replacing(finalizers: [ResourceFinalizer.agentAbsent.rawValue])
            let volumeID = try #require(volume.id)
            try await volume.save(on: app.testPostgres)
            try await placeVolume(volume, on: UUID().uuidString, using: app.testPostgres)

            let sql = try #require(Optional(app.testPostgres))
            let past = Date().addingTimeInterval(-3600)
            try await sql.raw("UPDATE volumes SET updated_at = \(bind: past) WHERE id = \(bind: volumeID)")
                .run()

            await app.agentService.sweepOrphanedTerminatingResources()

            #expect(try await Volume.find(volumeID, on: app.testPostgres) != nil)
        }
    }
}
