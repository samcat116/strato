import Testing
import Vapor
import Fluent
import VaporTesting
import StratoShared
@testable import App

/// Tests for the desired/observed state split and reconciliation phases 2-3
/// (issues #260, #261): mutations write desired state and bump the generation,
/// desired-state syncs are assembled from the database, observed-state reports
/// update status/generation and complete operations, deletions are confirmed
/// by absence, and registration requires a state-sync protocol version (the
/// imperative path is gone).
@Suite("Desired State Reconciliation Tests", .serialized)
final class DesiredStateReconciliationTests {

    /// Same harness as `VMOperationTests`: full middleware stack, mock SpiceDB,
    /// API-key auth, one VM.
    private func withVMTestApp(
        _ test: (Application, User, VM, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "reconuser",
                email: "recon@example.com",
                displayName: "Recon User",
                isSystemAdmin: false
            )
            let org = try await builder.createOrganization(name: "Recon Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            user.currentOrganizationId = org.id
            try await user.save(on: app.db)

            let project = try await builder.createProject(
                name: "Recon Project",
                description: "Project for reconciliation tests",
                organization: org
            )
            let vm = try await builder.createVM(name: "recon-vm", project: project)
            let token = try await user.generateAPIKey(on: app.db)

            try await test(app, user, vm, token)

        } catch {
            try await app.shutdownForTesting()
            throw error
        }

        try await app.shutdownForTesting()
    }

