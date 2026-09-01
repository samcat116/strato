import AppTestSupport
import Fluent
import SQLKit
import StratoShared
import Testing
import Vapor
import VaporTesting

@testable import App

/// Snapshot artifacts on the reconciliation loop, end to end (ADR 0001 stage 8,
/// STR-150).
///
/// The properties pinned here are the arguments the conversion rests on rather
/// than things the type system enforces:
///
/// * the captured metadata arrives on the **observed report**, which is re-sent
///   on every heartbeat — the whole reason it stopped riding a one-shot RPC
///   reply that a dropped socket could lose;
/// * an artifact's row is removed only when its agent stops listing it, so a
///   delete can be re-driven indefinitely without orphaning bytes;
/// * a report that says *nothing* about snapshots deletes nothing;
/// * retention exists at all, and goes down the same path an operator's
///   `DELETE` takes.
@Suite("Snapshot Convergence Tests", .serialized)
final class SnapshotConvergenceTests {

    private func withSnapshotApp(
        _ test: (Application, TestDataBuilder, User, Project) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "snapconv",
                email: "snapconv@example.com",
                displayName: "Snapshot Convergence User",
                isSystemAdmin: true
            )
            let org = try await builder.createOrganization(name: "Snap Org")
            let project = try await builder.createProject(
                name: "Snap Project", description: "Snapshot convergence", organization: org)

            try await test(app, builder, user, project)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    private func registerAgent(
        app: Application, named name: String, protocolVersion: Int = WireProtocol.currentVersion
    ) async throws -> String {
        try await TestDataBuilder(db: app.db).registerAgent(
            on: app,
            named: name,
            hostname: "\(name).test",
            hypervisors: [
                HypervisorSupport(
                    type: .qemu, available: true, accelerated: true, capabilities: .qemu),
                HypervisorSupport(
                    type: .firecracker, available: true, accelerated: true,
                    capabilities: .firecracker),
            ],
            protocolVersion: protocolVersion,
            sandboxCapable: true)
    }

    @discardableResult
    private func makeCheckpoint(
        on app: Application,
        user: User,
        project: Project,
        vm: VM,
        agentId: String?,
        name: String = "cp",
        desired: DesiredSnapshotStatus = .present,
        status: VMSnapshotStatus = .ready,
        generation: Int64 = 1,
        observedGeneration: Int64 = 1,
        expiresAt: Date? = nil
    ) async throws -> VMSnapshot {
        let snapshot = VMSnapshot(
            name: name,
            vmID: try vm.requireID(),
            projectID: try project.requireID(),
            environment: vm.environment,
            agentId: agentId,
            expiresAt: expiresAt,
            createdByID: try user.requireID())
        snapshot.status = status
        snapshot.desiredStatus = desired
        snapshot.generation = generation
        snapshot.observedGeneration = observedGeneration
        snapshot.size = 1 << 30
        try await snapshot.save(on: app.db)
        return snapshot
    }

    private func report(
        agentId: String, snapshots: [ObservedSnapshotState]?
    ) -> ObservedStateReport {
        ObservedStateReport(
            agentId: agentId,
            vms: [],
            resources: AgentResources(
                totalCPU: 16, availableCPU: 16,
                totalMemory: 1 << 34, availableMemory: 1 << 34,
                totalDisk: 1 << 40, availableDisk: 1 << 40
            ),
            snapshots: snapshots
        )
    }

    private func placedVM(
        _ builder: TestDataBuilder, project: Project, agentId: String, name: String = "vm"
    ) async throws -> VM {
        let vm = try await builder.createVM(name: name, project: project)
        vm.hypervisorId = agentId
        vm.setStatus(.running)
        try await vm.save(on: builder.db)
        return vm
    }

    // MARK: - Assembly

