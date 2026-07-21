import Testing
import Vapor
import Fluent
import VaporTesting
import StratoShared
@testable import App

/// Tests for online CPU/memory resize (issue #568): `PUT /api/vms/:id` moves a
/// VM's sizing, applying it as a desired-state change with a `resize`
/// operation while the VM runs, or as a plain edit (which may also raise the
/// hot-add ceilings) while it rests.
@Suite("VM Resize Tests", .serialized)
final class VMResizeTests {

    /// Boots a configured test app with a user, org, project and one VM sized
    /// 2 vCPU / 2 GiB with hot-add headroom to 8 vCPU / 8 GiB, plus an online
    /// agent that speaks the resize protocol version.
    private func withResizeTestApp(
        agentWireVersion: Int = WireProtocol.currentVersion,
        quotaVCPUs: Int = 32,
        quotaMemoryGB: Double = 64,
        _ test: (Application, User, VM, Project, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "resizeuser",
                email: "resize@example.com",
                displayName: "Resize User",
                isSystemAdmin: false
            )
            let org = try await builder.createOrganization(name: "Resize Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            user.currentOrganizationId = org.id
            try await user.save(on: app.db)

            let project = try await builder.createProject(
                name: "Resize Project",
                description: "Project for VM resize tests",
                organization: org
            )
            _ = try await builder.createResourceQuota(
                name: "Resize Quota",
                maxVCPUs: quotaVCPUs,
                maxMemoryGB: quotaMemoryGB,
                organization: org
            )

            let agent = Agent(
                name: "hv-resize-\(UUID().uuidString.prefix(8))",
                hostname: "hv.example",
                version: "1.0.0",
                capabilities: ["qemu"],
                status: .online,
                resources: AgentResources(
                    totalCPU: 32, availableCPU: 32,
                    totalMemory: 64_000_000_000, availableMemory: 64_000_000_000,
                    totalDisk: 500_000_000_000, availableDisk: 500_000_000_000
                ),
                architecture: .x86_64,
                lastHeartbeat: Date()
            )
            agent.wireProtocolVersion = agentWireVersion
            try await agent.save(on: app.db)

            let vm = try await builder.createVM(name: "resize-vm", project: project)
            vm.maxCpu = 8
            vm.maxMemory = 8 * 1024 * 1024 * 1024
            vm.hypervisorId = agent.id?.uuidString
            try await vm.save(on: app.db)

            let token = try await user.generateAPIKey(on: app.db)
            try await test(app, user, vm, project, token)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }

        try await app.shutdownForTesting()
    }

    private func running(_ vm: VM, on db: any Database) async throws {
        vm.setStatus(.running)
        vm.setDesiredStatus(.running)
        try await vm.save(on: db)
    }

