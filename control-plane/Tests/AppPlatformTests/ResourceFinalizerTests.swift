import ControlPlanePostgres
import AppTestSupport
import StratoShared
import Testing
import Vapor
import VaporTesting

@testable import App

/// Finalizers (STR-144, ADR 0001 stage 3): `DELETE` marks a workload absent
/// and stamps the cleanup participants its teardown owes, each participant
/// clears its own token from wherever it runs, and the row is removed only when
/// the list empties.
///
/// The agent-absence confirmation is the first participant — the same tombstone
/// dance `DesiredStateReconciliationTests` covers end to end, now expressed as
/// one token among a list. These tests cover the list itself: that it holds the
/// row, that clearing is atomic and idempotent, and that it cannot reap
/// something that was never deleted.
@Suite("Resource Finalizer Tests", .serialized)
final class ResourceFinalizerTests {

    /// A token no participant in this build knows about — the stand-in for both
    /// a future participant (`dns.deregister`) and a newer replica's token
    /// arriving mid-upgrade.
    private static let foreign = ResourceFinalizer(rawValue: "test.hold")

    private func withFinalizerApp(
        _ test: (Application, User, Project, VM, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)

            let builder = TestDataBuilder(db: app.testPostgres)
            let user = try await builder.createUser(
                username: "finalizeruser",
                email: "finalizer@example.com",
                displayName: "Finalizer User",
                isSystemAdmin: false
            )
            let org = try await builder.createOrganization(name: "Finalizer Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            try await user.replacingCurrentOrganization(org.id).save(on: app.testPostgres)

            let project = try await builder.createProject(
                name: "Finalizer Project",
                description: "Project for finalizer tests",
                organization: org
            )
            let vm = try await builder.createVM(name: "finalizer-vm", project: project)
            let token = try await user.generateAPIKey(on: app)

            try await test(app, user, project, vm, token)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }

        try await app.shutdownForTesting()
    }

    /// Registers an online in-memory agent and places `hypervisorId` on the
    /// workload, so `DELETE` takes the state-sync path rather than the offline
    /// direct one. Returns the agent's UUID string.
    @discardableResult
    private func placeOnAgent(
        app: Application, vm: VM? = nil, sandbox: Sandbox? = nil,
        named agentName: String = "finalizer-agent"
    ) async throws -> String {
        let message = AgentRegisterMessage(
            agentId: agentName,
            hostname: "test-host",
            version: "1.0.0",
            resources: AgentResources(
                totalCPU: 16, availableCPU: 16,
                totalMemory: 1 << 34, availableMemory: 1 << 34,
                totalDisk: 1 << 40, availableDisk: 1 << 40
            ),
            protocolVersion: WireProtocol.currentVersion
        )
        let orgID = try await Organization.all(on: app.testPostgres).first?.id
        let agentUUID = try await app.agentService.registerAgent(
            message, agentName: agentName,
            organizationScope: orgID.map { .organization($0) })
        if var vm {
            vm.hypervisorId = agentUUID.uuidString
            try await vm.save(on: app.testPostgres)
        }
        if var sandbox {
            sandbox.hypervisorId = agentUUID.uuidString
            try await sandbox.save(on: app.testPostgres)
        }
        return agentUUID.uuidString
    }

    /// A full report that mentions neither VMs nor sandboxes: the agent holds
    /// nothing, which is what confirms a teardown.
    private func emptyReport(agentId: String) throws -> MessageEnvelope {
        try MessageEnvelope(
            message: ObservedStateReport(
                agentId: agentId,
                vms: [],
                resources: AgentResources(
                    totalCPU: 16, availableCPU: 16,
                    totalMemory: 1 << 34, availableMemory: 1 << 34,
                    totalDisk: 1 << 40, availableDisk: 1 << 40
                )
            ))
    }

    // MARK: - Stamping

