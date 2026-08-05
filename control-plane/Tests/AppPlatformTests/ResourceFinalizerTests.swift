import AppTestSupport
import Fluent
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
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "finalizeruser",
                email: "finalizer@example.com",
                displayName: "Finalizer User",
                isSystemAdmin: false
            )
            let org = try await builder.createOrganization(name: "Finalizer Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            user.currentOrganizationId = org.id
            try await user.save(on: app.db)

            let project = try await builder.createProject(
                name: "Finalizer Project",
                description: "Project for finalizer tests",
                organization: org
            )
            let vm = try await builder.createVM(name: "finalizer-vm", project: project)
            let token = try await user.generateAPIKey(on: app.db)

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
            capabilities: ["qemu"],
            resources: AgentResources(
                totalCPU: 16, availableCPU: 16,
                totalMemory: 1 << 34, availableMemory: 1 << 34,
                totalDisk: 1 << 40, availableDisk: 1 << 40
            ),
            protocolVersion: WireProtocol.currentVersion
        )
        let orgID = try await Organization.query(on: app.db).sort(\.$createdAt).first()?.id
        let agentUUID = try await app.agentService.registerAgent(
            message, agentName: agentName,
            organizationScope: orgID.map { .organization($0) })
        if let vm {
            vm.hypervisorId = agentUUID.uuidString
            try await vm.save(on: app.db)
        }
        if let sandbox {
            sandbox.hypervisorId = agentUUID.uuidString
            try await sandbox.save(on: app.db)
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
        try await withFinalizerApp { app, _, _, vm, token in
            try await self.placeOnAgent(app: app, vm: vm)
            let vmID = try vm.requireID()

            try await app.test(.DELETE, "/api/vms/\(vmID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }

            // The row provably outlives the DELETE — the property that makes
            // `ResourceOperation`'s FK-lessness unnecessary.
            let terminating = try #require(try await VM.find(vmID, on: app.db))
            #expect(terminating.desiredStatus == .absent)
            #expect(terminating.finalizers == [ResourceFinalizer.agentAbsent.rawValue])
        }
    }

    @Test("An unplaced VM stamps nothing and is reaped by the direct path")
    func unplacedVMStampsNothing() async throws {
        try await withFinalizerApp { app, _, _, vm, token in
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
                if try await VM.find(vmID, on: app.db) == nil { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(try await VM.find(vmID, on: app.db) == nil)
        }
    }

    @Test("A second DELETE does not resurrect a token its participant already cleared")
    func restampingDoesNotResurrectClearedTokens() async throws {
        try await withFinalizerApp { app, _, _, vm, _ in
            vm.finalizers = [ResourceFinalizer.agentAbsent.rawValue, Self.foreign.rawValue]
            vm.setDesiredStatus(.absent)
            try await vm.save(on: app.db)

            try await ResourceFinalizerService.clear(.agentAbsent, from: vm, on: app.db, app: app)

            // Already terminating: the stamp is a no-op, not a fresh list.
            ResourceFinalizerService.stampForDeletion(vm)
            #expect(vm.finalizers == [Self.foreign.rawValue])
        }
    }

    // MARK: - Clearing and reaping

    @Test("An outstanding finalizer holds the row after the agent confirms absence")
    func outstandingFinalizerHoldsTheRow() async throws {
        try await withFinalizerApp { app, _, _, vm, _ in
            let agentId = try await self.placeOnAgent(app: app, vm: vm)
            let vmID = try vm.requireID()

            vm.finalizers = [ResourceFinalizer.agentAbsent.rawValue, Self.foreign.rawValue]
            vm.setDesiredStatus(.absent)
            try await vm.save(on: app.db)

            // The agent confirms teardown: its own token goes, the row does not.
            await app.agentService.applyObservedStateReport(
                try self.emptyReport(agentId: agentId), fromAgentKey: agentKey("finalizer-agent"))

            let held = try #require(try await VM.find(vmID, on: app.db))
            #expect(held.finalizers == [Self.foreign.rawValue])

            // The last participant clears, and the row goes with it.
            let removed = try await ResourceFinalizerService.clear(
                Self.foreign, from: held, on: app.db, app: app)
            #expect(removed)
            #expect(try await VM.find(vmID, on: app.db) == nil)
        }
    }

    @Test("Clearing the same token twice reaps once and never throws")
    func clearingIsIdempotent() async throws {
        try await withFinalizerApp { app, _, _, vm, _ in
            let vmID = try vm.requireID()
            vm.finalizers = [ResourceFinalizer.agentAbsent.rawValue]
            vm.setDesiredStatus(.absent)
            try await vm.save(on: app.db)

            let first = try await ResourceFinalizerService.clear(
                .agentAbsent, from: vm, on: app.db, app: app)
            #expect(first)
            #expect(try await VM.find(vmID, on: app.db) == nil)

            // The participant's trigger repeats (every observed-state report
            // omits a torn-down VM), so a second clear against a reaped row
            // must be a quiet no-op.
            let second = try await ResourceFinalizerService.clear(
                .agentAbsent, from: vm, on: app.db, app: app)
            #expect(!second)
        }
    }

    @Test("Clearing a finalizer on a live resource never reaps it")
    func clearingALiveResourceIsANoOp() async throws {
        try await withFinalizerApp { app, _, _, vm, _ in
            let vmID = try vm.requireID()
            vm.finalizers = [ResourceFinalizer.agentAbsent.rawValue]
            vm.setDesiredStatus(.running)
            try await vm.save(on: app.db)

            let removed = try await ResourceFinalizerService.clear(
                .agentAbsent, from: vm, on: app.db, app: app)
            #expect(!removed)

            let alive = try #require(try await VM.find(vmID, on: app.db))
            #expect(alive.finalizers == [ResourceFinalizer.agentAbsent.rawValue])
        }
    }

    @Test("Clearing an unstamped token is a no-op that does not reap the row")
    func clearingAnUnstampedTokenDoesNotReap() async throws {
        try await withFinalizerApp { app, _, _, vm, _ in
            let vmID = try vm.requireID()
            vm.finalizers = [Self.foreign.rawValue]
            vm.setDesiredStatus(.absent)
            try await vm.save(on: app.db)

            let removed = try await ResourceFinalizerService.clear(
                .agentAbsent, from: vm, on: app.db, app: app)
            #expect(!removed)

            let held = try #require(try await VM.find(vmID, on: app.db))
            #expect(held.finalizers == [Self.foreign.rawValue])
        }
    }

    // MARK: - Sandboxes

    @Test("Sandboxes take the same path: stamped on DELETE, reaped on confirmation")
    func sandboxFinalizersMirrorVMs() async throws {
        try await withFinalizerApp { app, _, project, _, token in
            let builder = TestDataBuilder(db: app.db)
            let sandbox = try await builder.createSandbox(name: "finalizer-sbx", project: project)
            let agentId = try await self.placeOnAgent(app: app, sandbox: sandbox)
            let sandboxID = try sandbox.requireID()

            try await app.test(.DELETE, "/api/sandboxes/\(sandboxID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }

            let terminating = try #require(try await Sandbox.find(sandboxID, on: app.db))
            #expect(terminating.desiredStatus == .absent)
            #expect(terminating.finalizers == [ResourceFinalizer.agentAbsent.rawValue])

            await app.agentService.applyObservedStateReport(
                try self.emptyReport(agentId: agentId), fromAgentKey: agentKey("finalizer-agent"))

            #expect(try await Sandbox.find(sandboxID, on: app.db) == nil)
        }
    }
}
