import Testing
import Vapor
import Fluent
import SQLKit
import VaporTesting
import StratoShared
import AppTestSupport
@testable import App

/// Tests for asynchronous VM operations (issue #259), as ADR 0001 left them:
/// lifecycle mutations return `202 Accepted` with `{resource,
/// targetGeneration, mutationId}` and are judged by the VM's own `conditions`
/// (stage 4, STR-147), and the operations API answers for them purely as a
/// façade over `resource_events` (stage 11, STR-152).
///
/// The operation-row half of this suite went with the table: the pending-row
/// uniqueness index, the compare-and-swap verdict guard, and the
/// stuck-operation sweep. Their replacements — the convergence deadline and
/// `conditions.degraded` — are exercised by the stuck-convergence section
/// below.
@Suite("VM Operation Tests", .serialized)
final class VMOperationTests {

    private struct AttachInterfaceBody: Content {
        let networkId: UUID
        var securityGroupIds: [UUID]? = nil
        var mtu: Int? = nil
    }

    /// Boots a configured test app with a non-admin user, org, project and one VM.
    /// Mirrors the harness in `VMAuthorizationTests` so requests traverse the full
    /// middleware stack (role-binding-backed authorization, API-key auth).
    private func withVMTestApp(
        _ test: (Application, User, VM, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "vmopuser",
                email: "vmop@example.com",
                displayName: "VM Op User",
                isSystemAdmin: false
            )
            let org = try await builder.createOrganization(name: "VM Op Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            user.currentOrganizationId = org.id
            try await user.save(on: app.db)

            let project = try await builder.createProject(
                name: "VM Op Project",
                description: "Project for VM operation tests",
                organization: org
            )
            let vm = try await builder.createVM(name: "op-vm", project: project)
            let token = try await user.generateAPIKey(on: app.db)

            try await test(app, user, vm, token)

        } catch {
            try await app.shutdownForTesting()
            throw error
        }

        try await app.shutdownForTesting()
    }

    /// Waits for the background dispatch task to resolve the VM to `expected`.
    /// The operation is completed before the VM status is written, so once the
    /// VM matches, the operation is guaranteed terminal.
    private func pollVMStatus(
        _ vmID: UUID, until expected: VMStatus, on db: any Database
    ) async throws {
        for _ in 0..<100 {
            if let vm = try await VM.find(vmID, on: db), vm.status == expected {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("VM \(vmID) never reached status \(expected.rawValue)")
    }

    /// Waits for the background dispatch to degrade the VM, returning its
    /// `conditions`. The `202` returns before the dispatch runs, so a test
    /// asserting on the outcome has to poll the row it asserts on.
    private func pollDegraded(_ vmID: UUID, on db: any Database) async throws -> ResourceConditions? {
        for _ in 0..<100 {
            if let vm = try await VM.find(vmID, on: db), vm.conditions.degraded != nil {
                return vm.conditions
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("VM \(vmID) never went degraded")
        return nil
    }

    // MARK: - Reboot as an edge-nonce (ADR 0001 stage 9, STR-151)

    /// Registers an agent and places `vm` on it, converged and running.
    @discardableResult
    private func placeOnAgent(app: Application, vm: VM) async throws -> String {
        let message = AgentRegisterMessage(
            agentId: "reboot-agent",
            hostname: "test-host",
            version: "1.0.0",
            resources: AgentResources(
                totalCPU: 16, availableCPU: 16,
                totalMemory: 1 << 34, availableMemory: 1 << 34,
                totalDisk: 1 << 40, availableDisk: 1 << 40),
            protocolVersion: WireProtocol.currentVersion)
        let organization = try #require(
            try await Organization.query(on: app.db).sort(\.$createdAt).first())
        let orgID = try organization.requireID()
        let site = Site(name: "VM Operation Site", organizationScope: .organization(orgID))
        try await site.save(on: app.db)
        let agentUUID = try await app.agentService.registerAgent(
            message, agentName: "reboot-agent", siteID: try site.requireID(),
            organizationScope: .organization(orgID))

        vm.hypervisorId = agentUUID.uuidString
        vm.setStatus(.running)
        vm.desiredStatus = .running
        vm.generation = 1
        vm.observedGeneration = 1
        try await vm.save(on: app.db)
        return agentUUID.uuidString
    }

    @Test("VM interface attach uses the lowest free stable slot and returns a 202 mutation")
    func attachNetworkInterfaceUsesLowestFreeSlot() async throws {
        try await withVMTestApp { app, user, vm, token in
            try await placeOnAgent(app: app, vm: vm)
            let project = try #require(try await Project.find(vm.$project.id, on: app.db))
            let network = try await TestDataBuilder(db: app.db).createNetwork(
                name: "hotplug-net", project: project,
                subnet: "10.240.0.0/24", gateway: "10.240.0.1")
            for slot in [0, 2] {
                try await VMNetworkInterface(
                    vmID: vm.id!, logicalNetworkID: network.id!,
                    macAddress: "52:54:00:00:00:0\(slot)",
                    deviceName: "net\(slot)", orderIndex: slot
                ).save(on: app.db)
            }

            var accepted: AcceptedMutation<VMDetailResponse>?
            try await app.test(.POST, "/api/vms/\(vm.id!)/interfaces") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(AttachInterfaceBody(networkId: network.id!, mtu: 1450))
            } afterResponse: { res in
                #expect(res.status == .accepted)
                accepted = try res.content.decode(AcceptedMutation<VMDetailResponse>.self)
            }

            let created = try #require(
                try await VMNetworkInterface.query(on: app.db)
                    .filter(\.$vm.$id == vm.id!)
                    .filter(\.$orderIndex == 1)
                    .first())
            #expect(created.deviceName == "net1")
            #expect(created.mtu == 1450)
            #expect(MACAddress(allocated: created.macAddress) != nil)
            #expect(created.attachGeneration == accepted?.targetGeneration)

            try await app.test(.GET, "/api/vms/\(vm.id!)/interfaces") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let interfaces = try res.content.decode([NetworkInterfaceResponse].self)
                #expect(interfaces.map(\.orderIndex) == [0, 1, 2])
            }
        }
    }