    private func put(
        _ app: Application, _ vm: VM, token: String, body: [String: Any],
        _ assertions: (TestingHTTPResponse) throws -> Void
    ) async throws {
        try await app.test(.PUT, "/api/vms/\(vm.id!)") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
            req.headers.contentType = .json
            req.body = ByteBuffer(data: try JSONSerialization.data(withJSONObject: body))
        } afterResponse: { res in
            try assertions(res)
        }
    }

    // MARK: - Metadata-only updates keep their 200

    @Test("A rename still answers 200 with the VM")
    func renameUnchanged() async throws {
        try await withResizeTestApp { app, _, vm, _, token in
            try await put(app, vm, token: token, body: ["name": "renamed"]) { res in
                #expect(res.status == .ok)
                let detail = try res.content.decode(VMDetailResponse.self)
                #expect(detail.name == "renamed")
                #expect(detail.cpu == 2)
            }
            let refreshed = try await VM.find(vm.id, on: app.db)
            #expect(refreshed?.generation == vm.generation)
        }
    }

    // MARK: - Resting VM

    @Test("Resizing a stopped VM applies immediately and raises the ceilings")
    func stoppedResizeAppliesDirectly() async throws {
        try await withResizeTestApp { app, _, vm, _, token in
            let sixteenGB = Int64(16 * 1024 * 1024 * 1024)
            try await put(app, vm, token: token, body: ["cpu": 12, "memory": sixteenGB]) { res in
                #expect(res.status == .ok)
                let detail = try res.content.decode(VMDetailResponse.self)
                #expect(detail.cpu == 12)
                #expect(detail.memory == sixteenGB)
            }

            let refreshed = try #require(try await VM.find(vm.id, on: app.db))
            #expect(refreshed.cpu == 12)
            #expect(refreshed.memory == sixteenGB)
            // A stopped VM re-spawns from the new spec, so its ceilings move with it.
            #expect(refreshed.maxCpu == 12)
            #expect(refreshed.maxMemory == sixteenGB)
            #expect(refreshed.generation > vm.generation)

            // No agent work is involved, so no operation is recorded.
            let operations = try await ResourceOperation.query(on: app.db)
                .filter(\.$resourceID == vm.id!).all()
            #expect(operations.isEmpty)
        }
    }

    // MARK: - Running VM

    @Test("Resizing a running VM returns 202 with a resize operation and bumps the generation")
    func runningResizeAccepted() async throws {
        try await withResizeTestApp { app, _, vm, _, token in
            try await running(vm, on: app.db)
            let generationBefore = vm.generation

            try await put(app, vm, token: token, body: ["cpu": 6]) { res in
                #expect(res.status == .accepted)
                let operation = try res.content.decode(OperationResponse.self)
                #expect(operation.kind == .resize)
                #expect(operation.status == .pending)
                #expect(operation.vmId == vm.id)
            }

            let refreshed = try #require(try await VM.find(vm.id, on: app.db))
            #expect(refreshed.cpu == 6)
            // A resize is a spec change, not a power-state change.
            #expect(refreshed.desiredStatus == .running)
            #expect(refreshed.generation > generationBefore)
        }
    }

    @Test("Growing a running VM past its vCPU ceiling is a 422 naming the restart")
    func beyondMaxCPURejected() async throws {
        try await withResizeTestApp { app, _, vm, _, token in
            try await running(vm, on: app.db)

            try await put(app, vm, token: token, body: ["cpu": 12]) { res in
                #expect(res.status == .unprocessableEntity)
                #expect(res.body.string.contains("restart"))
            }

            let refreshed = try await VM.find(vm.id, on: app.db)
            #expect(refreshed?.cpu == 2)
        }
    }

    @Test("Growing a running VM past its memory ceiling is a 422")
    func beyondMaxMemoryRejected() async throws {
        try await withResizeTestApp { app, _, vm, _, token in
            try await running(vm, on: app.db)

            try await put(app, vm, token: token, body: ["memory": Int64(32 * 1024 * 1024 * 1024)]) { res in
                #expect(res.status == .unprocessableEntity)
            }

            let refreshed = try #require(try await VM.find(vm.id, on: app.db))
            let unchanged = Int64(2 * 1024 * 1024 * 1024)
            #expect(refreshed.memory == unchanged)
        }
    }

    /// A pre-v17 agent reports the bumped generation as converged without
    /// touching the guest, so the resize must be refused rather than
    /// completing an operation that changed nothing.
    @Test("An agent too old to resize online is refused with 422")
    func oldAgentRejected() async throws {
        try await withResizeTestApp(agentWireVersion: WireProtocol.vmResizeMinimumVersion - 1) {
            app, _, vm, _, token in
            try await running(vm, on: app.db)

            try await put(app, vm, token: token, body: ["cpu": 4]) { res in
                #expect(res.status == .unprocessableEntity)
                #expect(res.body.string.contains("restart"))
            }

            let refreshed = try await VM.find(vm.id, on: app.db)
            #expect(refreshed?.cpu == 2)
        }
    }

    @Test("A resize that would exceed the project's quota is refused")
    func quotaEnforcedOnGrowth() async throws {
        try await withResizeTestApp(quotaVCPUs: 4) { app, _, vm, _, token in
            try await running(vm, on: app.db)

            try await put(app, vm, token: token, body: ["cpu": 6]) { res in
                #expect(res.status == .forbidden)
                #expect(res.body.string.lowercased().contains("quota"))
            }

            let refreshed = try await VM.find(vm.id, on: app.db)
            #expect(refreshed?.cpu == 2)
        }
    }

    @Test("A resize credits the quota back when the VM shrinks")
    func shrinkReleasesQuota() async throws {
        try await withResizeTestApp { app, _, vm, project, token in
            try await running(vm, on: app.db)

            try await put(app, vm, token: token, body: ["cpu": 1]) { res in
                #expect(res.status == .accepted)
            }

            let quotas = try await QuotaEnforcementService.applicableQuotas(
                for: project, environment: vm.environment, on: app.db)
            let quota = try #require(quotas.first)
            #expect(quota.reservedVCPUs == 1)
        }
    }

    @Test("A pending operation on the VM rejects a resize with 409")
    func pendingOperationBlocksResize() async throws {
        try await withResizeTestApp { app, user, vm, _, token in
            try await running(vm, on: app.db)
            let pending = ResourceOperation(vmID: vm.id!, userID: user.id!, kind: .shutdown)
            try await pending.save(on: app.db)

            try await put(app, vm, token: token, body: ["cpu": 4]) { res in
                #expect(res.status == .conflict)
            }
        }
    }
}