    @Test("An artifact rides its agent's sync, kind-tagged and parented")
    func artifactIsAssembledForItsAgent() async throws {
        try await withSnapshotApp { app, builder, user, project in
            let agentId = try await registerAgent(app: app, named: "assemble-agent")
            let vm = try await placedVM(builder, project: project, agentId: agentId)
            let snapshot = try await makeCheckpoint(
                on: app, user: user, project: project, vm: vm, agentId: agentId)

            let message = try await app.desiredStateAssembler.assemble(agentId: agentId)
            let entry = try #require(message.snapshots.first)
            #expect(entry.snapshotId == snapshot.id)
            #expect(entry.kind == .vmCheckpoint)
            #expect(entry.parentId == vm.id)
            #expect(entry.desiredStatus == .present)
            // Neither a path nor a size travels outbound: the agent owns
            // artifact layout and is the only party that can measure what it
            // wrote, so both come back on the report instead.
            #expect(entry.export == nil)
        }
    }

    /// A capture is a create strategy, and a sandbox's carries its mode. It has
    /// to be durable rather than derived from the request, because the entry is
    /// re-assembled on every sync — including ones long after the request that
    /// made it.
    @Test("A sandbox snapshot's capture mode rides every sync")
    func captureModeRidesTheSync() async throws {
        try await withSnapshotApp { app, builder, user, project in
            let agentId = try await registerAgent(app: app, named: "mode-agent")
            let sandbox = try await builder.createSandbox(name: "sb", project: project)
            sandbox.hypervisorId = agentId
            try await sandbox.save(on: app.db)

            let snapshot = SandboxSnapshot(
                name: "stopper",
                sandboxID: try sandbox.requireID(),
                projectID: try project.requireID(),
                environment: sandbox.environment,
                agentId: agentId,
                captureMode: .stop,
                createdByID: try user.requireID())
            try await snapshot.save(on: app.db)

            let message = try await app.desiredStateAssembler.assemble(agentId: agentId)
            let entry = try #require(message.snapshots.first { $0.kind == .sandboxSnapshot })
            #expect(entry.capture?.sandboxMode == .stop)
            // No export desired, so no upload slots — an export is a placement
            // fact the operator has to ask for.
            #expect(entry.export == nil)
        }
    }

    @Test("A desired export puts one upload slot per artifact on the sync")
    func exportPutsUploadSlotsOnTheSync() async throws {
        try await withSnapshotApp { app, builder, user, project in
            let agentId = try await registerAgent(app: app, named: "export-agent")
            let sandbox = try await builder.createSandbox(name: "sb", project: project)
            sandbox.hypervisorId = agentId
            try await sandbox.save(on: app.db)

            let snapshot = SandboxSnapshot(
                name: "exported",
                sandboxID: try sandbox.requireID(),
                projectID: try project.requireID(),
                environment: sandbox.environment,
                agentId: agentId,
                createdByID: try user.requireID())
            snapshot.status = .ready
            snapshot.exportDesired = true
            try await snapshot.save(on: app.db)

            let message = try await app.desiredStateAssembler.assemble(agentId: agentId)
            let entry = try #require(message.snapshots.first { $0.kind == .sandboxSnapshot })
            let export = try #require(entry.export)
            #expect(Set(export.uploads.map(\.kind)) == Set(SandboxSnapshotArtifactKind.allCases))
            // Control-plane-relative paths presented with the agent's SVID, so
            // nothing here expires and the entry is safe to sit in a sync.
            #expect(export.uploads.allSatisfy { $0.uploadURL.hasPrefix("/api/") })
        }
    }

    // MARK: - Observed state

