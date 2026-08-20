import Testing
import Vapor
import Fluent
import VaporTesting
import StratoShared
import AppTestSupport
@testable import App

/// Tests for online CPU growth/memory resize (issue #568): `PUT /api/vms/:id`
/// moves a VM's sizing, applying it as a desired-state change with a `resize`
/// operation while the VM runs, or by updating the persistent definition while
/// it rests. Live CPU shrink is rejected. The same endpoint carries an
/// operator's balloon target (issue #567 phase 2), which moves the guest's
/// usable memory without moving the grant it is charged for.
@Suite("VM Resize Tests", .serialized)
final class VMResizeTests {

    /// Boots a configured test app with a user, org, project and one VM sized
    /// 2 vCPU / 2 GiB with hot-add headroom to 8 vCPU / 8 GiB, plus an online
    /// agent that speaks the resize protocol version.
    private func withResizeTestApp(
        agentWireVersion: Int = WireProtocol.currentVersion,
        agentArchitecture: CPUArchitecture = .x86_64,
        quotaVCPUs: Int = 32,
        quotaMemoryGB: Double = 64,
        agentAvailableCPU: Int = 32,
        agentAvailableMemory: Int64 = 64_000_000_000,
        _ test: (Application, User, inout VM, Project, String) async throws -> Void
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
            try await user.replacingCurrentOrganization(org.id).save(on: app.db)

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
                status: .online,
                resources: AgentResources(
                    totalCPU: 32, availableCPU: agentAvailableCPU,
                    totalMemory: 64_000_000_000, availableMemory: agentAvailableMemory,
                    totalDisk: 500_000_000_000, availableDisk: 500_000_000_000
                ),
                architecture: agentArchitecture,
                lastHeartbeat: Date()
            ).replacing(
                siteID: try await builder.placementSite(for: project).requireID(),
                wireProtocolVersion: .some(agentWireVersion))
            try await agent.save(on: app.db)

            var vm = try await builder.createVM(name: "resize-vm", project: project)
            vm.maxCpu = 8
            vm.maxMemory = 8 * 1024 * 1024 * 1024
            vm.hypervisorId = agent.id?.uuidString
            try await vm.save(on: app.db)

