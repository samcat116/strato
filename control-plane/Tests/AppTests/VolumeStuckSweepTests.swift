import Testing
import Vapor
import Fluent
import SQLKit
import VaporTesting
import StratoShared
@testable import App

/// Tests for the volume stuck-operation backstop (issue #644). Volumes are
/// mutated through the same async-agent-RPC pattern as VMs and sandboxes but
/// carry no `ResourceOperation` row, so a control-plane crash mid-operation
/// could strand a volume in a transitional status forever. `sweepStuckOperations()`
/// now recovers them: transitional volumes past their per-status budget return
/// to a resting state.
@Suite("Volume Stuck Sweep Tests", .serialized)
final class VolumeStuckSweepTests {

    private func withVolumeTestApp(
        _ test: (Application, User, Project) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
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

    /// Persists a volume in `status` and backdates its `updated_at` by
    /// `ageSeconds`. `updated_at` is a Fluent-managed `on: .update` timestamp —
    /// every `save` resets it to now — so the sweep's clock can only be moved
    /// with a direct SQL write after the row exists.
    @discardableResult
    private func makeVolume(
        status: VolumeStatus,
        ageSeconds: TimeInterval,
        vmID: UUID? = nil,
        on app: Application,
        user: User,
        project: Project
    ) async throws -> Volume {
        let volume = Volume(
            name: "vol-\(status.rawValue)",
            description: "",
            projectID: project.id!,
            size: 10 * 1024 * 1024 * 1024,
            status: status,
            createdByID: user.id!
        )
        volume.$vm.id = vmID
        try await volume.save(on: app.db)

        let sql = try #require(app.db as? any SQLDatabase)
        let past = Date().addingTimeInterval(-ageSeconds)
        try await sql.raw("UPDATE volumes SET updated_at = \(bind: past) WHERE id = \(bind: volume.id!)")
            .run()
        return volume
    }

    // MARK: - Recovery of stuck transitional volumes

    @Test("A stuck .creating volume past budget is recovered to .error")
    func sweepRecoversStuckCreate() async throws {
        try await withVolumeTestApp { app, user, project in
            let volume = try await makeVolume(
                status: .creating, ageSeconds: 1000, on: app, user: user, project: project)

            await app.agentService.sweepStuckOperations()

            let swept = try await Volume.find(volume.id, on: app.db)
            #expect(swept?.status == .error)
            #expect(swept?.errorMessage?.isEmpty == false)
        }
    }

    @Test(
        "A stuck volume in an unknown-outcome transitional state is recovered to .error",
        arguments: [VolumeStatus.attaching, .detaching, .resizing]
    )
    func sweepRecoversUnknownOutcomeStates(status: VolumeStatus) async throws {
        try await withVolumeTestApp { app, user, project in
            let volume = try await makeVolume(
                status: status, ageSeconds: 1000, on: app, user: user, project: project)

            await app.agentService.sweepStuckOperations()

            let swept = try await Volume.find(volume.id, on: app.db)
            #expect(swept?.status == .error)
        }
    }

    @Test("A stuck detached .snapshotting volume is recovered to .available, not errored")
    func sweepReturnsSnapshottingSourceToResting() async throws {
        try await withVolumeTestApp { app, user, project in
            // The source volume's data is untouched by an interrupted snapshot,
            // so it must not be errored.
            let volume = try await makeVolume(
                status: .snapshotting, ageSeconds: 1000, on: app, user: user, project: project)

            await app.agentService.sweepStuckOperations()

            let swept = try await Volume.find(volume.id, on: app.db)
            #expect(swept?.status == .available)
            #expect(swept?.errorMessage == nil)
        }
    }

    @Test("A stuck attached .cloning source is recovered to .attached")
    func sweepReturnsCloningSourceToAttached() async throws {
        try await withVolumeTestApp { app, user, project in
            let builder = TestDataBuilder(db: app.db)
            let vm = try await builder.createVM(name: "clone-src-vm", project: project)

            let volume = try await makeVolume(
                status: .cloning, ageSeconds: 1000, vmID: vm.id, on: app, user: user, project: project)

            await app.agentService.sweepStuckOperations()

            let swept = try await Volume.find(volume.id, on: app.db)
            #expect(swept?.status == .attached)
        }
    }

    // MARK: - The sweep leaves live and resting volumes alone

    @Test("A fresh transitional volume within budget is left alone")
    func sweepIgnoresFreshTransitional() async throws {
        try await withVolumeTestApp { app, user, project in
            // 60s is well under every transitional budget, so a create still in
            // flight on a live replica must not be clobbered.
            let volume = try await makeVolume(
                status: .creating, ageSeconds: 60, on: app, user: user, project: project)

            await app.agentService.sweepStuckOperations()

            let swept = try await Volume.find(volume.id, on: app.db)
            #expect(swept?.status == .creating)
        }
    }

    @Test("A stuck .deleting volume is left to the retryable-delete path")
    func sweepIgnoresDeleting() async throws {
        try await withVolumeTestApp { app, user, project in
            let volume = try await makeVolume(
                status: .deleting, ageSeconds: 1000, on: app, user: user, project: project)

            await app.agentService.sweepStuckOperations()

            let swept = try await Volume.find(volume.id, on: app.db)
            #expect(swept?.status == .deleting)
        }
    }
}