    /// The reason the captured metadata moved onto the report. As an RPC reply
    /// it was delivered once: a socket that dropped mid-flight lost it, and the
    /// old path had to treat that as a protocol error and mark a checkpoint that
    /// in fact existed `.error`.
    @Test("Captured facts arrive on the observed report and settle convergence")
    func capturedFactsArriveOnTheReport() async throws {
        try await withSnapshotApp { app, builder, user, project in
            let agentId = try await registerAgent(app: app, named: "report-agent")
            let vm = try await placedVM(builder, project: project, agentId: agentId)
            let snapshot = try await makeCheckpoint(
                on: app, user: user, project: project, vm: vm, agentId: agentId,
                status: .creating, generation: 1, observedGeneration: 0)

            try await app.observedStateApplier.apply(
                report(
                    agentId: agentId,
                    snapshots: [
                        ObservedSnapshotState(
                            snapshotId: try snapshot.requireID(),
                            kind: .vmCheckpoint,
                            parentId: try vm.requireID(),
                            present: true,
                            facts: ObservedSnapshotFacts(
                                sizeBytes: 4096, architecture: .x86_64, qemuVersion: "9.1.0"),
                            observedGeneration: 1)
                    ]))

            let settled = try #require(await VMSnapshot.find(snapshot.id, on: app.db))
            #expect(settled.status == .ready)
            #expect(settled.size == 4096)
            #expect(settled.qemuVersion == "9.1.0")
            #expect(settled.architecture == CPUArchitecture.x86_64.rawValue)
            #expect(settled.observedGeneration == 1)
            #expect(settled.conditions.converged)
        }
    }

    /// A capture that failed with nothing written is reported with the reason,
    /// so the client is told why instead of waiting out the whole budget.
    @Test("A failed capture degrades the artifact with the agent's reason")
    func failedCaptureDegradesTheArtifact() async throws {
        try await withSnapshotApp { app, builder, user, project in
            let agentId = try await registerAgent(app: app, named: "fail-agent")
            let vm = try await placedVM(builder, project: project, agentId: agentId)
            let snapshot = try await makeCheckpoint(
                on: app, user: user, project: project, vm: vm, agentId: agentId,
                status: .creating, generation: 1, observedGeneration: 0)

            try await app.observedStateApplier.apply(
                report(
                    agentId: agentId,
                    snapshots: [
                        ObservedSnapshotState(
                            snapshotId: try snapshot.requireID(),
                            kind: .vmCheckpoint,
                            parentId: try vm.requireID(),
                            present: false,
                            observedGeneration: 1,
                            lastError: "qemu snapshot-save job failed",
                            failedGeneration: 1)
                    ]))

            let settled = try #require(await VMSnapshot.find(snapshot.id, on: app.db))
            #expect(settled.status == .error)
            let degraded = try #require(settled.conditions.degraded)
            #expect(degraded.reason == "qemu snapshot-save job failed")
            #expect(degraded.sinceGeneration == 1)
        }
    }

    @Test("A stale snapshot failure cannot overwrite a newer deletion")
    func staleFailureCannotOverwriteDelete() async throws {
        try await withSnapshotApp { app, builder, user, project in
            let agentId = try await registerAgent(app: app, named: "stale-snapshot-agent")
            let vm = try await placedVM(builder, project: project, agentId: agentId)
            let snapshot = try await makeCheckpoint(
                on: app, user: user, project: project, vm: vm, agentId: agentId,
                status: .creating, generation: 10, observedGeneration: 9)
            snapshot.convergenceDeadline = Date().addingTimeInterval(120)
            try await snapshot.save(on: app.db)
            let snapshotID = try #require(snapshot.id)
            let stale = try #require(try await VMSnapshot.find(snapshotID, on: app.db))
            let deleteCopy = try #require(try await VMSnapshot.find(snapshotID, on: app.db))

            let accepted = try await app.resourceMutation.accept(
                .delete, on: deleteCopy, actor: .user(try user.requireID()),
                dispatch: .directResolution { _ in false }, on: app.db, app: app
            ) { db in
                try await ResourceFinalizerService.stampForDeletion(deleteCopy, on: db)
                deleteCopy.setDesiredStatus(.absent)
            }
            #expect(accepted.targetGeneration == 11)

            let outcome = try await ResourceConvergence.recordFailure(
                stale, mutation: .create, reason: "obsolete capture failure",
                telemetryReason: "convergence_failed", on: app.db)
            #expect(outcome == .superseded(actualGeneration: 11))

            let stored = try #require(try await VMSnapshot.find(snapshotID, on: app.db))
            #expect(stored.generation == 11)
            #expect(stored.desiredStatus == .absent)
            #expect(stored.convergenceDeadline != nil)
            #expect(stored.errorMessage == nil)
            #expect(stored.failedGeneration == nil)

            await app.backgroundTasks.drain(timeout: .seconds(10))
        }
    }