    /// Registers an in-memory agent with the given protocol version and maps
    /// the VM to it. Returns the agent's UUID string.
    private func registerAgent(
        app: Application,
        vm: VM,
        named agentName: String = "recon-agent",
        protocolVersion: Int?
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
            protocolVersion: protocolVersion
        )
        let orgID = try await Organization.query(on: app.db).sort(\.$createdAt).first()?.id
        let agentUUID = try await app.agentService.registerAgent(
            message, agentName: agentName,
            organizationScope: orgID.map { .organization($0) })
        vm.hypervisorId = agentUUID.uuidString
        try await vm.save(on: app.db)
        return agentUUID.uuidString
    }

    private func report(
        agentId: String,
        vms: [ObservedVMState]
    ) throws -> MessageEnvelope {
        let report = ObservedStateReport(
            agentId: agentId,
            vms: vms,
            resources: AgentResources(
                totalCPU: 16, availableCPU: 12,
                totalMemory: 1 << 34, availableMemory: 1 << 33,
                totalDisk: 1 << 40, availableDisk: 1 << 39
            )
        )
        return try MessageEnvelope(message: report)
    }

    // MARK: - Model defaults and generation bumps

    @Test("New VMs rest at desired shutdown with generation zero")
    func modelDefaults() async throws {
        try await withVMTestApp { _, _, vm, _ in
            #expect(vm.desiredStatus == .shutdown)
            #expect(vm.generation == 0)
            #expect(vm.observedGeneration == 0)

            vm.setDesiredStatus(.running)
            #expect(vm.desiredStatus == .running)
            #expect(vm.generation == 1)
        }
    }

    // MARK: - Mutations write desired state

    @Test("POST start writes desired running and bumps the generation")
    func startWritesDesiredState() async throws {
        try await withVMTestApp { app, _, vm, token in
            // An online agent owns the VM, so the desired state persists (an
            // unreachable agent would fail the operation and realign it).
            _ = try await self.registerAgent(app: app, vm: vm, protocolVersion: 2)

            try await app.test(.POST, "/api/vms/\(vm.id!)/start") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }

            let refreshed = try await VM.find(vm.id, on: app.db)
            #expect(refreshed?.desiredStatus == .running)
            #expect(refreshed?.generation == 1)
        }
    }

    @Test("POST start against an offline agent fails the operation fast")
    func startAgainstOfflineAgentFailsFast() async throws {
        try await withVMTestApp { app, _, vm, token in
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: 2)

            // The agent went dark: its row is offline cluster-wide.
            let agent = try #require(await app.agentService.getAgentInfo(agentId))
            agent.status = .offline
            try await agent.save(on: app.db)

            var operationId: UUID?
            try await app.test(.POST, "/api/vms/\(vm.id!)/start") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
                operationId = try res.content.decode(OperationResponse.self).id
            }

            // The dispatch fails immediately — not after the sweep budget.
            var operation: ResourceOperation?
            for _ in 0..<250 {
                operation = try await ResourceOperation.find(operationId, on: app.db)
                if operation?.status == .failed { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(operation?.status == .failed)
            #expect(operation?.error?.contains("offline") == true)

            // The unachieved intent was realigned: desired reverts to the
            // observed resting state instead of firing when the agent returns.
            // The VM row is written after the operation row, so poll it too.
            var refreshed: VM?
            for _ in 0..<100 {
                refreshed = try await VM.find(vm.id, on: app.db)
                if refreshed?.desiredStatus == .shutdown { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(refreshed?.desiredStatus == .shutdown)
        }
    }

    @Test("Start stores no transitional status; in-flight state is derived")
    func noTransitionalStatusOnStart() async throws {
        try await withVMTestApp { app, _, vm, token in
            _ = try await self.registerAgent(app: app, vm: vm, protocolVersion: 2)

            try await app.test(.POST, "/api/vms/\(vm.id!)/start") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }

            // No `.starting` marker on the sync path: in-flight state is
            // derived from desired != observed plus the pending operation.
            let refreshed = try await VM.find(vm.id, on: app.db)
            #expect(refreshed?.status == .created)
            #expect(refreshed?.desiredStatus == .running)
            #expect(refreshed?.generation == 1)

            // The operation stays pending until an observed report confirms.
            let pending = try await ResourceOperation.query(on: app.db)
                .filter(\.$resourceID == vm.id!)
                .filter(\.$status == .pending)
                .count()
            #expect(pending == 1)
        }
    }

    @Test("Registration requires a state-sync protocol version")
    func protocolVersionGate() async throws {
        try await withVMTestApp { app, _, vm, _ in
            // The imperative path is gone (issue #261): agents that predate
            // desired-state sync are refused at registration.
            await #expect(throws: AgentServiceError.self) {
                _ = try await self.registerAgent(
                    app: app, vm: vm, named: "old-agent", protocolVersion: 1)
            }
            await #expect(throws: AgentServiceError.self) {
                _ = try await self.registerAgent(
                    app: app, vm: vm, named: "legacy-agent", protocolVersion: nil)
            }

            // Refused agents leave no registry row behind.
            let rows = try await Agent.query(on: app.db).all()
            #expect(rows.isEmpty)

            // A state-sync agent registers fine.
            let v2Agent = try await self.registerAgent(
                app: app, vm: vm, named: "new-agent", protocolVersion: 2)
            let registered = await app.agentService.getAgentInfo(v2Agent)
            #expect(registered?.name == "new-agent")
            #expect(registered?.status == .online)
        }
    }

    // MARK: - Sync assembly

    @Test("Sync assembly lists the agent's VMs with desired status and generation")
    func syncAssemblyFromDatabase() async throws {
        try await withVMTestApp { app, _, vm, _ in
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: 2)

            vm.setDesiredStatus(.running)
            try await vm.save(on: app.db)

            let message = try await app.agentService.assembleDesiredState(agentId: agentId)
            #expect(message.vms.count == 1)
            let entry = try #require(message.vms.first)
            #expect(entry.vmId == vm.id)
            #expect(entry.desiredStatus == .running)
            #expect(entry.generation == 1)
            #expect(entry.hypervisorType == .qemu)
            #expect(entry.spec.cpus == vm.cpu)

            // VMs on other agents are not included.
            let other = try await app.agentService.assembleDesiredState(agentId: UUID().uuidString)
            #expect(other.vms.isEmpty)
        }
    }

    @Test("Sync assembly emits first-class network desired state for referenced networks")
    func syncAssemblyIncludesNetworks() async throws {
        try await withVMTestApp { app, _, vm, _ in
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: 2)

            // A project-scoped network the VM references via a NIC.
            let network = LogicalNetwork(
                name: "app-net",
                subnet: "10.20.0.0/24",
                gateway: "10.20.0.1",
                projectID: vm.$project.id,
                externalAccess: true,
                generation: 3
            )
            try await network.save(on: app.db)
            let nic = VMNetworkInterface(
                vmID: vm.id!, network: "app-net", macAddress: VMNetworkInterface.generateMACAddress())
            try await nic.save(on: app.db)

            let message = try await app.agentService.assembleDesiredState(agentId: agentId)
            let net = try #require(message.networks.first { $0.name == "app-net" })
            #expect(net.networkId == network.id)
            #expect(net.subnet == "10.20.0.0/24")
            #expect(net.gateway == "10.20.0.1")
            #expect(net.externalAccess)
            #expect(net.generation == 3)
            // DHCP config rides the network state so the level-triggered
            // network reconcile converges DHCP rows on live networks (DHCP
            // edits bump no generation and converged VMs never re-realize).
            #expect(net.dhcpEnabled == true)
            // Per-project router: the key is derived from the owning project.
            #expect(net.routerKey == "project-\(vm.$project.id.uuidString)")

            // A network no VM on this agent references is not synced to it.
            #expect(!message.networks.contains { $0.name == "unreferenced" })
        }
    }

    @Test("Sync assembly carries attached floating IPs on their network's desired state")
    func syncAssemblyIncludesFloatingIPs() async throws {
        try await withVMTestApp { app, user, vm, _ in
            let agentId = try await self.registerAgent(
                app: app, vm: vm, protocolVersion: WireProtocol.currentVersion)

            let network = LogicalNetwork(
                name: "fip-net", subnet: "10.30.0.0/24", gateway: "10.30.0.1",
                projectID: vm.$project.id, externalAccess: true)
            try await network.save(on: app.db)
            let nic = VMNetworkInterface(
                vmID: vm.id!, network: "fip-net", macAddress: VMNetworkInterface.generateMACAddress())
            try await nic.save(on: app.db)
            try await VMInterfaceAddress(
                interfaceID: nic.id!, network: "fip-net", family: .ipv4,
                address: "10.30.0.5", prefixLength: 24, gateway: "10.30.0.1"
            ).save(on: app.db)

            let pool = FloatingIPPool(name: "edge", cidr: "203.0.113.0/24", gateway: "203.0.113.1")
            try await pool.save(on: app.db)
            let attached = FloatingIP(
                poolID: pool.id!, address: "203.0.113.10", projectID: vm.$project.id,
                interfaceID: nic.id!, createdByID: user.id!)
            try await attached.save(on: app.db)
            // A reserved-but-unattached address must not produce a NAT rule.
            try await FloatingIP(
                poolID: pool.id!, address: "203.0.113.11", projectID: vm.$project.id,
                createdByID: user.id!
            ).save(on: app.db)

            let message = try await app.agentService.assembleDesiredState(agentId: agentId)
            let net = try #require(message.networks.first { $0.name == "fip-net" })
            let fips = try #require(net.floatingIPs)
            #expect(fips.count == 1)
            #expect(fips[0].externalIP == "203.0.113.10")
            #expect(fips[0].logicalIP == "10.30.0.5")
            #expect(fips[0].vmId == vm.id)
            #expect(fips[0].nicIndex == 0)

            // Another agent's sync must not carry this VM's floating IP.
            let other = try await app.agentService.assembleDesiredState(agentId: UUID().uuidString)
            #expect(!other.networks.contains { ($0.floatingIPs ?? []).isEmpty == false })
        }
    }

    @Test("Sync assembly omits floating IPs for pre-v12 agents")
    func syncAssemblyOmitsFloatingIPsForOldAgents() async throws {
        try await withVMTestApp { app, user, vm, _ in
            // An agent from before the floating IP protocol: it would decode
            // and silently ignore the field, so assembly must not claim the
            // sync carries NAT intent it cannot realize.
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: 11)

            let network = LogicalNetwork(
                name: "fip-old-net", subnet: "10.31.0.0/24", gateway: "10.31.0.1",
                projectID: vm.$project.id, externalAccess: true)
            try await network.save(on: app.db)
            let nic = VMNetworkInterface(
                vmID: vm.id!, network: "fip-old-net", macAddress: VMNetworkInterface.generateMACAddress())
            try await nic.save(on: app.db)
            try await VMInterfaceAddress(
                interfaceID: nic.id!, network: "fip-old-net", family: .ipv4,
                address: "10.31.0.5", prefixLength: 24, gateway: "10.31.0.1"
            ).save(on: app.db)
            let pool = FloatingIPPool(name: "edge-old", cidr: "198.51.100.0/24")
            try await pool.save(on: app.db)
            try await FloatingIP(
                poolID: pool.id!, address: "198.51.100.10", projectID: vm.$project.id,
                interfaceID: nic.id!, createdByID: user.id!
            ).save(on: app.db)

            let message = try await app.agentService.assembleDesiredState(agentId: agentId)
            let net = try #require(message.networks.first { $0.name == "fip-old-net" })
            #expect(net.floatingIPs == nil)
        }
    }

    // MARK: - Observed-state report application

    @Test("A converged report updates status, generation, and completes the operation")
    func reportCompletesOperation() async throws {
        try await withVMTestApp { app, user, vm, _ in
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: 2)

            vm.setDesiredStatus(.running)
            try await vm.save(on: app.db)
            let operation = ResourceOperation(vmID: vm.id!, userID: user.id!, kind: .boot)
            try await operation.save(on: app.db)

            let envelope = try self.report(
                agentId: agentId,
                vms: [ObservedVMState(vmId: vm.id!, status: .running, observedGeneration: 1)]
            )
            await app.agentService.applyObservedStateReport(envelope, fromAgentNamed: "recon-agent")

            let refreshed = try await VM.find(vm.id, on: app.db)
            #expect(refreshed?.status == .running)
            #expect(refreshed?.observedGeneration == 1)

            let completed = try await ResourceOperation.find(operation.id, on: app.db)
            #expect(completed?.status == .succeeded)
        }
    }

    @Test("A convergence failure fails the pending operation with the agent's error")
    func reportFailsOperationWithError() async throws {
        try await withVMTestApp { app, user, vm, _ in
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: 2)

            vm.setDesiredStatus(.running)
            try await vm.save(on: app.db)
            let operation = ResourceOperation(vmID: vm.id!, userID: user.id!, kind: .boot)
            try await operation.save(on: app.db)

            // Generation 1 was attempted and failed; the agent reports the
            // failure tagged with the generation that produced it.
            let envelope = try self.report(
                agentId: agentId,
                vms: [
                    ObservedVMState(
                        vmId: vm.id!, status: .shutdown, observedGeneration: 0,
                        lastError: "boot failed: no bootable device",
                        failedGeneration: 1)
                ]
            )
            await app.agentService.applyObservedStateReport(envelope, fromAgentNamed: "recon-agent")

            let failed = try await ResourceOperation.find(operation.id, on: app.db)
            #expect(failed?.status == .failed)
            #expect(failed?.error == "boot failed: no bootable device")

            // The unachieved intent must not linger: desired realigns with the
            // observed resting state (and bumps the generation).
            let refreshed = try await VM.find(vm.id, on: app.db)
            #expect(refreshed?.desiredStatus == .shutdown)
            #expect(refreshed?.generation == 2)
        }
    }

    @Test("A stale error from a previous generation does not fail a fresh operation")
    func staleErrorFromPreviousGenerationIgnored() async throws {
        try await withVMTestApp { app, user, vm, _ in
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: 2)

            // Boot at generation 1 failed and capped out; the user retried,
            // minting generation 2 and a fresh pending operation.
            vm.setDesiredStatus(.running)  // gen 1
            vm.setDesiredStatus(.running)  // gen 2 (retry)
            try await vm.save(on: app.db)
            let operation = ResourceOperation(vmID: vm.id!, userID: user.id!, kind: .boot)
            try await operation.save(on: app.db)

            // A heartbeat report still carrying generation 1's error arrives
            // before the agent attempts generation 2.
            let envelope = try self.report(
                agentId: agentId,
                vms: [
                    ObservedVMState(
                        vmId: vm.id!, status: .shutdown, observedGeneration: 1,
                        lastError: "boot failed at generation 1",
                        failedGeneration: 1)
                ]
            )
            await app.agentService.applyObservedStateReport(envelope, fromAgentNamed: "recon-agent")

            // The fresh operation must not be failed by the stale error.
            let stillPending = try await ResourceOperation.find(operation.id, on: app.db)
            #expect(stillPending?.status == .pending)
        }
    }

    @Test("Progress-only entries neither settle status nor complete operations")
    func convergingEntriesAreProgressOnly() async throws {
        try await withVMTestApp { app, user, vm, _ in
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: 2)

            vm.setDesiredStatus(.running)
            try await vm.save(on: app.db)
            let operation = ResourceOperation(vmID: vm.id!, userID: user.id!, kind: .create)
            try await operation.save(on: app.db)

            let envelope = try self.report(
                agentId: agentId,
                vms: [
                    ObservedVMState(
                        vmId: vm.id!, status: .unknown, observedGeneration: 0,
                        convergencePhase: "downloading image")
                ]
            )
            await app.agentService.applyObservedStateReport(envelope, fromAgentNamed: "recon-agent")

            let refreshed = try await VM.find(vm.id, on: app.db)
            #expect(refreshed?.status == .created)  // untouched

            let stillPending = try await ResourceOperation.find(operation.id, on: app.db)
            #expect(stillPending?.status == .pending)
        }
    }

    @Test("Absence with desired absent confirms deletion: row removed, operation succeeded")
    func absenceConfirmsDeletion() async throws {
        try await withVMTestApp { app, user, vm, _ in
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: 2)

            vm.setDesiredStatus(.absent)
            try await vm.save(on: app.db)
            let operation = ResourceOperation(vmID: vm.id!, userID: user.id!, kind: .delete)
            try await operation.save(on: app.db)

            // Full-list semantics: the VM is missing from the agent's report.
            let envelope = try self.report(agentId: agentId, vms: [])
            await app.agentService.applyObservedStateReport(envelope, fromAgentNamed: "recon-agent")

            let gone = try await VM.find(vm.id, on: app.db)
            #expect(gone == nil)

            let completed = try await ResourceOperation.find(operation.id, on: app.db)
            #expect(completed?.status == .succeeded)
        }
    }

    @Test("Absence of an established VM that should exist marks it as error")
    func absenceOfEstablishedVMIsDrift() async throws {
        try await withVMTestApp { app, _, vm, _ in
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: 2)

            vm.setDesiredStatus(.running)
            vm.setStatus(.running)
            try await vm.save(on: app.db)

            let envelope = try self.report(agentId: agentId, vms: [])
            await app.agentService.applyObservedStateReport(envelope, fromAgentNamed: "recon-agent")

            let refreshed = try await VM.find(vm.id, on: app.db)
            #expect(refreshed?.status == .error)
        }
    }

    @Test("A never-established VM absent from the report is left alone")
    func absenceOfFreshVMIsIgnored() async throws {
        try await withVMTestApp { app, _, vm, _ in
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: 2)

            // `.created` may be mid-create on an agent that hasn't received
            // the sync yet — absence must not escalate it.
            vm.setDesiredStatus(.running)
            try await vm.save(on: app.db)

            let envelope = try self.report(agentId: agentId, vms: [])
            await app.agentService.applyObservedStateReport(envelope, fromAgentNamed: "recon-agent")

            let refreshed = try await VM.find(vm.id, on: app.db)
            #expect(refreshed?.status == .created)
        }
    }

    @Test("Out-of-band drift is applied and detected without a pending operation")
    func driftDetectedWithoutOperation() async throws {
        try await withVMTestApp { app, _, vm, _ in
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: 2)

            vm.setDesiredStatus(.running)
            vm.setStatus(.running)
            vm.observedGeneration = 1
            try await vm.save(on: app.db)

            // The guest paused itself out of band; no operation asked for it.
            let envelope = try self.report(
                agentId: agentId,
                vms: [ObservedVMState(vmId: vm.id!, status: .paused, observedGeneration: 1)]
            )
            await app.agentService.applyObservedStateReport(envelope, fromAgentNamed: "recon-agent")

            let refreshed = try await VM.find(vm.id, on: app.db)
            #expect(refreshed?.status == .paused)
        }
    }

    @Test("A report claiming another agent's identity is ignored")
    func reportOwnershipValidated() async throws {
        try await withVMTestApp { app, _, vm, _ in
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: 2)

            vm.setDesiredStatus(.running)
            try await vm.save(on: app.db)

            let envelope = try self.report(
                agentId: agentId,
                vms: [ObservedVMState(vmId: vm.id!, status: .running, observedGeneration: 1)]
            )
            // Delivered over a connection authenticated as a different agent.
            await app.agentService.applyObservedStateReport(envelope, fromAgentNamed: "impostor")

            let refreshed = try await VM.find(vm.id, on: app.db)
            #expect(refreshed?.status == .created)
            #expect(refreshed?.observedGeneration == 0)
        }
    }

    // MARK: - Guest agent (qga) observed info (issue #563)

    @Test("A report's guestInfo persists hostname, availability, and per-MAC observed addresses")
    func guestInfoPersisted() async throws {
        try await withVMTestApp { app, _, vm, _ in
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: 15)

            // A NIC to attribute the guest's addresses to, by MAC.
            let nic = VMNetworkInterface(
                vmID: vm.id!, network: "default", macAddress: "52:54:00:ab:cd:ef", deviceName: "net0")
            try await nic.save(on: app.db)

            let guestInfo = GuestInfo(
                qgaAvailable: true,
                hostname: "web-01",
                interfaces: [
                    // Reported with an uppercase MAC to prove case-insensitive matching.
                    GuestNetworkInterface(
                        name: "enp0s3",
                        hardwareAddress: "52:54:00:AB:CD:EF",
                        addresses: [
                            GuestIPAddress(family: .ipv4, address: "10.0.0.5", prefixLength: 24),
                            GuestIPAddress(family: .ipv6, address: "fe80::5054:ff:feab:cdef", prefixLength: 64),
                        ]),
                    // An interface with no matching NIC is simply ignored.
                    GuestNetworkInterface(name: "docker0", hardwareAddress: "02:42:00:00:00:01", addresses: []),
                ])
            let envelope = try self.report(
                agentId: agentId,
                vms: [ObservedVMState(vmId: vm.id!, status: .running, observedGeneration: 1, guestInfo: guestInfo)]
            )
            await app.agentService.applyObservedStateReport(envelope, fromAgentNamed: "recon-agent")

            let refreshed = try #require(try await VM.find(vm.id, on: app.db))
            #expect(refreshed.qgaAvailable == true)
            #expect(refreshed.observedHostname == "web-01")

            let observed = try await VMInterfaceObservedAddress.query(on: app.db)
                .filter(\.$interface.$id == nic.id!)
                .all()
            #expect(observed.count == 2)
            #expect(
                observed.contains {
                    $0.address == "10.0.0.5" && $0.family == IPFamily.ipv4.rawValue && $0.prefixLength == 24
                })
            #expect(
                observed.contains {
                    $0.address == "fe80::5054:ff:feab:cdef" && $0.family == IPFamily.ipv6.rawValue
                })
        }
    }

    @Test("A later report reconciles observed addresses; a nil guestInfo leaves them intact")
    func guestInfoReconciledAndPreservedOnNil() async throws {
        try await withVMTestApp { app, _, vm, _ in
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: 15)
            let nic = VMNetworkInterface(
                vmID: vm.id!, network: "default", macAddress: "52:54:00:ab:cd:ef", deviceName: "net0")
            try await nic.save(on: app.db)

            func send(_ guestInfo: GuestInfo?) async throws {
                let envelope = try self.report(
                    agentId: agentId,
                    vms: [ObservedVMState(vmId: vm.id!, status: .running, observedGeneration: 1, guestInfo: guestInfo)]
                )
                await app.agentService.applyObservedStateReport(envelope, fromAgentNamed: "recon-agent")
            }

            // First: the guest has a DHCP address.
            try await send(
                GuestInfo(
                    qgaAvailable: true, hostname: "h1",
                    interfaces: [
                        GuestNetworkInterface(
                            name: "eth0", hardwareAddress: "52:54:00:ab:cd:ef",
                            addresses: [GuestIPAddress(family: .ipv4, address: "10.0.0.5", prefixLength: 24)])
                    ]))
            var rows = try await VMInterfaceObservedAddress.query(on: app.db).filter(\.$interface.$id == nic.id!).all()
            #expect(rows.map(\.address) == ["10.0.0.5"])

            // The lease changed: the set is reconciled wholesale to the new address.
            try await send(
                GuestInfo(
                    qgaAvailable: true, hostname: "h1",
                    interfaces: [
                        GuestNetworkInterface(
                            name: "eth0", hardwareAddress: "52:54:00:ab:cd:ef",
                            addresses: [GuestIPAddress(family: .ipv4, address: "10.0.0.9", prefixLength: 24)])
                    ]))
            rows = try await VMInterfaceObservedAddress.query(on: app.db).filter(\.$interface.$id == nic.id!).all()
            #expect(rows.map(\.address) == ["10.0.0.9"])

            // A report without guestInfo (e.g. a transient probe miss) must NOT
            // wipe the last-known observed addresses.
            try await send(nil)
            rows = try await VMInterfaceObservedAddress.query(on: app.db).filter(\.$interface.$id == nic.id!).all()
            #expect(rows.map(\.address) == ["10.0.0.9"])
        }
    }

    @Test("A nil guestInfo on a stopped VM clears the stale qga view")
    func guestInfoClearedWhenNotRunning() async throws {
        try await withVMTestApp { app, _, vm, _ in
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: 15)
            let nic = VMNetworkInterface(
                vmID: vm.id!, network: "default", macAddress: "52:54:00:ab:cd:ef", deviceName: "net0")
            try await nic.save(on: app.db)

            func send(status: VMStatus, guestInfo: GuestInfo?) async throws {
                let envelope = try self.report(
                    agentId: agentId,
                    vms: [ObservedVMState(vmId: vm.id!, status: status, observedGeneration: 1, guestInfo: guestInfo)]
                )
                await app.agentService.applyObservedStateReport(envelope, fromAgentNamed: "recon-agent")
            }

            // Running with a live guest agent: hostname, availability, addresses recorded.
            try await send(
                status: .running,
                guestInfo: GuestInfo(
                    qgaAvailable: true, hostname: "web-01",
                    interfaces: [
                        GuestNetworkInterface(
                            name: "eth0", hardwareAddress: "52:54:00:ab:cd:ef",
                            addresses: [GuestIPAddress(family: .ipv4, address: "10.0.0.5", prefixLength: 24)])
                    ]))
            #expect(try await VM.find(vm.id, on: app.db)?.qgaAvailable == true)

            // The VM is now observed shut down with no guest info: the stale qga
            // view (which would otherwise persist forever) is cleared.
            try await send(status: .shutdown, guestInfo: nil)
            let refreshed = try #require(try await VM.find(vm.id, on: app.db))
            #expect(refreshed.qgaAvailable == nil)
            #expect(refreshed.observedHostname == nil)
            let rows = try await VMInterfaceObservedAddress.query(on: app.db)
                .filter(\.$interface.$id == nic.id!).all()
            #expect(rows.isEmpty)
        }
    }
}