            let token = try await user.generateAPIKey(on: app)
            try await test(app, user, &vm, project, token)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }

        try await app.shutdownForTesting()
    }

    private func running(_ vm: inout VM, on db: any Database) async throws {
        vm.setStatus(.running)
        vm.setFixtureDesiredStatus(.running)
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

    @Test("Resizing a stopped VM records the desired sizing and raises the ceilings")
    func stoppedResizeRecordsDesiredSizing() async throws {
        try await withResizeTestApp { app, _, vm, _, token in
            let sixteenGB = Int64(16 * 1024 * 1024 * 1024)
            try await put(app, vm, token: token, body: ["cpu": 12, "memory": sixteenGB]) { res in
                #expect(res.status == .ok)
                let detail = try res.content.decode(VMDetailResponse.self)
                #expect(detail.cpu == 12)
                #expect(detail.memory == sixteenGB)
                #expect(!detail.conditions.converged)
                #expect(
                    detail.conditions.targetGeneration
                        > detail.conditions.observedGeneration
                )
            }

            let refreshed = try #require(try await VM.find(vm.id, on: app.db))
            #expect(refreshed.cpu == 12)
            #expect(refreshed.memory == sixteenGB)
            // A stopped VM re-spawns from the new spec, so its ceilings move with it.
            #expect(refreshed.maxCpu == 12)
            #expect(refreshed.maxMemory == sixteenGB)
            #expect(refreshed.generation > vm.generation)

            // The legacy 200 response does not create a mutation deadline. The
            // generation still reaches the agent, which must update its stopped
            // definition before it advances observedGeneration (STR-248).
            #expect(refreshed.convergenceDeadline == nil)
        }
    }

    // MARK: - Running VM

    @Test("Placed resize accepts an exact fit")
    func placedExactFit() async throws {
        try await withResizeTestApp(agentAvailableCPU: 4) { app, _, vm, _, token in
            try await running(&vm, on: app.db)
            try await put(app, vm, token: token, body: ["cpu": 6]) { res in
                #expect(res.status == .accepted)
            }
        }
    }

    @Test("Placed resize rejects CPU shortage without changing sizing, generation, or quota")
    func placedCPUShortage() async throws {
        try await withResizeTestApp(agentAvailableCPU: 3) { app, _, vm, project, token in
            try await running(&vm, on: app.db)
            let generation = vm.generation
            let quotasBefore = try await QuotaEnforcementService.applicableQuotas(
                for: project, environment: vm.environment, on: app.db)
            let reservedBefore = try #require(quotasBefore.first).reservedVCPUs

            try await put(app, vm, token: token, body: ["cpu": 6]) { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("Agent `hv-resize-"))
                #expect(res.body.string.contains("4 additional vCPUs"))
            }

            let refreshed = try #require(try await VM.find(vm.id, on: app.db))
            #expect(refreshed.cpu == 2)
            #expect(refreshed.generation == generation)
            let quotasAfter = try await QuotaEnforcementService.applicableQuotas(
                for: project, environment: vm.environment, on: app.db)
            #expect(try #require(quotasAfter.first).reservedVCPUs == reservedBefore)
        }
    }

    @Test("Placed resize subtracts active placement reservations")
    func activePlacementReservation() async throws {
        try await withResizeTestApp(agentAvailableCPU: 4) { app, _, vm, _, token in
            try await running(&vm, on: app.db)
            let agentID = try #require(vm.hypervisorId)
            #expect(
                await app.coordination.reserveCapacity(
                    agentId: agentID, vmId: UUID().uuidString,
                    amounts: ReservationAmounts(cpu: 2, memory: 0, disk: 0),
                    capacity: ReservationAmounts(cpu: 4, memory: 64_000_000_000, disk: 0)))

            try await put(app, vm, token: token, body: ["cpu": 6]) { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("after active placements"))
            }
        }
    }

    @Test("Stopped QEMU growth beyond reserved headroom needs new host capacity")
    func stoppedQEMUBeyondHeadroom() async throws {
        try await withResizeTestApp(agentAvailableMemory: 1024 * 1024 * 1024) {
            app, _, vm, _, token in
            try await put(
                app, vm, token: token,
                body: ["memory": Int64(10 * 1024 * 1024 * 1024)]
            ) { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("2 GiB additional memory"))
            }
        }
    }

    @Test("Stopped QEMU resize charges arm64 headroom that was too small to realize")
    func stoppedQEMUUnrealizedHeadroom() async throws {
        try await withResizeTestApp(
            agentArchitecture: .arm64,
            agentAvailableMemory: 0
        ) { app, _, vm, project, token in
            let gib: Int64 = 1024 * 1024 * 1024
            let requested = gib + 256 * 1024 * 1024
            vm.memory = gib
            vm.maxMemory = requested
            try await vm.save(on: app.db)
            let generation = vm.generation
            let quotasBefore = try await QuotaEnforcementService.applicableQuotas(
                for: project, environment: vm.environment, on: app.db)
            let reservedBefore = try #require(quotasBefore.first).reservedMemory

            try await put(app, vm, token: token, body: ["memory": requested]) { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("256 MiB additional memory"))
            }

            let refreshed = try #require(try await VM.find(vm.id, on: app.db))
            #expect(refreshed.memory == gib)
            #expect(refreshed.maxMemory == requested)
            #expect(refreshed.generation == generation)
            let quotasAfter = try await QuotaEnforcementService.applicableQuotas(
                for: project, environment: vm.environment, on: app.db)
            #expect(try #require(quotasAfter.first).reservedMemory == reservedBefore)
        }
    }

    @Test("ARM QEMU memory shrink passes when alignment would make the reservation look larger")
    func armQEMUShrinkOnFullHost() async throws {
        try await withResizeTestApp(
            agentArchitecture: .arm64,
            agentAvailableMemory: 0
        ) { app, _, vm, _, token in
            let gib: Int64 = 1024 * 1024 * 1024
            vm.memory = gib + 768 * 1024 * 1024
            vm.maxMemory = 2 * gib
            try await vm.save(on: app.db)

            try await put(app, vm, token: token, body: ["memory": gib]) { res in
                #expect(res.status == .ok)
            }

            let refreshed = try #require(try await VM.find(vm.id, on: app.db))
            #expect(refreshed.memory == gib)
        }
    }

    @Test("Non-QEMU memory growth compares current and requested grants")
    func nonQEMUMemoryShortage() async throws {
        try await withResizeTestApp(agentAvailableMemory: 1024 * 1024 * 1024) {
            app, _, vm, _, token in
            vm.hypervisorType = .firecracker
            try await vm.save(on: app.db)
            try await put(
                app, vm, token: token,
                body: ["memory": Int64(4 * 1024 * 1024 * 1024)]
            ) { res in
                #expect(res.status == .conflict)
            }
        }
    }

    @Test("A running memory shrink passes on a full host")
    func memoryShrinkOnFullHost() async throws {
        try await withResizeTestApp(agentAvailableCPU: 0, agentAvailableMemory: 0) {
            app, _, vm, _, token in
            try await running(&vm, on: app.db)
            try await put(
                app, vm, token: token,
                body: ["memory": Int64(1024 * 1024 * 1024)]
            ) { res in
                #expect(res.status == .accepted)
            }
        }
    }

    @Test("A running vCPU shrink is rejected without changing convergence, sizing, or quota")
    func runningVCPUShrinkRejected() async throws {
        try await withResizeTestApp { app, _, vm, project, token in
            try await running(&vm, on: app.db)
            // Model a live count the agent has confirmed, so the control plane
            // can distinguish this from a smaller replacement for a pending
            // growth request.
            vm.observedGeneration = vm.generation
            try await vm.save(on: app.db)
            let generationBefore = vm.generation
            let observedBefore = vm.observedGeneration
            let conditionsBefore = vm.conditions
            let quotasBefore = try await QuotaEnforcementService.applicableQuotas(
                for: project, environment: vm.environment, on: app.db)
            let reservedBefore = try #require(quotasBefore.first).reservedVCPUs

            try await put(app, vm, token: token, body: ["cpu": 1]) { res in
                #expect(res.status == .unprocessableEntity)
                #expect(res.body.string.contains("live vCPU unplug is not supported"))
                #expect(res.body.string.contains("Stop the VM, resize it, then start it again"))
                #expect(res.body.string.contains("no resize was recorded"))
            }

            let refreshed = try #require(try await VM.find(vm.id, on: app.db))
            #expect(refreshed.cpu == 2)
            #expect(refreshed.generation == generationBefore)
            #expect(refreshed.observedGeneration == observedBefore)
            #expect(refreshed.conditions == conditionsBefore)
            #expect(refreshed.convergenceDeadline == nil)
            let quotasAfter = try await QuotaEnforcementService.applicableQuotas(
                for: project, environment: vm.environment, on: app.db)
            #expect(try #require(quotasAfter.first).reservedVCPUs == reservedBefore)
        }
    }

    @Test("Unplaced stopped VM relies on placement instead of one host snapshot")
    func unplacedStoppedVM() async throws {
        try await withResizeTestApp(agentAvailableCPU: 0, agentAvailableMemory: 0) {
            app, _, vm, _, token in
            vm.hypervisorId = nil
            try await vm.save(on: app.db)
            try await put(app, vm, token: token, body: ["cpu": 12]) { res in
                #expect(res.status == .ok)
            }
        }
    }

    @Test("Resizing a running VM returns 202 with the VM and bumps the generation")
    func runningResizeAccepted() async throws {
        try await withResizeTestApp { app, _, vm, _, token in
            try await running(&vm, on: app.db)
            let generationBefore = vm.generation

            try await put(app, vm, token: token, body: ["cpu": 6]) { res in
                #expect(res.status == .accepted)
                let body = try res.content.decode(AcceptedMutation<VMDetailResponse>.self)
                #expect(body.resource.id == vm.id)
                #expect(body.resource.cpu == 6)
                #expect(body.targetGeneration == body.resource.conditions.targetGeneration)
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
            try await running(&vm, on: app.db)

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
            try await running(&vm, on: app.db)

            try await put(app, vm, token: token, body: ["memory": Int64(32 * 1024 * 1024 * 1024)]) { res in
                #expect(res.status == .unprocessableEntity)
            }

            let refreshed = try #require(try await VM.find(vm.id, on: app.db))
            let unchanged = Int64(2 * 1024 * 1024 * 1024)
            #expect(refreshed.memory == unchanged)
        }
    }

    @Test("A resize that would exceed the project's quota is refused")
    func quotaEnforcedOnGrowth() async throws {
        try await withResizeTestApp(quotaVCPUs: 4) { app, _, vm, _, token in
            try await running(&vm, on: app.db)

            try await put(app, vm, token: token, body: ["cpu": 6]) { res in
                #expect(res.status == .forbidden)
                #expect(res.body.string.lowercased().contains("quota"))
            }

            let refreshed = try await VM.find(vm.id, on: app.db)
            #expect(refreshed?.cpu == 2)
        }
    }

    @Test("A stopped vCPU shrink credits the quota back")
    func stoppedShrinkReleasesQuota() async throws {
        try await withResizeTestApp { app, _, vm, project, token in
            try await put(app, vm, token: token, body: ["cpu": 1]) { res in
                #expect(res.status == .ok)
            }

            let quotas = try await QuotaEnforcementService.applicableQuotas(
                for: project, environment: vm.environment, on: app.db)
            let quota = try #require(quotas.first)
            #expect(quota.reservedVCPUs == 1)
        }
    }

    @Test("Two overlapping resizes charge quota once each, against the committed sizing")
    func overlappingResizesChargeQuotaCorrectly() async throws {
        try await withResizeTestApp { app, _, vm, project, token in
            try await running(&vm, on: app.db)

            // The "operation already pending" mutex is gone (STR-147), so
            // nothing refuses the second resize. What replaces it is the row
            // lock the resize takes inside its own transaction: the loser
            // recomputes its delta against the winner's committed sizing rather
            // than against the stale value it read before the request.
            let vmID = try vm.requireID()
            try await withThrowingTaskGroup(of: Void.self) { group in
                for cpu in [4, 6] {
                    group.addTask {
                        try await app.test(.PUT, "/api/vms/\(vmID)") { req in
                            req.headers.bearerAuthorization = BearerAuthorization(token: token)
                            req.headers.contentType = .json
                            req.body = ByteBuffer(
                                data: try JSONSerialization.data(withJSONObject: ["cpu": cpu]))
                        } afterResponse: { res in
                            #expect(res.status == .accepted)
                        }
                    }
                }
                try await group.waitForAll()
            }

            // Whichever landed last owns the sizing, and the project is charged
            // exactly the difference from the VM's original 2 vCPUs — never
            // both deltas computed from the same base.
            let refreshed = try #require(try await VM.find(vm.id, on: app.db))
            let quotas = try await QuotaEnforcementService.applicableQuotas(
                for: project, environment: vm.environment, on: app.db)
            let quota = try #require(quotas.first)
            #expect(quota.reservedVCPUs == refreshed.cpu)
        }
    }

    @Test("A smaller pending growth supersedes a larger one instead of becoming a shrink")
    func pendingGrowthRemainsLastWriterWins() async throws {
        try await withResizeTestApp { app, _, vm, project, token in
            try await running(&vm, on: app.db)
            vm.observedGeneration = vm.generation
            try await vm.save(on: app.db)

            try await put(app, vm, token: token, body: ["cpu": 6]) { res in
                #expect(res.status == .accepted)
            }
            let first = try #require(try await VM.find(vm.id, on: app.db))
            #expect(first.cpu == 6)
            #expect(!first.conditions.converged)

            // The confirmed runtime is still 2 vCPUs. Although the desired
            // column now says 6, replacing that pending request with 4 remains
            // growth and keeps ResourceMutation's last-writer-wins behavior.
            try await put(app, vm, token: token, body: ["cpu": 4]) { res in
                #expect(res.status == .accepted)
            }

            let refreshed = try #require(try await VM.find(vm.id, on: app.db))
            let quotas = try await QuotaEnforcementService.applicableQuotas(
                for: project, environment: vm.environment, on: app.db)
            #expect(refreshed.cpu == 4)
            #expect(try #require(quotas.first).reservedVCPUs == 4)
        }
    }

    // MARK: - Balloon targets (issue #567 phase 2)

    @Test("Setting a balloon target on a running VM returns 202 and leaves the grant alone")
    func balloonTargetOnRunningVM() async throws {
        try await withResizeTestApp { app, _, vm, project, token in
            try await running(&vm, on: app.db)
            let generationBefore = vm.generation
            let oneGB = Int64(1024 * 1024 * 1024)

            try await put(app, vm, token: token, body: ["balloonTarget": oneGB]) { res in
                #expect(res.status == .accepted)
                let body = try res.content.decode(AcceptedMutation<VMDetailResponse>.self)
                #expect(body.resource.balloonTarget == oneGB)
            }

            let refreshed = try #require(try await VM.find(vm.id, on: app.db))
            #expect(refreshed.balloonTarget == oneGB)
            // The grant — and so the quota charge — is untouched: reclaim is
            // opportunistic, the memory is still committed to this VM.
            #expect(refreshed.memory == vm.memory)
            #expect(refreshed.generation > generationBefore)

            let quotas = try await QuotaEnforcementService.applicableQuotas(
                for: project, environment: vm.environment, on: app.db)
            let quota = try #require(quotas.first)
            #expect(quota.reservedVCPUs == 2)
        }
    }

    @Test("Clearing a balloon target with an explicit null hands the grant back")
    func balloonTargetCleared() async throws {
        try await withResizeTestApp { app, _, vm, _, token in
            vm.balloonTarget = 1024 * 1024 * 1024
            try await vm.save(on: app.db)
            try await running(&vm, on: app.db)

            try await put(app, vm, token: token, body: ["balloonTarget": NSNull()]) { res in
                #expect(res.status == .accepted)
            }

            let refreshed = try #require(try await VM.find(vm.id, on: app.db))
            #expect(refreshed.balloonTarget == nil)
        }
    }

    /// Absence and null are different requests: a rename must not silently
    /// deflate a guest that an operator deliberately squeezed.
    @Test("An update that omits balloonTarget leaves the existing target alone")
    func balloonTargetUntouchedWhenOmitted() async throws {
        try await withResizeTestApp { app, _, vm, _, token in
            let oneGB = Int64(1024 * 1024 * 1024)
            vm.balloonTarget = oneGB
            try await vm.save(on: app.db)
            try await running(&vm, on: app.db)

            try await put(app, vm, token: token, body: ["name": "renamed"]) { res in
                #expect(res.status == .ok)
            }

            let refreshed = try #require(try await VM.find(vm.id, on: app.db))
            #expect(refreshed.balloonTarget == oneGB)
        }
    }

    @Test("A balloon target on a stopped VM is a plain edit the next boot applies")
    func balloonTargetOnStoppedVM() async throws {
        try await withResizeTestApp { app, _, vm, _, token in
            let oneGB = Int64(1024 * 1024 * 1024)

            try await put(app, vm, token: token, body: ["balloonTarget": oneGB]) { res in
                #expect(res.status == .ok)
                let detail = try res.content.decode(VMDetailResponse.self)
                #expect(detail.balloonTarget == oneGB)
            }

            let refreshed = try #require(try await VM.find(vm.id, on: app.db))
            #expect(refreshed.balloonTarget == oneGB)
            #expect(refreshed.generation > vm.generation)
        }
    }

    @Test("A balloon target above the VM's memory is a 400")
    func balloonTargetAboveMemoryRejected() async throws {
        try await withResizeTestApp { app, _, vm, _, token in
            try await running(&vm, on: app.db)
            let tenGB = Int64(10 * 1024 * 1024 * 1024)

            try await put(app, vm, token: token, body: ["balloonTarget": tenGB]) { res in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("memory"))
            }

            let refreshed = try await VM.find(vm.id, on: app.db)
            #expect(refreshed?.balloonTarget == nil)
        }
    }

    @Test("A balloon target below the survivable floor is a 400")
    func balloonTargetBelowFloorRejected() async throws {
        try await withResizeTestApp { app, _, vm, _, token in
            try await running(&vm, on: app.db)

            try await put(app, vm, token: token, body: ["balloonTarget": 1024]) { res in
                #expect(res.status == .badRequest)
            }

            let refreshed = try await VM.find(vm.id, on: app.db)
            #expect(refreshed?.balloonTarget == nil)
        }
    }

}