    /// The delete contract: the row goes when — and only when — the agent's
    /// full list stops mentioning the artifact.
    @Test("Omission from a full report confirms a deletion and reaps the row")
    func omissionConfirmsDeletion() async throws {
        try await withSnapshotApp { app, builder, user, project in
            let agentId = try await registerAgent(app: app, named: "reap-agent")
            let vm = try await placedVM(builder, project: project, agentId: agentId)
            let snapshot = try await makeCheckpoint(
                on: app, user: user, project: project, vm: vm, agentId: agentId,
                desired: .absent)
            snapshot.finalizers = [ResourceFinalizer.agentAbsent.rawValue]
            try await snapshot.save(on: app.db)

            // Still listed: nothing is confirmed, so the row stays.
            try await app.observedStateApplier.apply(
                report(
                    agentId: agentId,
                    snapshots: [
                        ObservedSnapshotState(
                            snapshotId: try snapshot.requireID(),
                            kind: .vmCheckpoint,
                            parentId: try vm.requireID(),
                            present: true,
                            observedGeneration: 1)
                    ]))
            #expect(try await VMSnapshot.find(snapshot.id, on: app.db) != nil)

            // Omitted from a full list: the bytes are gone, so the row is.
            try await app.observedStateApplier.apply(report(agentId: agentId, snapshots: []))
            #expect(try await VMSnapshot.find(snapshot.id, on: app.db) == nil)
        }
    }

    /// The most expensive thing to get wrong in this change. A pre-v33 agent
    /// says nothing about snapshots; reading that silence as an empty inventory
    /// would reap every terminating checkpoint row and error every live one.
    @Test("A report with no snapshots field confirms nothing")
    func nilSnapshotsConfirmsNothing() async throws {
        try await withSnapshotApp { app, builder, user, project in
            let agentId = try await registerAgent(app: app, named: "silent-agent")
            let vm = try await placedVM(builder, project: project, agentId: agentId)
            let terminating = try await makeCheckpoint(
                on: app, user: user, project: project, vm: vm, agentId: agentId,
                name: "terminating", desired: .absent)
            terminating.finalizers = [ResourceFinalizer.agentAbsent.rawValue]
            try await terminating.save(on: app.db)
            let live = try await makeCheckpoint(
                on: app, user: user, project: project, vm: vm, agentId: agentId, name: "live")

            try await app.observedStateApplier.apply(report(agentId: agentId, snapshots: nil))

            #expect(try await VMSnapshot.find(terminating.id, on: app.db) != nil)
            let untouched = try #require(await VMSnapshot.find(live.id, on: app.db))
            #expect(untouched.status == .ready)
        }
    }

    /// An artifact that some agent confirmed and has now lost is an error, not
    /// a deletion — but one that has never been confirmed is simply mid-capture,
    /// and must not be escalated for being absent.
    @Test("A never-confirmed artifact is not escalated for being absent")
    func midCaptureAbsenceIsNotAnError() async throws {
        try await withSnapshotApp { app, builder, user, project in
            let agentId = try await registerAgent(app: app, named: "midflight-agent")
            let vm = try await placedVM(builder, project: project, agentId: agentId)
            let pending = try await makeCheckpoint(
                on: app, user: user, project: project, vm: vm, agentId: agentId,
                name: "pending", status: .creating, generation: 1, observedGeneration: 0)
            let lost = try await makeCheckpoint(
                on: app, user: user, project: project, vm: vm, agentId: agentId, name: "lost")

            try await app.observedStateApplier.apply(report(agentId: agentId, snapshots: []))

            #expect(try await VMSnapshot.find(pending.id, on: app.db)?.status == .creating)
            #expect(try await VMSnapshot.find(lost.id, on: app.db)?.status == .error)
        }
    }