    @Test("VM interface attach rejects networks that need static guest configuration")
    func networkInterfaceAttachRejectsStaticNetwork() async throws {
        try await withVMTestApp { app, user, vm, token in
            try await placeOnAgent(app: app, vm: vm)
            let project = try #require(try await Project.find(vm.$project.id, on: app.db))
            let network = try await TestDataBuilder(db: app.db).createNetwork(
                name: "static-hotplug-net", project: project,
                subnet: "10.243.0.0/24", gateway: "10.243.0.1", dhcpEnabled: false)

            try await app.test(.POST, "/api/vms/\(vm.id!)/interfaces") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(AttachInterfaceBody(networkId: network.id!))
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("requires static guest configuration"))
            }

            #expect(
                try await VMNetworkInterface.query(on: app.db)
                    .filter(\.$vm.$id == vm.id!).count() == 0)
            #expect(try await VM.find(vm.id, on: app.db)?.generation == 1)
        }
    }

    @Test("Detaching the final NIC retains it for confirmation and a failed detach can be retried")
    func detachFinalNetworkInterfaceAndRetry() async throws {
        try await withVMTestApp { app, user, vm, token in
            try await placeOnAgent(app: app, vm: vm)
            let project = try #require(try await Project.find(vm.$project.id, on: app.db))
            let network = try await TestDataBuilder(db: app.db).createNetwork(
                name: "detach-net", project: project,
                subnet: "10.242.0.0/24", gateway: "10.242.0.1")
            let nic = VMNetworkInterface(
                vmID: try vm.requireID(), logicalNetworkID: try network.requireID(),
                macAddress: "52:54:00:00:00:42", deviceName: "net0", orderIndex: 0)
            nic.attachGeneration = vm.generation
            try await nic.save(on: app.db)
            let nicID = try nic.requireID()

            try await app.test(.POST, "/api/vms/\(vm.id!)/interfaces/\(nicID)/retry") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            var detachGeneration: Int64?
            try await app.test(.DELETE, "/api/vms/\(vm.id!)/interfaces/\(nicID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
                detachGeneration = try res.content.decode(
                    AcceptedMutation<VMDetailResponse>.self
                ).targetGeneration
            }
            let retained = try #require(try await VMNetworkInterface.find(nicID, on: app.db))
            #expect(retained.detachGeneration == detachGeneration)

            // Model the agent's failed convergence report. The list surface
            // derives the failure from the interface's mutation generation and
            // keeps the row visible and reserved.
            let failedVM = try #require(try await VM.find(vm.id, on: app.db))
            failedVM.failedGeneration = detachGeneration
            failedVM.lastError = "libvirt detach failed"
            try await failedVM.save(on: app.db)
            try await app.test(.GET, "/api/vms/\(vm.id!)/interfaces") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                let interfaces = try res.content.decode([NetworkInterfaceResponse].self)
                #expect(interfaces.count == 1)
                #expect(interfaces[0].attachmentState == .detachFailed)
                #expect(interfaces[0].attachmentError == "libvirt detach failed")
            }

            var retryGeneration: Int64?
            try await app.test(.POST, "/api/vms/\(vm.id!)/interfaces/\(nicID)/retry") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
                retryGeneration = try res.content.decode(
                    AcceptedMutation<VMDetailResponse>.self
                ).targetGeneration
            }
            #expect(retryGeneration == (detachGeneration ?? 0) + 1)
            #expect(
                try await VMNetworkInterface.find(nicID, on: app.db)?.detachGeneration
                    == retryGeneration)
        }
    }

    /// A reboot starts and ends `.running`, so `desiredStatus` cannot express
    /// it — which is why it was the last VM verb still dispatched as an
    /// imperative RPC. It rides the sync as a count now.
    @Test("POST /api/vms/:id/restart bumps the reboot nonce and answers like every other mutation")
    func restartBumpsTheRebootNonce() async throws {
        try await withVMTestApp { app, _, vm, token in
            try await placeOnAgent(app: app, vm: vm)

            var accepted: AcceptedMutation<VMDetailResponse>?
            try await app.test(.POST, "/api/vms/\(vm.id!)/restart") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
                accepted = try res.content.decode(AcceptedMutation<VMDetailResponse>.self)
            }
            let body = try #require(accepted)
            #expect(body.targetGeneration == 2)

            let stored = try #require(try await VM.find(vm.id, on: app.db))
            #expect(stored.rebootGeneration == 1)
            // Untouched: a reboot is not a power-state change, and saying it was
            // would have the next sync stop or start the guest.
            #expect(stored.desiredStatus == .running)
            #expect(stored.generation == 2)
            #expect(stored.restoreGeneration == 0)

            // A second request outranks the first rather than colliding with it:
            // there is no "operation already pending" 409 on a level-triggered
            // counter.
            try await app.test(.POST, "/api/vms/\(vm.id!)/restart") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }
            #expect(try await VM.find(vm.id, on: app.db)?.rebootGeneration == 2)

            // Attributed and auditable like every other mutation.
            let events = try await ResourceEvent.query(on: app.db)
                .filter(\.$resourceID == vm.id!)
                .filter(\.$mutation == .reboot)
                .all()
            #expect(events.count == 2)
        }
    }

    @Test("replaying one idempotent restart returns its first acceptance and bumps the nonce once")
    func idempotentRestartIsAppliedOnce() async throws {
        try await withVMTestApp { app, _, vm, token in
            try await placeOnAgent(app: app, vm: vm)
            let key = UUID().uuidString
            var first: AcceptedMutation<VMDetailResponse>?
            var replay: AcceptedMutation<VMDetailResponse>?

            try await app.test(.POST, "/api/vms/\(vm.id!)/restart") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                req.headers.replaceOrAdd(name: "Idempotency-Key", value: key)
            } afterResponse: { res in
                #expect(res.status == .accepted)
                first = try res.content.decode(AcceptedMutation<VMDetailResponse>.self)
            }
            try await app.test(.POST, "/api/vms/\(vm.id!)/restart") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                req.headers.replaceOrAdd(name: "Idempotency-Key", value: key)
            } afterResponse: { res in
                #expect(res.status == .accepted)
                replay = try res.content.decode(AcceptedMutation<VMDetailResponse>.self)
            }

            #expect(replay?.mutationId == first?.mutationId)
            #expect(replay?.targetGeneration == first?.targetGeneration)
            #expect(try await VM.find(vm.id, on: app.db)?.rebootGeneration == 1)
            #expect(
                try await ResourceEvent.query(on: app.db)
                    .filter(\.$resourceID == vm.id!)
                    .filter(\.$mutation == .reboot)
                    .count() == 1)
        }
    }

    // MARK: - 202 + async failure recording

    @Test("POST /api/vms/:id/start returns 202 with the VM and its target generation")
    func startReturnsAcceptedAndDegradesWithoutAgent() async throws {
        try await withVMTestApp { app, _, vm, token in
            var accepted: AcceptedMutation<VMDetailResponse>?

            try await app.test(.POST, "/api/vms/\(vm.id!)/start") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
                let body = try res.content.decode(AcceptedMutation<VMDetailResponse>.self)
                #expect(body.resource.id == vm.id)
                // The generation the client waits for is the one the mutation
                // just wrote, and the VM has not reached it yet.
                #expect(body.targetGeneration == body.resource.conditions.targetGeneration)
                #expect(!body.resource.conditions.converged)
                accepted = body
            }
            let body = try #require(accepted)

            // No agent is mapped to the VM, so the background dispatch fails
            // immediately: the VM must go degraded at this generation and be
            // restored to its pre-mutation status (not left `.starting`).
            let conditions = try await pollDegraded(vm.id!, on: app.db)
            #expect(conditions?.degraded?.sinceGeneration == body.targetGeneration)
            #expect(conditions?.degraded?.reason.isEmpty == false)

            try await pollVMStatus(vm.id!, until: .created, on: app.db)

            // And the operations façade reports the same thing to a client that
            // still polls the old way.
            try await app.test(.GET, "/api/operations/\(body.mutationId)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let operation = try res.content.decode(OperationResponse.self)
                #expect(operation.kind == .boot)
                #expect(operation.status == .failed)
                #expect(operation.vmId == vm.id)
                #expect(operation.error?.isEmpty == false)
            }
        }
    }

    // MARK: - Delete cleans up IAM bindings (STR-112)

    @Test("DELETE takes the VM's role bindings — and its checkpoints' — with the row")
    func deleteRevokesRoleBindings() async throws {
        try await withVMTestApp { app, user, vm, token in
            let vmID = try vm.requireID()

            // The creator binding VM creation writes, plus a checkpoint whose
            // row cascades away with the VM and so orphans its binding too.
            try await RoleBindingService.grant(
                principalType: .user, principalID: user.id!, role: .admin,
                nodeType: .virtualMachine, nodeID: vmID, createdBy: user.id!, on: app.db)
            let snapshot = VMSnapshot(
                name: "checkpoint", vmID: vmID, projectID: vm.$project.id,
                environment: vm.environment, agentId: nil, createdByID: user.id!)
            try await snapshot.save(on: app.db)
            let snapshotID = try snapshot.requireID()
            try await RoleBindingService.grant(
                principalType: .user, principalID: user.id!, role: .admin,
                nodeType: .vmSnapshot, nodeID: snapshotID, createdBy: user.id!, on: app.db)

            // Unplaced VM, so the delete resolves directly instead of waiting
            // for an agent to confirm absence.
            var mutationId: UUID?
            try await app.test(.DELETE, "/api/vms/\(vmID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
                mutationId = try res.content.decode(AcceptedMutation<VMDetailResponse>.self).mutationId
            }

            try await self.pollVMRemoved(vmID, on: app.db)
            let gone = try await VM.find(vmID, on: app.db)
            #expect(gone == nil)

            // The delete's completion signal: the reap appended a terminal
            // event, and the façade answers `succeeded` off it — the one thing
            // `conditions` cannot say, because the resource is gone.
            try await app.test(.GET, "/api/operations/\(mutationId!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let operation = try res.content.decode(OperationResponse.self)
                #expect(operation.kind == .delete)
                #expect(operation.status == .succeeded)
                #expect(operation.completedAt != nil)
            }

            let vmBindings = try await RoleBinding.query(on: app.db)
                .filter(\.$nodeType == IAMNodeType.virtualMachine.rawValue)
                .filter(\.$nodeID == vmID)
                .count()
            #expect(vmBindings == 0)
            let snapshotBindings = try await RoleBinding.query(on: app.db)
                .filter(\.$nodeType == IAMNodeType.vmSnapshot.rawValue)
                .filter(\.$nodeID == snapshotID)
                .count()
            #expect(snapshotBindings == 0)
        }
    }

    /// Waits for the background dispatch to reap the deleted row.
    private func pollVMRemoved(_ vmID: UUID, on db: any Database) async throws {
        for _ in 0..<100 {
            if try await VM.find(vmID, on: db) == nil { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("VM \(vmID) was never removed")
    }

    // MARK: - The dropped mutex

    @Test("An unconverged mutation no longer blocks another lifecycle mutation")
    func pendingOperationDoesNotBlockLifecycleMutation() async throws {
        try await withVMTestApp { app, user, vm, token in
            // A mutation in flight: desired state moved and the agent has not
            // confirmed it, which is what the operation mutex used to key on.
            vm.setFixtureDesiredStatus(.shutdown)
            vm.extendConvergenceDeadline(by: 600)
            try await vm.save(on: app.db)
            _ = try await record(.shutdown, on: vm, by: user, on: app.db)

            // Starting the VM is a level-triggered desired-state write, so it
            // is accepted rather than refused with the `409` the operation
            // mutex used to produce (STR-147).
            try await app.test(.POST, "/api/vms/\(vm.id!)/start") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }

            // The boot was recorded and bumped a generation of its own; what
            // the background dispatch then does with an unplaced VM is the
            // subject of `startReturnsAcceptedAndDegradesWithoutAgent`.
            let boot = try await ResourceEvent.latest(
                .requested, resourceKind: .virtualMachine, resourceID: vm.id!, on: app.db)
            #expect(boot?.mutation == .boot)
        }
    }

    // The partial unique index that allowed at most one pending operation per
    // VM went with the table (STR-152). Nothing replaces it, and that is the
    // point of the section above: two overlapping desired-state writes leave
    // the last one standing, and `lockAndRefresh` is what serializes them.

    // MARK: - Operation read API authorization

    @Test("GET /api/operations/:id follows the VM's read permission")
    func operationReadFollowsVMPermission() async throws {
        try await withVMTestApp { app, user, vm, token in
            let event = try await record(.boot, on: vm, by: user, on: app.db)
            let eventID = try event.requireID()

            try await app.test(.GET, "/api/operations/\(eventID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let body = try res.content.decode(OperationResponse.self)
                #expect(body.id == eventID)
                #expect(body.vmId == vm.id)
            }

            // A user with no binding on the VM cannot read its operation.
            let outsider = try await TestDataBuilder(db: app.db).createUser(
                username: "op-outsider", email: "op-outsider@example.com")
            let outsiderToken = try await outsider.generateAPIKey(on: app.db)
            try await app.test(.GET, "/api/operations/\(eventID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: outsiderToken)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test("Captured command output requires initiation or vm:runCommand")
    func commandOutputRequiresCommandPrivilege() async throws {
        try await withVMTestApp { app, user, vm, token in
            let vmID = try vm.requireID()
            let execution = VMCommandExecution(
                vmID: vmID, actorID: try user.requireID(), agentKey: "agent-key",
                deadline: Date().addingTimeInterval(60))
            try await execution.create(command: ["/usr/bin/printenv"], on: app.db)
            let executionID = try execution.requireID()
            let payload = try #require(try await VMCommandPayload.find(executionID, on: app.db))
            payload.recordResult(
                stdout: Data("SECRET=value\n".utf8), stderr: Data(), exitCode: 0,
                truncated: false)
            try await payload.update(on: app.db)
            execution.status = .succeeded
            execution.completedAt = Date()
            try await execution.update(on: app.db)

            // The initiating user may poll the result even though no seeded
            // role grants vm:runCommand.
            try await app.test(.GET, "/api/operations/\(executionID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let operation = try res.content.decode(OperationResponse.self)
                #expect(operation.result?.stdout == "SECRET=value\n")
            }

            let reader = try await TestDataBuilder(db: app.db).createUser(
                username: "command-output-reader", email: "command-output-reader@example.com")
            try await RoleBindingService.grant(
                principalType: .user, principalID: try reader.requireID(), role: .viewer,
                nodeType: .virtualMachine, nodeID: vmID, createdBy: nil, on: app.db)
            let readerToken = try await reader.generateAPIKey(on: app.db)

            try await app.test(.GET, "/api/operations/\(executionID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: readerToken)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
                #expect(!res.body.string.contains("SECRET=value"))
            }
        }
    }

    @Test("An operation whose VM is gone is visible to its initiator only")
    func operationForDeletedVMVisibleToInitiatorOnly() async throws {
        try await withVMTestApp { app, user, vm, token in
            let event = try await record(.delete, on: vm, by: user, on: app.db)
            let eventID = try event.requireID()

            // Remove the VM row directly, as a completed delete would.
            try await vm.delete(on: app.db)

            try await app.test(.GET, "/api/operations/\(eventID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            // A different (non-admin) user cannot see it — 404, not 403, so the
            // operation's existence is not leaked.
            let builder = TestDataBuilder(db: app.db)
            let other = try await builder.createUser(
                username: "othervmopuser",
                email: "othervmop@example.com",
                displayName: "Other User"
            )
            let otherToken = try await other.generateAPIKey(on: app.db)

            try await app.test(.GET, "/api/operations/\(eventID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: otherToken)
            } afterResponse: { res in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("GET /api/vms/:id/operations lists newest first and honors limit")
    func listOperationsNewestFirst() async throws {
        try await withVMTestApp { app, user, vm, token in
            // Recorded in order and never rewritten: `resource_events` is
            // append-only (its trigger rejects an `UPDATE`), so the insert
            // order is the only way to age one row relative to another.
            _ = try await record(.boot, on: vm, by: user, on: app.db)
            let newer = try await record(.shutdown, on: vm, by: user, on: app.db)

            try await app.test(.GET, "/api/vms/\(vm.id!)/operations?limit=1") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let operations = try res.content.decode([OperationResponse].self)
                #expect(operations.count == 1)
                #expect(operations.first?.id == newer.id)
            }

            // A malformed limit is a 400 here too, not a silent fall back to
            // the default — every int query parameter goes through the same
            // shared parse (issue #732).
            try await app.test(.GET, "/api/vms/\(vm.id!)/operations?limit=abc") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    // MARK: - The operations façade (STR-147)

    /// Records a mutation the way `ResourceMutation` does, without the dispatch.
    private func record(
        _ kind: VMOperationKind, on vm: VM, by user: User, on db: any Database
    ) async throws -> ResourceEvent {
        try await ResourceEvent.record(
            kind, resourceKind: .virtualMachine, resourceID: try vm.requireID(),
            actor: .user(try user.requireID()), on: db)
    }

    @Test("The façade reports pending, then succeeded, as the VM converges")
    func facadeFollowsConvergence() async throws {
        try await withVMTestApp { app, user, vm, token in
            vm.setFixtureDesiredStatus(.running)
            try await vm.save(on: app.db)
            let event = try await record(.boot, on: vm, by: user, on: app.db)
            let eventID = try event.requireID()

            try await app.test(.GET, "/api/operations/\(eventID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                let operation = try res.content.decode(OperationResponse.self)
                #expect(operation.status == .pending)
                #expect(operation.kind == .boot)
            }

            // The agent converges: observed generation reaches the target and
            // the observed status satisfies the desired one.
            vm.observedGeneration = vm.generation
            vm.setStatus(.running)
            try await vm.save(on: app.db)

            try await app.test(.GET, "/api/operations/\(eventID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                let operation = try res.content.decode(OperationResponse.self)
                #expect(operation.status == .succeeded)
            }
        }
    }

    @Test("The façade reports failed when the VM is degraded at the mutation's generation")
    func facadeReportsDegradedAsFailed() async throws {
        try await withVMTestApp { app, user, vm, token in
            vm.setFixtureDesiredStatus(.running)
            try await vm.save(on: app.db)
            let event = try await record(.boot, on: vm, by: user, on: app.db)

            vm.lastError = "image download failed"
            vm.failedGeneration = vm.generation
            try await vm.save(on: app.db)

            try await app.test(.GET, "/api/operations/\(try event.requireID())") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                let operation = try res.content.decode(OperationResponse.self)
                #expect(operation.status == .failed)
                #expect(operation.error == "image download failed")
            }
        }
    }

    /// The ticket's own case: a VM whose agent applied generation N — by the
    /// boot — and then failed the drift-correcting resize planned at the same N.
    /// The façade already read `degraded` first, so it answered `failed`; the
    /// resource read `converged: true` alongside it, so a client following the
    /// documented rule got both answers. Asserting the two together is what
    /// pins them to one.
    @Test("A VM converged at the generation a failure names reports failed on both readers")
    func facadeAndConditionsAgreeAtOneGeneration() async throws {
        try await withVMTestApp { app, user, vm, token in
            vm.setFixtureDesiredStatus(.running)
            vm.setStatus(.running)
            vm.observedGeneration = vm.generation
            try await vm.save(on: app.db)
            let event = try await record(.resize, on: vm, by: user, on: app.db)

            vm.lastError = "resize failed: no space left on device"
            vm.failedGeneration = vm.generation
            try await vm.save(on: app.db)

            try await app.test(.GET, "/api/operations/\(try event.requireID())") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                let operation = try res.content.decode(OperationResponse.self)
                #expect(operation.status == .failed)
                #expect(operation.error == "resize failed: no space left on device")
            }

            try await app.test(.GET, "/api/vms/\(try vm.requireID())") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                let detail = try res.content.decode(VMDetailResponse.self)
                #expect(!detail.conditions.converged)
                #expect(detail.conditions.degraded?.sinceGeneration == detail.conditions.targetGeneration)
            }
        }
    }

    @Test("A superseded mutation reads as succeeded, not pending forever")
    func facadeReportsSupersededAsSucceeded() async throws {
        try await withVMTestApp { app, user, vm, token in
            vm.setFixtureDesiredStatus(.running)
            try await vm.save(on: app.db)
            let event = try await record(.boot, on: vm, by: user, on: app.db)

            // The agent reached this mutation's generation, and a newer
            // mutation has already moved the target on. The old one is not
            // pending — the reconciler is past it.
            vm.observedGeneration = vm.generation
            vm.setFixtureDesiredStatus(.shutdown)
            try await vm.save(on: app.db)

            try await app.test(.GET, "/api/operations/\(try event.requireID())") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                let operation = try res.content.decode(OperationResponse.self)
                #expect(operation.status == .succeeded)
            }
        }
    }

    @Test("A delete is visible to its initiator after the VM is gone, and hidden from others")
    func facadeAnswersDeleteAfterTheRowIsGone() async throws {
        try await withVMTestApp { app, user, vm, token in
            let vmID = try vm.requireID()
            try await ResourceFinalizerService.stampForDeletion(vm, on: app.db)
            vm.setFixtureDesiredStatus(.absent)
            try await vm.save(on: app.db)
            let event = try await record(.delete, on: vm, by: user, on: app.db)
            let eventID = try event.requireID()

            // Still terminating: not done.
            try await app.test(.GET, "/api/operations/\(eventID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                let operation = try res.content.decode(OperationResponse.self)
                #expect(operation.status == .pending)
            }

            _ = try await ResourceFinalizerService.clear(.agentAbsent, from: vm, on: app.db, app: app)
            #expect(try await VM.find(vmID, on: app.db) == nil)

            try await app.test(.GET, "/api/operations/\(eventID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let operation = try res.content.decode(OperationResponse.self)
                #expect(operation.status == .succeeded)
                #expect(operation.completedAt != nil)
            }

            // 404 rather than 403 for a stranger, so the mutation's existence
            // is not leaked now that there is no resource to authorize against.
            let outsider = try await TestDataBuilder(db: app.db).createUser(
                username: "facade-outsider", email: "facade-outsider@example.com")
            let outsiderToken = try await outsider.generateAPIKey(on: app.db)
            try await app.test(.GET, "/api/operations/\(eventID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: outsiderToken)
            } afterResponse: { res in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("An idempotent delete replays its original acceptance after the VM is gone")
    func idempotentDeleteReplaysAfterTheRowIsGone() async throws {
        try await withVMTestApp { app, user, vm, token in
            let vmID = try vm.requireID()
            let path = "/api/vms/\(vmID)"
            let key = UUID().uuidString
            var originalBody: Data?
            var originalMutationID: UUID?

            let boot = Volume(
                name: "op-vm-boot", description: "", projectID: vm.$project.id,
                environment: vm.environment, size: vm.disk, volumeType: .boot,
                createdByID: try user.requireID())
            boot.$vm.id = vmID
            boot.deviceName = "disk0"
            boot.bootOrder = 0
            try await boot.save(on: app.db)

            try await app.test(.DELETE, path) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                req.headers.replaceOrAdd(name: "Idempotency-Key", value: key)
            } afterResponse: { res in
                #expect(res.status == .accepted)
                originalBody = Data(res.body.readableBytesView)
                originalMutationID = try res.content
                    .decode(AcceptedMutation<VMDetailResponse>.self).mutationId
            }

            await app.backgroundTasks.drain(timeout: .seconds(10))
            #expect(try await VM.find(vmID, on: app.db) == nil)

            try await app.test(.DELETE, path) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                req.headers.replaceOrAdd(name: "Idempotency-Key", value: key)
            } afterResponse: { res in
                #expect(res.status == .accepted)
                #expect(Data(res.body.readableBytesView) == originalBody)
                let replayed = try res.content.decode(AcceptedMutation<VMDetailResponse>.self)
                #expect(replayed.mutationId == originalMutationID)
            }
        }
    }

    @Test("A delete that misses its deadline stays pending, then succeeds")
    func facadeNeverReportsASlowDeleteAsFailed() async throws {
        try await withVMTestApp { app, user, vm, token in
            let vmID = try vm.requireID()
            try await ResourceFinalizerService.stampForDeletion(vm, on: app.db)
            vm.setFixtureDesiredStatus(.absent)
            vm.convergenceDeadline = Date().addingTimeInterval(-1)
            try await vm.save(on: app.db)
            let event = try await record(.delete, on: vm, by: user, on: app.db)
            let eventID = try event.requireID()

            // The teardown outran its budget — a large disk, or a finalizer
            // participant waiting on something — so the sweep degrades the VM.
            await app.agentService.sweepStuckConvergence()
            let degraded = try #require(try await VM.find(vmID, on: app.db))
            #expect(degraded.conditions.degraded != nil)

            // The *resource* carries that reason for an operator, but the
            // delete's own verdict must not read `failed`: the teardown is slow,
            // not doomed, and telling a user their delete failed moments before
            // the resource disappears is the worst available answer.
            try await app.test(.GET, "/api/operations/\(eventID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                let operation = try res.content.decode(OperationResponse.self)
                #expect(operation.status == .pending)
            }

            // The agent finally confirms absence.
            _ = try await ResourceFinalizerService.clear(.agentAbsent, from: degraded, on: app.db, app: app)
            #expect(try await VM.find(vmID, on: app.db) == nil)

            try await app.test(.GET, "/api/operations/\(eventID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                let operation = try res.content.decode(OperationResponse.self)
                #expect(operation.status == .succeeded)
                #expect(operation.completedAt != nil)
            }
        }
    }

    @Test("A terminal event is not addressable as an operation of its own")
    func facadeRefusesTerminalEventIds() async throws {
        try await withVMTestApp { app, user, vm, token in
            let terminal = try await ResourceEvent.record(
                .delete, resourceKind: .virtualMachine, resourceID: try vm.requireID(),
                actor: .user(try user.requireID()), phase: .completed, on: app.db)

            try await app.test(.GET, "/api/operations/\(try terminal.requireID())") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .notFound)
            }
        }
    }

    /// One source now: `resource_events`. The list used to merge in the
    /// operation rows the still-imperative verbs wrote, and the merge went with
    /// them (STR-152) rather than the events half, because every verb records
    /// an event and none records a row.
    @Test("GET /api/vms/:id/operations lists every recorded mutation")
    func historyListsRecordedMutations() async throws {
        try await withVMTestApp { app, user, vm, token in
            _ = try await record(.snapshot, on: vm, by: user, on: app.db)
            _ = try await record(.boot, on: vm, by: user, on: app.db)

            try await app.test(.GET, "/api/vms/\(vm.id!)/operations") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                let operations = try res.content.decode([OperationResponse].self)
                #expect(operations.map(\.kind) == [.boot, .snapshot])
            }
        }
    }

    // MARK: - Stuck-convergence sweep (STR-147)

    @Test("The sweep degrades a VM past its convergence deadline")
    func sweepDegradesOverdueConvergence() async throws {
        try await withVMTestApp { app, user, vm, _ in
            vm.setFixtureDesiredStatus(.running)
            vm.convergenceDeadline = Date().addingTimeInterval(-1)
            try await vm.save(on: app.db)
            _ = try await record(.boot, on: vm, by: user, on: app.db)

            await app.agentService.sweepStuckConvergence()

            let swept = try #require(try await VM.find(vm.id, on: app.db))
            #expect(swept.conditions.degraded?.reason.contains("Timed out") == true)
            // One behind the target: abandoning the unachieved intent is itself
            // a desired-state change, so the revert bumped the generation past
            // the one that failed.
            #expect(swept.conditions.degraded?.sinceGeneration == swept.generation - 1)
            // The deadline is cleared, so the row drops out of the next scan.
            #expect(swept.convergenceDeadline == nil)
            // The unachieved intent is abandoned rather than left to replay.
            #expect(swept.desiredStatus == .shutdown)
        }
    }

    @Test("The sweep is idempotent, so every replica can run it lock-free")
    func sweepIsIdempotent() async throws {
        try await withVMTestApp { app, user, vm, _ in
            vm.setFixtureDesiredStatus(.running)
            vm.convergenceDeadline = Date().addingTimeInterval(-1)
            try await vm.save(on: app.db)
            _ = try await record(.boot, on: vm, by: user, on: app.db)

            await app.agentService.sweepStuckConvergence()
            let first = try #require(try await VM.find(vm.id, on: app.db))
            let generation = first.generation
            let reason = first.lastError

            // A second pass — the other replica's, or the next tick's — finds
            // the deadline already claimed and changes nothing.
            await app.agentService.sweepStuckConvergence()

            let second = try #require(try await VM.find(vm.id, on: app.db))
            #expect(second.generation == generation)
            #expect(second.lastError == reason)
        }
    }

    /// A current-generation agent error may be a blocked report rather than a
    /// terminal verdict. The deadline claimant finalizes it, while keeping the
    /// agent's actionable reason instead of replacing it with a generic timeout.
    @Test("The sweep finalizes an already-degraded VM without losing its reason")
    func sweepFinalizesReportedFailure() async throws {
        try await withVMTestApp { app, user, vm, _ in
            vm.setFixtureDesiredStatus(.running)
            vm.setStatus(.running)
            vm.observedGeneration = vm.generation
            vm.lastError = "resize failed: no space left on device"
            vm.failedGeneration = vm.generation
            vm.convergenceDeadline = Date().addingTimeInterval(-1)
            try await vm.save(on: app.db)
            _ = try await record(.resize, on: vm, by: user, on: app.db)
            let generation = vm.generation

            await app.agentService.sweepStuckConvergence()

            let swept = try #require(try await VM.find(vm.id, on: app.db))
            #expect(swept.lastError == "resize failed: no space left on device")
            #expect(swept.generation == generation)
            #expect(swept.convergenceDeadline == nil)
        }
    }

    @Test("The sweep leaves a VM that converged before its deadline alone")
    func sweepIgnoresConvergedVM() async throws {
        try await withVMTestApp { app, _, vm, _ in
            vm.setFixtureDesiredStatus(.shutdown)
            vm.observedGeneration = vm.generation
            vm.convergenceDeadline = Date().addingTimeInterval(-1)
            try await vm.save(on: app.db)

            await app.agentService.sweepStuckConvergence()

            let swept = try #require(try await VM.find(vm.id, on: app.db))
            #expect(swept.conditions.degraded == nil)
            #expect(swept.convergenceDeadline == nil)
        }
    }

    @Test("A stuck delete degrades without resurrecting the VM")
    func sweepDoesNotRevertATerminatingVM() async throws {
        try await withVMTestApp { app, user, vm, _ in
            try await ResourceFinalizerService.stampForDeletion(vm, on: app.db)
            vm.setFixtureDesiredStatus(.absent)
            vm.convergenceDeadline = Date().addingTimeInterval(-1)
            try await vm.save(on: app.db)
            _ = try await record(.delete, on: vm, by: user, on: app.db)

            await app.agentService.sweepStuckConvergence()

            let swept = try #require(try await VM.find(vm.id, on: app.db))
            #expect(swept.conditions.degraded != nil)
            // `.absent` is the one intent never abandoned: reverting it would
            // resurrect a VM the user deleted.
            #expect(swept.desiredStatus == .absent)
        }
    }
}