    @Test("DELETE on a placed VM stamps agent.absent and leaves the row standing")
    func deleteStampsAgentAbsent() async throws {
        try await withFinalizerApp { app, _, _, initialVM, token in
            var vm = initialVM
            try await self.placeOnAgent(app: app, vm: vm)
            let vmID = try vm.requireID()

            try await app.test(.DELETE, "/api/vms/\(vmID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }

            // The row provably outlives the DELETE — the property that makes
            // `ResourceOperation`'s FK-lessness unnecessary.
            let terminating = try #require(try await VM.find(vmID, on: app.testPostgres))
            #expect(terminating.desiredStatus == .absent)
            #expect(terminating.finalizers == [ResourceFinalizer.agentAbsent.rawValue])
        }
    }

    @Test("An unplaced VM stamps nothing and is reaped by the direct path")
    func unplacedVMStampsNothing() async throws {
        try await withFinalizerApp { app, _, _, initialVM, token in
            var vm = initialVM
            let vmID = try vm.requireID()
            #expect(vm.hypervisorId == nil)

            try await app.test(.DELETE, "/api/vms/\(vmID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }

            // Nothing has to confirm a teardown that never reached an agent, so
            // the empty list reaps on the direct path's first clear.
            for _ in 0..<100 {
                if try await VM.find(vmID, on: app.testPostgres) == nil { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(try await VM.find(vmID, on: app.testPostgres) == nil)
        }
    }

    @Test("A second DELETE does not resurrect a token its participant already cleared")
    func restampingDoesNotResurrectClearedTokens() async throws {
        try await withFinalizerApp { app, _, _, initialVM, _ in
            var vm = initialVM
            vm.finalizers = [ResourceFinalizer.agentAbsent.rawValue, Self.foreign.rawValue]
            vm.setFixtureDesiredStatus(.absent)
            try await vm.save(on: app.testPostgres)

            try await ResourceFinalizerService.clear(.agentAbsent, from: vm, on: app.testPostgres, app: app)

            // Already terminating: the stamp is a no-op, not a fresh list.
            try await ResourceFinalizerService.stampForDeletion(vm, on: app.testPostgres)
            #expect(vm.finalizers == [Self.foreign.rawValue])
        }
    }

    // MARK: - Clearing and reaping

    @Test("An outstanding finalizer holds the row after the agent confirms absence")
    func outstandingFinalizerHoldsTheRow() async throws {
        try await withFinalizerApp { app, _, _, initialVM, _ in
            var vm = initialVM
            let agentId = try await self.placeOnAgent(app: app, vm: vm)
            let vmID = try vm.requireID()

            vm.finalizers = [ResourceFinalizer.agentAbsent.rawValue, Self.foreign.rawValue]
            vm.setFixtureDesiredStatus(.absent)
            try await vm.save(on: app.testPostgres)

            // The agent confirms teardown: its own token goes, the row does not.
            await app.agentService.applyObservedStateReport(
                try self.emptyReport(agentId: agentId), fromAgentKey: agentKey("finalizer-agent"))

            let held = try #require(try await VM.find(vmID, on: app.testPostgres))
            #expect(held.finalizers == [Self.foreign.rawValue])

            // The last participant clears, and the row goes with it.
            let outcome = try await ResourceFinalizerService.clear(
                Self.foreign, from: held, on: app.testPostgres, app: app)
            #expect(outcome == .reaped)
            #expect(try await VM.find(vmID, on: app.testPostgres) == nil)
        }
    }

    @Test("Clearing the same token twice reaps once and never throws")
    func clearingIsIdempotent() async throws {
        try await withFinalizerApp { app, _, _, initialVM, _ in
            var vm = initialVM
            let vmID = try vm.requireID()
            vm.finalizers = [ResourceFinalizer.agentAbsent.rawValue]
            vm.setFixtureDesiredStatus(.absent)
            try await vm.save(on: app.testPostgres)

            let first = try await ResourceFinalizerService.clear(
                .agentAbsent, from: vm, on: app.testPostgres, app: app)
            #expect(first == .reaped)
            #expect(try await VM.find(vmID, on: app.testPostgres) == nil)

            // The participant's trigger repeats (every observed-state report
            // omits a torn-down VM), so a second clear against a reaped row
            // must be a quiet no-op — and must not claim a second removal, or
            // the direct path would report a delete it did not perform.
            let second = try await ResourceFinalizerService.clear(
                .agentAbsent, from: vm, on: app.testPostgres, app: app)
            #expect(second == .alreadyGone)
        }
    }

    @Test("Clearing a finalizer on a live resource never reaps it")
    func clearingALiveResourceIsANoOp() async throws {
        try await withFinalizerApp { app, _, _, initialVM, _ in
            var vm = initialVM
            let vmID = try vm.requireID()
            vm.finalizers = [ResourceFinalizer.agentAbsent.rawValue]
            vm.setFixtureDesiredStatus(.running)
            try await vm.save(on: app.testPostgres)

            let outcome = try await ResourceFinalizerService.clear(
                .agentAbsent, from: vm, on: app.testPostgres, app: app)
            #expect(outcome == .notTerminating)

            let alive = try #require(try await VM.find(vmID, on: app.testPostgres))
            #expect(alive.finalizers == [ResourceFinalizer.agentAbsent.rawValue])
        }
    }

    @Test("Clearing an unstamped token is a no-op that does not reap the row")
    func clearingAnUnstampedTokenDoesNotReap() async throws {
        try await withFinalizerApp { app, _, _, initialVM, _ in
            var vm = initialVM
            let vmID = try vm.requireID()
            vm.finalizers = [Self.foreign.rawValue]
            vm.setFixtureDesiredStatus(.absent)
            try await vm.save(on: app.testPostgres)

            let outcome = try await ResourceFinalizerService.clear(
                .agentAbsent, from: vm, on: app.testPostgres, app: app)
            #expect(outcome == .held([Self.foreign.rawValue]))

            let held = try #require(try await VM.find(vmID, on: app.testPostgres))
            #expect(held.finalizers == [Self.foreign.rawValue])
        }
    }

    @Test("A terminating row left with an empty list by a crash reaps on the next clear")
    func emptyListLeftByACrashReapsOnTheNextClear() async throws {
        try await withFinalizerApp { app, _, _, initialVM, _ in
            var vm = initialVM
            let vmID = try vm.requireID()

            // Exactly the state a crash between the token's commit and the
            // row's leaves behind — the case the two-commit design leans on.
            vm.finalizers = []
            vm.setFixtureDesiredStatus(.absent)
            try await vm.save(on: app.testPostgres)

            let outcome = try await ResourceFinalizerService.clear(
                .agentAbsent, from: vm, on: app.testPostgres, app: app)
            #expect(outcome == .reaped)
            #expect(try await VM.find(vmID, on: app.testPostgres) == nil)
        }
    }

    // MARK: - The direct path (offline agent)

    @Test("An offline agent's VM is reaped by the direct path, and the reap records it")
    func offlineAgentDirectPathReaps() async throws {
        try await withFinalizerApp { app, _, _, initialVM, token in
            var vm = initialVM
            // Placed on an agent that was never registered: online lookup
            // fails, so DELETE takes the direct path rather than state sync.
            vm.hypervisorId = UUID().uuidString
            try await vm.save(on: app.testPostgres)
            let vmID = try vm.requireID()

            try await app.test(.DELETE, "/api/vms/\(vmID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }
            await app.backgroundTasks.drain(timeout: .seconds(10))

            #expect(try await VM.find(vmID, on: app.testPostgres) == nil)
            let terminal = try #require(try await self.deletionCompleted(for: vmID, on: app.testPostgres))
            #expect(terminal.mutation == .delete)
        }
    }

    @Test("The direct path records nothing terminal while another finalizer holds the row")
    func offlineAgentDirectPathRecordsNothingWhenHeld() async throws {
        try await withFinalizerApp { app, _, _, initialVM, token in
            var vm = initialVM
            vm.hypervisorId = UUID().uuidString
            vm.finalizers = [ResourceFinalizer.agentAbsent.rawValue, Self.foreign.rawValue]
            vm.setFixtureDesiredStatus(.absent)
            try await vm.save(on: app.testPostgres)
            let vmID = try vm.requireID()

            try await app.test(.DELETE, "/api/vms/\(vmID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }
            await app.backgroundTasks.drain(timeout: .seconds(10))

            // Force-clearing the agent's token does not finish the delete, so
            // nothing may record that it did — a client polling the delete
            // would otherwise be told a still-standing row is gone.
            let held = try #require(try await VM.find(vmID, on: app.testPostgres))
            #expect(held.finalizers == [Self.foreign.rawValue])
            #expect(try await self.deletionCompleted(for: vmID, on: app.testPostgres) == nil)
        }
    }

    // MARK: - The orphan backstop

    @Test("The sweep reaps a terminating row whose finalizers all cleared")
    func sweepReapsOrphanedTerminatingRows() async throws {
        try await withFinalizerApp { app, _, _, initialVM, _ in
            var vm = initialVM
            let vmID = try vm.requireID()
            vm.finalizers = []
            vm.setFixtureDesiredStatus(.absent)
            try await vm.save(on: app.testPostgres)
            try await self.backdate(schema: VM.schema, id: vmID, bySeconds: 600, on: app.testPostgres)

            await app.agentService.sweepOrphanedTerminatingResources()

            #expect(try await VM.find(vmID, on: app.testPostgres) == nil)
        }
    }

    @Test("The sweep leaves a row that still owes a finalizer, however old")
    func sweepLeavesHeldRowsAlone() async throws {
        try await withFinalizerApp { app, _, _, initialVM, _ in
            var vm = initialVM
            let vmID = try vm.requireID()
            vm.finalizers = [Self.foreign.rawValue]
            vm.setFixtureDesiredStatus(.absent)
            try await vm.save(on: app.testPostgres)
            try await self.backdate(schema: VM.schema, id: vmID, bySeconds: 600, on: app.testPostgres)

            await app.agentService.sweepOrphanedTerminatingResources()

            let held = try #require(try await VM.find(vmID, on: app.testPostgres))
            #expect(held.finalizers == [Self.foreign.rawValue])
        }
    }

    @Test("The sweep leaves a live row alone, however old")
    func sweepLeavesLiveRowsAlone() async throws {
        try await withFinalizerApp { app, _, _, initialVM, _ in
            var vm = initialVM
            let vmID = try vm.requireID()
            try await self.backdate(schema: VM.schema, id: vmID, bySeconds: 600, on: app.testPostgres)

            await app.agentService.sweepOrphanedTerminatingResources()

            #expect(try await VM.find(vmID, on: app.testPostgres) != nil)
        }
    }

    // MARK: - Sandboxes

    @Test("Sandboxes take the same path: stamped on DELETE, reaped on confirmation")
    func sandboxFinalizersMirrorVMs() async throws {
        try await withFinalizerApp { app, _, project, _, token in
            let builder = TestDataBuilder(db: app.testPostgres)
            let sandbox = try await builder.createSandbox(name: "finalizer-sbx", project: project)
            let agentId = try await self.placeOnAgent(app: app, sandbox: sandbox)
            let sandboxID = try sandbox.requireID()

            try await app.test(.DELETE, "/api/sandboxes/\(sandboxID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }

            let terminating = try #require(try await Sandbox.find(sandboxID, on: app.testPostgres))
            #expect(terminating.desiredStatus == .absent)
            #expect(terminating.finalizers == [ResourceFinalizer.agentAbsent.rawValue])

            await app.agentService.applyObservedStateReport(
                try self.emptyReport(agentId: agentId), fromAgentKey: agentKey("finalizer-agent"))

            #expect(try await Sandbox.find(sandboxID, on: app.testPostgres) == nil)
        }
    }

    @Test("The expiry sweep stamps finalizers like a user-initiated delete")
    func expirySweepStampsFinalizers() async throws {
        try await withFinalizerApp { app, _, project, _, _ in
            let builder = TestDataBuilder(db: app.testPostgres)
            var sandbox = try await builder.createSandbox(name: "expiring-sbx", project: project)
            // Online agent, so the sweep takes the state-sync path and the row
            // waits for the agent's confirmation rather than going directly.
            try await self.placeOnAgent(app: app, sandbox: sandbox)
            let sandboxID = try sandbox.requireID()

            sandbox.ttlSeconds = 60
            sandbox.createdAt = Date().addingTimeInterval(-120)
            try await sandbox.save(on: app.testPostgres)

            await app.agentService.sweepExpiredSandboxes()

            let terminating = try #require(try await Sandbox.find(sandboxID, on: app.testPostgres))
            #expect(terminating.desiredStatus == .absent)
            #expect(terminating.finalizers == [ResourceFinalizer.agentAbsent.rawValue])
        }
    }

    // MARK: - Helpers

    /// The terminal `resource_events` row the reap appends — the delete's
    /// completion signal now that there is no operation row to succeed
    /// (STR-147).
    private func deletionCompleted(for resourceID: UUID, on db: PostgresStoreContext) async throws
        -> ResourceEvent?
    {
        try await ResourceEvent.latest(
            .completed, resourceKind: .virtualMachine, resourceID: resourceID, on: db)
    }

    /// Ages a row's `updatedAt` past a sweep's budget. Raw SQL because Fluent
    /// stamps `updatedAt` on every save, so it cannot be backdated through the
    /// model the way `createdAt` can.
    private func backdate(
        schema: String, id: UUID, bySeconds seconds: TimeInterval, on db: PostgresStoreContext
    ) async throws {
        let sql = try #require(Optional(db))
        try await sql.raw(
            """
            UPDATE \(ident: schema)
            SET updated_at = \(bind: Date().addingTimeInterval(-seconds))
            WHERE id = \(bind: id)
            """
        ).run()
    }
}