    /// Admission reserves an *estimate*; the agent's report replaces it with the
    /// truth, and the truth can be much larger. This is the check the retired
    /// background create halves ran right after the RPC reply — without it a
    /// project sits over an enabled quota indefinitely while the artifact
    /// converges `ready`, and the only symptom is the *next* create being
    /// refused with nothing naming what consumed the pool.
    @Test("A reported footprint that blows the storage quota deletes the artifact")
    func oversizedFootprintIsDeleted() async throws {
        try await withSnapshotApp { app, builder, user, project in
            let agentId = try await registerAgent(app: app, named: "quota-agent")
            let vm = try await placedVM(builder, project: project, agentId: agentId)
            _ = try await builder.createResourceQuota(
                name: "tiny-storage", maxStorageGB: 1.0, project: project)

            let snapshot = try await makeCheckpoint(
                on: app, user: user, project: project, vm: vm, agentId: agentId,
                status: .creating, generation: 1, observedGeneration: 0)

            // 8 GiB against a 1 GiB pool.
            try await app.observedStateApplier.apply(
                report(
                    agentId: agentId,
                    snapshots: [
                        ObservedSnapshotState(
                            snapshotId: try snapshot.requireID(),
                            kind: .vmCheckpoint,
                            parentId: try vm.requireID(),
                            present: true,
                            facts: ObservedSnapshotFacts(sizeBytes: 8 << 30),
                            observedGeneration: 1)
                    ]))

            let settled = try #require(await VMSnapshot.find(snapshot.id, on: app.db))
            #expect(settled.desiredStatus == .absent)
            // The quota's name reaches the user, which is the whole point of
            // failing rather than tolerating.
            #expect(settled.errorMessage?.contains("tiny-storage") == true)

            // Unattributed teardown is still attributed: the sweep's `system`
            // actor arrangement, reused.
            let event = try #require(
                await ResourceEvent.latest(
                    .requested, resourceKind: .vmCheckpoint, resourceID: try snapshot.requireID(),
                    on: app.db))
            #expect(event.mutation == .delete)
            #expect(event.actorType == .system)
        }
    }

    @Test("A footprint that fits leaves the artifact alone")
    func fittingFootprintIsKept() async throws {
        try await withSnapshotApp { app, builder, user, project in
            let agentId = try await registerAgent(app: app, named: "quota-ok-agent")
            let vm = try await placedVM(builder, project: project, agentId: agentId)
            _ = try await builder.createResourceQuota(
                name: "roomy-storage", maxStorageGB: 100.0, project: project)

            let snapshot = try await makeCheckpoint(
                on: app, user: user, project: project, vm: vm, agentId: agentId,
                status: .creating, generation: 1, observedGeneration: 0)

            try await app.observedStateApplier.apply(
                report(
                    agentId: agentId,
                    snapshots: [
                        ObservedSnapshotState(
                            snapshotId: try snapshot.requireID(),
                            kind: .vmCheckpoint,
                            parentId: try vm.requireID(),
                            present: true,
                            facts: ObservedSnapshotFacts(sizeBytes: 2 << 30),
                            observedGeneration: 1)
                    ]))

            let settled = try #require(await VMSnapshot.find(snapshot.id, on: app.db))
            #expect(settled.desiredStatus == .present)
            #expect(settled.status == .ready)
            #expect(settled.size == 2 << 30)
            #expect(settled.conditions.converged)
        }
    }

    /// A bare export request must not read as converged the moment the agent's
    /// generation catches up: `isConverged` (which fires the convergence event
    /// and the completion webhook) and `conditions.converged` (which answers the
    /// client) are one derivation, so both wait for the copy.
    @Test("An outstanding export keeps the snapshot unconverged on both readers")
    func outstandingExportBlocksConvergence() async throws {
        try await withSnapshotApp { app, builder, user, project in
            let agentId = try await registerAgent(app: app, named: "export-converge")
            let sandbox = try await builder.createSandbox(name: "sb", project: project)
            sandbox.hypervisorId = agentId
            try await sandbox.save(on: app.db)

            let snapshot = SandboxSnapshot(
                name: "awaiting-export",
                sandboxID: try sandbox.requireID(),
                projectID: try project.requireID(),
                environment: sandbox.environment,
                agentId: agentId,
                createdByID: try user.requireID())
            snapshot.status = .ready
            snapshot.observedGeneration = snapshot.generation
            snapshot.exportDesired = true
            try await snapshot.save(on: app.db)

            #expect(!snapshot.isConverged)
            #expect(!snapshot.conditions.converged)

            // The upload route's completion is what settles it — never the
            // agent's word.
            snapshot.exportedArtifacts = SandboxSnapshotArtifactKind.allCases.map {
                SandboxSnapshotExportedArtifact(kind: $0, sizeBytes: 1, sha256: "abc")
            }
            snapshot.exportedAt = Date()
            #expect(snapshot.isConverged)
            #expect(snapshot.conditions.converged)
        }
    }

    /// STR-191, on the artifact families. Their resolution for a failed mutation
    /// is deliberately nothing, so `failedGeneration == generation` stands until
    /// a new mutation moves the target — which is exactly the state that used to
    /// read `converged` and `degraded` at once.
    @Test("A failure at the current generation un-converges an artifact on both readers")
    func currentGenerationFailureUnconvergesArtifact() async throws {
        try await withSnapshotApp { app, builder, user, project in
            let agentId = try await registerAgent(app: app, named: "artifact-degraded")
            let sandbox = try await builder.createSandbox(name: "sb", project: project)
            sandbox.hypervisorId = agentId
            try await sandbox.save(on: app.db)

            let snapshot = SandboxSnapshot(
                name: "failed-capture",
                sandboxID: try sandbox.requireID(),
                projectID: try project.requireID(),
                environment: sandbox.environment,
                agentId: agentId,
                createdByID: try user.requireID())
            snapshot.status = .ready
            snapshot.observedGeneration = snapshot.generation
            snapshot.errorMessage = "capture failed: no space left on device"
            snapshot.failedGeneration = snapshot.generation
            try await snapshot.save(on: app.db)

            #expect(!snapshot.isConverged)
            #expect(!snapshot.conditions.converged)
            #expect(snapshot.conditions.degraded?.sinceGeneration == snapshot.generation)

            // A failure a newer mutation already moved past still stands, but it
            // is not this generation's verdict.
            snapshot.generation += 1
            snapshot.observedGeneration = snapshot.generation
            #expect(snapshot.isConverged)
            #expect(snapshot.conditions.converged)
            #expect(snapshot.conditions.degraded != nil)
        }
    }

    @Test("A terminating artifact reads unconverged on both readers")
    func terminatingArtifactIsNeverConverged() async throws {
        try await withSnapshotApp { app, builder, user, project in
            let agentId = try await registerAgent(app: app, named: "artifact-terminating")
            let sandbox = try await builder.createSandbox(name: "sb", project: project)
            sandbox.hypervisorId = agentId
            try await sandbox.save(on: app.db)

            let snapshot = SandboxSnapshot(
                name: "going-away",
                sandboxID: try sandbox.requireID(),
                projectID: try project.requireID(),
                environment: sandbox.environment,
                agentId: agentId,
                createdByID: try user.requireID())
            snapshot.status = .ready
            snapshot.setFixtureDesiredStatus(.absent)
            snapshot.observedGeneration = snapshot.generation
            try await snapshot.save(on: app.db)

            // Absence is confirmed by omission from the agent's report, which
            // reaps the row — a still-present row has not converged. Unifying the
            // derivation is what brought the client-facing half in line with the
            // reconciliation half here (STR-191).
            #expect(!snapshot.isConverged)
            #expect(!snapshot.conditions.converged)
        }
    }

    // MARK: - Retention

    /// The `ttlSecondsAfterFinished` answer durable artifact objects need and
    /// fire-and-forget RPCs never raised. The expiry goes down the same path an
    /// operator's `DELETE` takes, attributed to the `system` actor.
    @Test("The retention sweep marks an expired artifact absent, attributably")
    func retentionSweepExpiresArtifacts() async throws {
        try await withSnapshotApp { app, builder, user, project in
            let agentId = try await registerAgent(app: app, named: "retention-agent")
            let vm = try await placedVM(builder, project: project, agentId: agentId)
            let expired = try await makeCheckpoint(
                on: app, user: user, project: project, vm: vm, agentId: agentId,
                name: "expired", expiresAt: Date().addingTimeInterval(-60))
            let kept = try await makeCheckpoint(
                on: app, user: user, project: project, vm: vm, agentId: agentId, name: "kept")

            await SnapshotRetentionSweep.run(app: app)

            let swept = try #require(await VMSnapshot.find(expired.id, on: app.db))
            #expect(swept.desiredStatus == .absent)
            #expect(swept.finalizers == [ResourceFinalizer.agentAbsent.rawValue])
            #expect(try await VMSnapshot.find(kept.id, on: app.db)?.desiredStatus == .present)

            let event = try #require(
                await ResourceEvent.latest(
                    .requested, resourceKind: .vmCheckpoint, resourceID: try expired.requireID(),
                    on: app.db))
            #expect(event.mutation == .delete)
            #expect(event.actorType == .system)
        }
    }

    /// Idempotent by construction: an artifact already heading for `.absent` is
    /// excluded by the query, so a second pass does not bump its generation
    /// again and re-arm a convergence that is already under way.
    @Test("A second retention pass does not re-delete an expiring artifact")
    func retentionSweepIsIdempotent() async throws {
        try await withSnapshotApp { app, builder, user, project in
            let agentId = try await registerAgent(app: app, named: "retention-twice")
            let vm = try await placedVM(builder, project: project, agentId: agentId)
            let expired = try await makeCheckpoint(
                on: app, user: user, project: project, vm: vm, agentId: agentId,
                name: "expired", expiresAt: Date().addingTimeInterval(-60))

            await SnapshotRetentionSweep.run(app: app)
            let first = try #require(await VMSnapshot.find(expired.id, on: app.db))
            let generation = first.generation

            await SnapshotRetentionSweep.run(app: app)
            let second = try #require(await VMSnapshot.find(expired.id, on: app.db))
            #expect(second.generation == generation)
        }
    }

    /// `SnapshotRetention.expiry` turns a relative TTL into an absolute
    /// deadline — relative would drift with every restart, and an artifact whose
    /// expiry keeps moving is one that never expires.
    @Test("A TTL resolves to an absolute deadline, with 0 meaning keep forever")
    func retentionExpiryResolution() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(try SnapshotRetention.expiry(requested: 60, from: now) == now.addingTimeInterval(60))
        #expect(try SnapshotRetention.expiry(requested: 0, from: now) == nil)
        // Unset means the fleet default, which is unset by default — so an
        // upgrade changes nothing about artifacts already being taken.
        #expect(try SnapshotRetention.expiry(requested: nil, from: now) == nil)
        #expect(throws: (any Error).self) {
            try SnapshotRetention.expiry(requested: -1, from: now)
        }
        #expect(throws: (any Error).self) {
            try SnapshotRetention.expiry(
                requested: SnapshotRetention.maxTTLSeconds + 1, from: now)
        }
    }
}
