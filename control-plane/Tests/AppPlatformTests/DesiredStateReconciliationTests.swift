import Testing
import Vapor
import Fluent
import VaporTesting
import StratoShared
import AppTestSupport
@testable import App

/// Tests for the desired/observed state split and reconciliation phases 2-3
/// (issues #260, #261): mutations write desired state and bump the generation,
/// desired-state syncs are assembled from the database, observed-state reports
/// update status/generation and complete operations, deletions are confirmed
/// by absence, and registration requires a state-sync protocol version (the
/// imperative path is gone).
@Suite("Desired State Reconciliation Tests", .serialized)
final class DesiredStateReconciliationTests {

    private static func healthyOverlayObservation(at checkedAt: Date = Date())
        -> NodeDependencyObservation
    {
        NodeDependencyObservation(
            id: .ovnOvs,
            role: .networking,
            desiredState: .required,
            ownership: .observeOnly,
            supervisorState: .active,
            compatibility: .compatible,
            functionalState: .healthy,
            checkedAt: checkedAt,
            lastHealthyAt: checkedAt,
            affectedCapabilities: [.overlayNetworking])
    }

    /// A network in the VM's project for a NIC to reference, created on first
    /// use. Nothing provisions one with a project (issue #765), and these tests
    /// only need the NIC to point somewhere real.
    private func network(app: Application, vm: VM, named name: String = "default") async throws
        -> LogicalNetwork
    {
        let projectID = vm.$project.id
        if let existing = try await LogicalNetwork.query(on: app.db)
            .filter(\.$project.$id == projectID)
            .filter(\.$name == name)
            .first()
        {
            return existing
        }
        let project = try #require(try await Project.find(projectID, on: app.db))
        let siteID = try await TestDataBuilder(db: app.db).placementSite(for: project).requireID()
        let network = LogicalNetwork(
            name: name, subnet: "192.168.1.0/24", gateway: "192.168.1.1", projectID: projectID,
            siteID: siteID)
        try await network.save(on: app.db)
        return network
    }

    /// Same harness as `VMOperationTests`: full middleware stack, API-key
    /// auth, one VM.
    private func withVMTestApp(
        _ test: (Application, User, VM, String) async throws -> Void
    ) async throws {
        try await withProjectApp(prefix: "recon") { app, builder, fixture in
            let vm = try await builder.createVM(name: "recon-vm", project: fixture.project)
            try await test(app, fixture.user, vm, fixture.token)
        }
    }

    /// Registers an in-memory agent with the given protocol version and maps
    /// the VM to it. Returns the agent's UUID string.
    private func registerAgent(
        app: Application,
        vm: VM,
        named agentName: String = "recon-agent",
        protocolVersion: Int,
        placeVM: Bool = true
    ) async throws -> String {
        let project = try #require(try await Project.find(vm.$project.id, on: app.db))
        let siteID = try await TestDataBuilder(db: app.db).placementSite(for: project).requireID()
        let registeredID = try await TestDataBuilder(db: app.db).registerAgent(
            on: app,
            named: agentName,
            hostname: "test-host",
            networkCapability: .overlay,
            protocolVersion: protocolVersion,
            dependencyObservations: [Self.healthyOverlayObservation()],
            siteID: siteID)
        let agentUUID = try #require(UUID(uuidString: registeredID))
        let site = try #require(try await Site.find(siteID, on: app.db))
        if site.$networkControllerAgent.id == nil {
            site.$networkControllerAgent.id = agentUUID
            try await site.save(on: app.db)
        }
        if placeVM {
            vm.hypervisorId = agentUUID.uuidString
            try await vm.save(on: app.db)
        }
        return registeredID
    }

    private func report(
        agentId: String,
        vms: [ObservedVMState],
        networks: [ObservedNetworkState]? = nil,
        securityGroups: [ObservedSecurityGroupState]? = nil,
        portMemberships: [ObservedPortMembershipState]? = nil,
        manifestStatus: ObservedManifestStatus? = nil
    ) throws -> MessageEnvelope {
        let report = ObservedStateReport(
            agentId: agentId,
            vms: vms,
            resources: AgentResources(
                totalCPU: 16, availableCPU: 12,
                totalMemory: 1 << 34, availableMemory: 1 << 33,
                totalDisk: 1 << 40, availableDisk: 1 << 39
            ),
            manifestStatus: manifestStatus,
            networks: networks,
            securityGroups: securityGroups,
            portMemberships: portMemberships
        )
        return try MessageEnvelope(message: report)
    }

    // MARK: - Model defaults and state-only helpers

    @Test("New VMs rest at generation zero and desired helpers do not advance it")
    func modelDefaults() async throws {
        try await withVMTestApp { _, _, vm, _ in
            #expect(vm.desiredStatus == .shutdown)
            #expect(vm.generation == 0)
            #expect(vm.observedGeneration == 0)

            vm.setDesiredStatus(.running)
            #expect(vm.desiredStatus == .running)
            #expect(vm.generation == 0)
        }
    }

    // MARK: - Mutations write desired state

    @Test("POST start writes desired running and bumps the generation")
    func startWritesDesiredState() async throws {
        try await withVMTestApp { app, _, vm, token in
            // An online agent owns the VM, so the desired state persists (an
            // unreachable agent would fail the operation and realign it).
            _ = try await self.registerAgent(app: app, vm: vm, protocolVersion: WireProtocol.currentVersion)

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

    @Test("POST start against an offline agent degrades the VM fast")
    func startAgainstOfflineAgentFailsFast() async throws {
        try await withVMTestApp { app, _, vm, token in
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: WireProtocol.currentVersion)

            // The agent went dark: its row is offline cluster-wide.
            let agent = try #require(await app.agentService.getAgentInfo(agentId))
            agent.status = .offline
            try await agent.save(on: app.db)

            var targetGeneration: Int64?
            try await app.test(.POST, "/api/vms/\(vm.id!)/start") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
                targetGeneration = try res.content.decode(
                    AcceptedMutation<VMDetailResponse>.self
                ).targetGeneration
            }

            // The dispatch fails immediately — not after the convergence
            // deadline — and the unachieved intent is realigned: desired
            // reverts to the observed resting state instead of firing when the
            // agent returns.
            var refreshed: VM?
            for _ in 0..<250 {
                refreshed = try await VM.find(vm.id, on: app.db)
                if refreshed?.conditions.degraded != nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let degraded = try #require(refreshed?.conditions.degraded)
            #expect(degraded.reason.contains("offline"))
            #expect(degraded.sinceGeneration == targetGeneration)
            #expect(refreshed?.desiredStatus == .shutdown)
        }
    }

    @Test("Start stores no transitional status; in-flight state is derived")
    func noTransitionalStatusOnStart() async throws {
        try await withVMTestApp { app, _, vm, token in
            _ = try await self.registerAgent(app: app, vm: vm, protocolVersion: WireProtocol.currentVersion)

            try await app.test(.POST, "/api/vms/\(vm.id!)/start") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }

            // No `.starting` marker on the sync path: in-flight state is the
            // gap between desired and observed.
            let refreshed = try #require(await VM.find(vm.id, on: app.db))
            #expect(refreshed.status == .created)
            #expect(refreshed.desiredStatus == .running)
            #expect(refreshed.generation == 1)

            // Unconverged until an observed report confirms, with a deadline
            // for the stuck-convergence sweep to judge it against (STR-147).
            #expect(!refreshed.conditions.converged)
            #expect(refreshed.conditions.observedGeneration == 0)
            #expect(refreshed.convergenceDeadline != nil)
        }
    }

    @Test("Registration requires the exact current protocol version")
    func protocolVersionGate() async throws {
        try await withVMTestApp { app, _, vm, _ in
            // Control plane and agents deploy in lockstep: older and future
            // contracts are both refused before creating an agent row.
            await #expect(throws: AgentServiceError.self) {
                _ = try await self.registerAgent(
                    app: app, vm: vm, named: "old-agent",
                    protocolVersion: WireProtocol.currentVersion - 1)
            }
            await #expect(throws: AgentServiceError.self) {
                _ = try await self.registerAgent(
                    app: app, vm: vm, named: "future-agent",
                    protocolVersion: WireProtocol.currentVersion + 1)
            }

            // Refused agents leave no registry row behind.
            let rows = try await Agent.query(on: app.db).all()
            #expect(rows.isEmpty)

            // An exactly matching agent registers fine.
            let current = try await self.registerAgent(
                app: app, vm: vm, named: "new-agent",
                protocolVersion: WireProtocol.currentVersion)
            let registered = await app.agentService.getAgentInfo(current)
            #expect(registered?.name == "new-agent")
            #expect(registered?.status == .online)
        }
    }

    // MARK: - Sync assembly

    @Test("Sync assembly lists the agent's VMs with desired status and generation")
    func syncAssemblyFromDatabase() async throws {
        try await withVMTestApp { app, _, vm, _ in
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: WireProtocol.currentVersion)
            try await attachBootVolume(to: vm, on: agentId, using: app.db)

            vm.setFixtureDesiredStatus(.running)
            try await vm.save(on: app.db)

            let message = try await app.desiredStateAssembler.assemble(agentId: agentId)
            #expect(message.vms.count == 1)
            let entry = try #require(message.vms.first)
            #expect(entry.vmId == vm.id)
            #expect(entry.desiredStatus == .running)
            #expect(entry.generation == 1)
            #expect(entry.hypervisorType == .qemu)
            #expect(entry.spec.cpus == vm.cpu)

            // VMs on other agents are not included.
            let otherAgentID = try await self.registerAgent(
                app: app, vm: vm, named: "recon-idle-agent",
                protocolVersion: WireProtocol.currentVersion, placeVM: false)
            let other = try await app.desiredStateAssembler.assemble(agentId: otherAgentID)
            #expect(other.vms.isEmpty)
        }
    }

    @Test("Sync assembly emits first-class network desired state for referenced networks")
    func syncAssemblyIncludesNetworks() async throws {
        try await withVMTestApp { app, _, vm, _ in
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: WireProtocol.currentVersion)
            try await attachBootVolume(to: vm, on: agentId, using: app.db)
            let project = try #require(try await Project.find(vm.$project.id, on: app.db))
            let siteID = try await TestDataBuilder(db: app.db).placementSite(for: project).requireID()

            // A project-scoped network the VM references via a NIC.
            let network = LogicalNetwork(
                name: "app-net",
                subnet: "10.20.0.0/24",
                gateway: "10.20.0.1",
                projectID: vm.$project.id,
                externalAccess: true,
                generation: 3,
                siteID: siteID
            )
            try await network.save(on: app.db)
            let nic = VMNetworkInterface(
                vmID: vm.id!, logicalNetworkID: try network.requireID(),
                macAddress: MACAllocator.generateCandidate().description)
            try await nic.save(on: app.db)

            let message = try await app.desiredStateAssembler.assemble(agentId: agentId)
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
            try await attachBootVolume(to: vm, on: agentId, using: app.db)
            let project = try #require(try await Project.find(vm.$project.id, on: app.db))
            let siteID = try await TestDataBuilder(db: app.db).placementSite(for: project).requireID()

            let network = LogicalNetwork(
                name: "fip-net", subnet: "10.30.0.0/24", gateway: "10.30.0.1",
                projectID: vm.$project.id, externalAccess: true, siteID: siteID)
            try await network.save(on: app.db)
            let networkID = try network.requireID()
            let net0 = VMNetworkInterface(
                vmID: vm.id!, logicalNetworkID: networkID,
                macAddress: MACAllocator.generateCandidate().description,
                deviceName: "net0", orderIndex: 0)
            try await net0.save(on: app.db)
            let net1 = VMNetworkInterface(
                vmID: vm.id!, logicalNetworkID: networkID,
                macAddress: MACAllocator.generateCandidate().description,
                deviceName: "net1", orderIndex: 1)
            net1.detachGeneration = vm.generation
            try await net1.save(on: app.db)
            let nic = VMNetworkInterface(
                vmID: vm.id!, logicalNetworkID: networkID,
                macAddress: MACAllocator.generateCandidate().description,
                deviceName: "net2", orderIndex: 2)
            try await nic.save(on: app.db)
            try await VMInterfaceAddress(
                interfaceID: nic.id!, logicalNetworkID: networkID, family: .ipv4,
                address: "10.30.0.5", prefixLength: 24, gateway: "10.30.0.1"
            ).save(on: app.db)

            let pool = FloatingIPPool(
                name: "edge", cidr: "203.0.113.0/24", gateway: "203.0.113.1", siteID: siteID)
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

            let message = try await app.desiredStateAssembler.assemble(agentId: agentId)
            let net = try #require(message.networks.first { $0.name == "fip-net" })
            let fips = net.floatingIPs
            #expect(fips.count == 1)
            #expect(fips[0].externalIP == "203.0.113.10")
            #expect(fips[0].logicalIP == "10.30.0.5")
            #expect(fips[0].vmId == vm.id)
            #expect(fips[0].nicIndex == 2)

            // Another agent's sync must not carry this VM's floating IP.
            let otherAgentID = try await self.registerAgent(
                app: app, vm: vm, named: "recon-idle-fip-agent",
                protocolVersion: WireProtocol.currentVersion, placeVM: false)
            let other = try await app.desiredStateAssembler.assemble(agentId: otherAgentID)
            #expect(!other.networks.contains { !$0.floatingIPs.isEmpty })
        }
    }

    // MARK: - Observed-state report application

    @Test("A detaching NIC retains related rows until an authoritative applied-ID report omits it")
    func detachedNICCleanupWaitsForAgentConfirmation() async throws {
        try await withVMTestApp { app, user, vm, _ in
            let agentId = try await self.registerAgent(
                app: app, vm: vm, protocolVersion: WireProtocol.currentVersion)
            let network = try await self.network(app: app, vm: vm, named: "detach-net")
            let networkID = try network.requireID()

            let initialGeneration = vm.generation
            #expect(
                try await vm.advanceDesiredStateGeneration(
                    expectedGeneration: initialGeneration, on: app.db)
                    == .applied(initialGeneration + 1))
            let nic = VMNetworkInterface(
                vmID: try vm.requireID(), logicalNetworkID: networkID,
                macAddress: "52:54:00:de:7a:01", deviceName: "net0", orderIndex: 0)
            nic.attachGeneration = 0
            nic.detachGeneration = vm.generation
            try await nic.save(on: app.db)
            let nicID = try nic.requireID()
            let address = VMInterfaceAddress(
                interfaceID: nicID, logicalNetworkID: networkID, family: .ipv4,
                address: "192.168.1.50", prefixLength: 24, gateway: "192.168.1.1")
            try await address.save(on: app.db)
            let group = try await SecurityGroupService.ensureDefaultGroup(
                projectID: vm.$project.id, on: app.db)
            let membership = VMInterfaceSecurityGroup(
                interfaceID: nicID, securityGroupID: try group.requireID())
            try await membership.save(on: app.db)
            let pool = FloatingIPPool(
                name: "detach-pool", cidr: "203.0.113.0/24", gateway: "203.0.113.1",
                siteID: network.$site.id)
            try await pool.save(on: app.db)
            let floatingIP = FloatingIP(
                poolID: try pool.requireID(), address: "203.0.113.50",
                projectID: vm.$project.id, interfaceID: nicID,
                createdByID: try user.requireID())
            try await floatingIP.save(on: app.db)

            func apply(appliedIDs: [UUID]) async throws {
                let envelope = try self.report(
                    agentId: agentId,
                    vms: [
                        ObservedVMState(
                            vmId: try vm.requireID(), status: .shutdown,
                            observedGeneration: vm.generation,
                            appliedNetworkInterfaceIds: appliedIDs)
                    ])
                await app.agentService.applyObservedStateReport(
                    envelope, fromAgentKey: agentKey("recon-agent"))
            }

            // A settled generation alone is insufficient: the durable agent
            // manifest still says this NIC is applied, so every related row is
            // retained for a safe retry.
            try await apply(appliedIDs: [nicID])
            #expect(try await VMNetworkInterface.find(nicID, on: app.db) != nil)
            #expect(try await VMInterfaceAddress.find(address.id, on: app.db) != nil)
            #expect(try await VMInterfaceSecurityGroup.find(membership.id, on: app.db) != nil)
            #expect(try await FloatingIP.find(floatingIP.id, on: app.db)?.$interface.id == nicID)

            // Only an explicit, authoritative absence releases the retained
            // NIC. Its FK cascades release leases and memberships; the
            // floating IP allocation remains reserved but becomes unattached.
            try await apply(appliedIDs: [])
            #expect(try await VMNetworkInterface.find(nicID, on: app.db) == nil)
            #expect(try await VMInterfaceAddress.find(address.id, on: app.db) == nil)
            #expect(try await VMInterfaceSecurityGroup.find(membership.id, on: app.db) == nil)
            #expect(try await FloatingIP.find(floatingIP.id, on: app.db)?.$interface.id == nil)
        }
    }

    @Test("A converged report updates status and generation, and clears the deadline")
    func reportRecordsConvergence() async throws {
        try await withVMTestApp { app, _, vm, _ in
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: WireProtocol.currentVersion)

            vm.setFixtureDesiredStatus(.running)
            vm.extendConvergenceDeadline(by: 600)
            try await vm.save(on: app.db)

            let envelope = try self.report(
                agentId: agentId,
                vms: [ObservedVMState(vmId: vm.id!, status: .running, observedGeneration: 1)]
            )
            await app.agentService.applyObservedStateReport(envelope, fromAgentKey: agentKey("recon-agent"))

            let refreshed = try #require(await VM.find(vm.id, on: app.db))
            #expect(refreshed.status == .running)
            #expect(refreshed.observedGeneration == 1)
            #expect(refreshed.conditions.converged)
            // Converged means nothing is outstanding to time out.
            #expect(refreshed.convergenceDeadline == nil)
        }
    }

    @Test("Fabric failures become degraded conditions and membership errors")
    func fabricFailuresArePersisted() async throws {
        try await withVMTestApp { app, _, vm, _ in
            let agentId = try await self.registerAgent(
                app: app, vm: vm, protocolVersion: WireProtocol.currentVersion)
            let network = try await self.network(app: app, vm: vm, named: "observed-fabric")
            network.generation = 2
            network.convergenceDeadline = Date().addingTimeInterval(300)
            try await network.save(on: app.db)

            let group = try await SecurityGroupService.ensureDefaultGroup(
                projectID: vm.$project.id, on: app.db)
            group.generation = 3
            group.convergenceDeadline = Date().addingTimeInterval(300)
            try await group.save(on: app.db)

            let nic = VMNetworkInterface(
                vmID: try vm.requireID(), logicalNetworkID: try network.requireID(),
                macAddress: "52:54:00:29:40:01", deviceName: "net0", orderIndex: 0)
            try await nic.save(on: app.db)
            let membership = VMInterfaceSecurityGroup(
                interfaceID: try nic.requireID(), securityGroupID: try group.requireID())
            try await membership.save(on: app.db)
            try await SecurityGroupSiteObservation(
                securityGroupID: try group.requireID(), siteID: network.$site.id
            ).save(on: app.db)

            let envelope = try self.report(
                agentId: agentId,
                vms: [],
                networks: [
                    ObservedNetworkState(
                        id: try network.requireID(), observedGeneration: 0, status: .error,
                        lastError: "OVSDB unavailable", failedGeneration: 2,
                        failureClassification: .transient)
                ],
                securityGroups: [
                    ObservedSecurityGroupState(
                        id: try group.requireID(), observedGeneration: 0, status: .error,
                        lastError: "ACL match rejected", failedGeneration: 3,
                        failureClassification: .permanent)
                ],
                portMemberships: [
                    ObservedPortMembershipState(
                        interfaceId: try nic.requireID(), portName: "vm-test-net0",
                        securityGroupIds: [try group.requireID()], status: .error,
                        lastError: "could not join pg_strato_drop",
                        failureClassification: .transient)
                ],
                manifestStatus: ObservedManifestStatus(
                    inventoryComplete: false, quarantinedEntries: 0,
                    reason: "fabric-only test report"))
            await app.agentService.applyObservedStateReport(
                envelope, fromAgentKey: agentKey("recon-agent"))

            let storedNetwork = try #require(
                try await LogicalNetwork.find(network.id, on: app.db))
            #expect(storedNetwork.conditions.degraded?.reason == "OVSDB unavailable")
            #expect(storedNetwork.conditions.degraded?.sinceGeneration == 2)
            #expect(storedNetwork.convergenceDeadline == nil)

            let storedGroup = try #require(try await SecurityGroup.find(group.id, on: app.db))
            #expect(storedGroup.conditions.degraded?.reason == "ACL match rejected")
            #expect(storedGroup.conditions.degraded?.sinceGeneration == 3)
            #expect(storedGroup.convergenceDeadline == nil)

            let storedNIC = try #require(try await VMNetworkInterface.find(nic.id, on: app.db))
            #expect(storedNIC.securityGroupStatus == ObservedNetworkFabricStatus.error.rawValue)
            #expect(storedNIC.securityGroupLastError == "could not join pg_strato_drop")
            #expect(storedNIC.securityGroupLastErrorAt != nil)

            let recovery = try self.report(
                agentId: agentId,
                vms: [],
                networks: [
                    ObservedNetworkState(
                        id: try network.requireID(), observedGeneration: 2, status: .active)
                ],
                securityGroups: [
                    ObservedSecurityGroupState(
                        id: try group.requireID(), observedGeneration: 3, status: .active)
                ],
                portMemberships: [
                    ObservedPortMembershipState(
                        interfaceId: try nic.requireID(), portName: "vm-test-net0",
                        securityGroupIds: [try group.requireID()], status: .active)
                ],
                manifestStatus: ObservedManifestStatus(
                    inventoryComplete: false, quarantinedEntries: 0,
                    reason: "same-generation fabric recovery"))
            await app.agentService.applyObservedStateReport(
                recovery, fromAgentKey: agentKey("recon-agent"))

            let recoveredNetwork = try #require(
                try await LogicalNetwork.find(network.id, on: app.db))
            #expect(recoveredNetwork.conditions.converged)
            #expect(recoveredNetwork.lastError == nil)
            let recoveredGroup = try #require(
                try await SecurityGroup.find(group.id, on: app.db))
            #expect(recoveredGroup.conditions.converged)
            #expect(recoveredGroup.lastError == nil)
            let recoveredNIC = try #require(
                try await VMNetworkInterface.find(nic.id, on: app.db))
            #expect(recoveredNIC.securityGroupStatus == ObservedNetworkFabricStatus.active.rawValue)
            #expect(recoveredNIC.securityGroupLastError == nil)
            #expect(recoveredNIC.securityGroupLastErrorAt == nil)
        }
    }

    @Test("Every relevant site must acknowledge a security-group generation")
    func securityGroupConvergenceAggregatesSites() async throws {
        try await withVMTestApp { app, _, vm, _ in
            let firstAgentID = try await self.registerAgent(
                app: app, vm: vm, named: "recon-site-a",
                protocolVersion: WireProtocol.currentVersion)
            let firstAgentUUID = try #require(UUID(uuidString: firstAgentID))
            let firstAgent = try #require(try await Agent.find(firstAgentUUID, on: app.db))

            let project = try #require(try await Project.find(vm.$project.id, on: app.db))
            let organizationID = try #require(project.$organization.id)
            let builder = TestDataBuilder(db: app.db)
            let secondSite = try await builder.createSite(
                name: "recon-site-b",
                organizationScope: .organization(organizationID))
            let secondAgentID = try await builder.registerAgent(
                on: app,
                named: "recon-site-b-agent",
                dependencyObservations: [Self.healthyOverlayObservation()],
                siteID: try secondSite.requireID())
            let secondAgentUUID = try #require(UUID(uuidString: secondAgentID))
            secondSite.$networkControllerAgent.id = secondAgentUUID
            try await secondSite.save(on: app.db)

            let group = SecurityGroup(projectID: vm.$project.id, name: "multi-site")
            group.convergenceDeadline = Date().addingTimeInterval(300)
            try await group.save(on: app.db)
            let groupID = try group.requireID()
            try await SecurityGroupSiteObservation(
                securityGroupID: groupID, siteID: firstAgent.$site.id
            ).save(on: app.db)
            try await SecurityGroupSiteObservation(
                securityGroupID: groupID, siteID: try secondSite.requireID()
            ).save(on: app.db)

            let firstReport = try self.report(
                agentId: firstAgentID,
                vms: [],
                securityGroups: [
                    ObservedSecurityGroupState(
                        id: groupID, observedGeneration: 1, status: .active)
                ])
            await app.agentService.applyObservedStateReport(
                firstReport, fromAgentKey: agentKey("recon-site-a"))

            let awaitingSecond = try #require(
                try await SecurityGroup.find(groupID, on: app.db))
            #expect(awaitingSecond.observedGeneration == 0)
            #expect(!awaitingSecond.conditions.converged)
            #expect(awaitingSecond.convergenceDeadline != nil)

            awaitingSecond.convergenceDeadline = Date().addingTimeInterval(-1)
            try await awaitingSecond.save(on: app.db)
            await app.agentMaintenance.sweepStuckConvergence()
            let timedOut = try #require(
                try await SecurityGroup.find(groupID, on: app.db))
            let timeoutReason = try #require(timedOut.lastError)
            let timeoutAt = try #require(timedOut.lastErrorAt)
            #expect(timedOut.conditions.degraded?.sinceGeneration == 1)

            // Site A's routine healthy report cannot erase site B's timeout.
            await app.agentService.applyObservedStateReport(
                firstReport, fromAgentKey: agentKey("recon-site-a"))
            let stillTimedOut = try #require(
                try await SecurityGroup.find(groupID, on: app.db))
            #expect(stillTimedOut.lastError == timeoutReason)
            #expect(stillTimedOut.lastErrorAt == timeoutAt)
            #expect(stillTimedOut.conditions.degraded?.sinceGeneration == 1)
            #expect(stillTimedOut.convergenceDeadline == nil)

            let secondReport = try self.report(
                agentId: secondAgentID,
                vms: [],
                securityGroups: [
                    ObservedSecurityGroupState(
                        id: groupID, observedGeneration: 1, status: .active)
                ])
            await app.agentService.applyObservedStateReport(
                secondReport, fromAgentKey: agentKey("recon-site-b-agent"))

            let converged = try #require(
                try await SecurityGroup.find(groupID, on: app.db))
            #expect(converged.observedGeneration == 1)
            #expect(converged.conditions.converged)
            #expect(converged.convergenceDeadline == nil)
        }
    }

    @Test("A superseded fabric failure preserves the current generation's deadline")
    func supersededFabricFailurePreservesDeadline() async throws {
        try await withVMTestApp { app, _, vm, _ in
            let agentId = try await self.registerAgent(
                app: app, vm: vm, protocolVersion: WireProtocol.currentVersion)
            let network = try await self.network(app: app, vm: vm, named: "superseded-fabric-failure")
            network.generation = 2
            network.observedGeneration = 1
            let deadline = Date().addingTimeInterval(300)
            network.convergenceDeadline = deadline
            try await network.save(on: app.db)

            let envelope = try self.report(
                agentId: agentId,
                vms: [],
                networks: [
                    ObservedNetworkState(
                        id: try network.requireID(), observedGeneration: 1, status: .error,
                        lastError: "generation 1 failed", failedGeneration: 1,
                        failureClassification: .transient)
                ],
                manifestStatus: ObservedManifestStatus(
                    inventoryComplete: false, quarantinedEntries: 0,
                    reason: "stale fabric failure"))
            await app.agentService.applyObservedStateReport(
                envelope, fromAgentKey: agentKey("recon-agent"))

            let stored = try #require(try await LogicalNetwork.find(network.id, on: app.db))
            #expect(stored.conditions.targetGeneration == 2)
            #expect(stored.conditions.degraded?.sinceGeneration == 1)
            #expect(abs(try #require(stored.convergenceDeadline).timeIntervalSince(deadline)) < 0.01)
        }
    }

    @Test("Only the site's topology authority can update network observations")
    func nonAuthorityNetworkObservationIsIgnored() async throws {
        try await withVMTestApp { app, _, vm, _ in
            _ = try await self.registerAgent(
                app: app, vm: vm, named: "recon-agent", protocolVersion: WireProtocol.currentVersion)
            let nonAuthority = try await self.registerAgent(
                app: app, vm: vm, named: "fabric-bystander",
                protocolVersion: WireProtocol.currentVersion, placeVM: false)
            let network = try await self.network(app: app, vm: vm, named: "authority-guard")
            network.generation = 1
            try await network.save(on: app.db)

            let envelope = try self.report(
                agentId: nonAuthority,
                vms: [],
                networks: [
                    ObservedNetworkState(
                        id: try network.requireID(), observedGeneration: 0, status: .error,
                        lastError: "must be ignored", failedGeneration: 1)
                ],
                manifestStatus: ObservedManifestStatus(
                    inventoryComplete: false, quarantinedEntries: 0,
                    reason: "fabric-only test report"))
            await app.agentService.applyObservedStateReport(
                envelope, fromAgentKey: agentKey("fabric-bystander"))

            let stored = try #require(try await LogicalNetwork.find(network.id, on: app.db))
            #expect(stored.lastError == nil)
            #expect(stored.observedGeneration == 0)
        }
    }

    @Test("A network timeout survives stale active reports until the current generation lands")
    func networkFabricDeadlineSweep() async throws {
        try await withVMTestApp { app, _, vm, _ in
            let agentID = try await self.registerAgent(
                app: app, vm: vm, protocolVersion: WireProtocol.currentVersion)
            let network = try await self.network(app: app, vm: vm, named: "fabric-timeout")
            network.generation = 4
            network.observedGeneration = 3
            network.convergenceDeadline = Date().addingTimeInterval(-1)
            try await network.save(on: app.db)

            await app.agentMaintenance.sweepStuckConvergence()

            let stored = try #require(try await LogicalNetwork.find(network.id, on: app.db))
            #expect(stored.conditions.converged == false)
            #expect(stored.conditions.degraded?.sinceGeneration == 4)
            #expect(stored.conditions.degraded?.reason.contains("did not report convergence") == true)
            #expect(stored.convergenceDeadline == nil)

            let timeoutReason = try #require(stored.lastError)
            let timeoutAt = try #require(stored.lastErrorAt)
            let stale = try self.report(
                agentId: agentID,
                vms: [],
                networks: [
                    ObservedNetworkState(
                        id: try network.requireID(), observedGeneration: 3, status: .active)
                ])
            await app.agentService.applyObservedStateReport(
                stale, fromAgentKey: agentKey("recon-agent"))

            let afterStale = try #require(
                try await LogicalNetwork.find(network.id, on: app.db))
            #expect(afterStale.lastError == timeoutReason)
            #expect(afterStale.lastErrorAt == timeoutAt)
            #expect(afterStale.conditions.degraded?.sinceGeneration == 4)

            let current = try self.report(
                agentId: agentID,
                vms: [],
                networks: [
                    ObservedNetworkState(
                        id: try network.requireID(), observedGeneration: 4, status: .active)
                ])
            await app.agentService.applyObservedStateReport(
                current, fromAgentKey: agentKey("recon-agent"))
            let converged = try #require(
                try await LogicalNetwork.find(network.id, on: app.db))
            #expect(converged.conditions.converged)
            #expect(converged.lastError == nil)
        }
    }

    @Test("The network fabric migration backfills only authority-addressable deadlines")
    func networkFabricMigrationBackfillsDeadlines() async throws {
        try await withVMTestApp { app, _, vm, _ in
            _ = try await self.registerAgent(
                app: app, vm: vm, protocolVersion: WireProtocol.currentVersion)
            let network = try await self.network(app: app, vm: vm, named: "fabric-upgrade")
            network.generation = 3
            network.observedGeneration = 0
            network.convergenceDeadline = nil
            try await network.save(on: app.db)

            let group = try await SecurityGroupService.ensureDefaultGroup(
                projectID: vm.$project.id, on: app.db)
            group.generation = 0
            group.observedGeneration = 0
            group.convergenceDeadline = nil
            try await group.save(on: app.db)
            let nic = VMNetworkInterface(
                vmID: try vm.requireID(), logicalNetworkID: try network.requireID(),
                macAddress: "52:54:00:29:40:02")
            try await nic.save(on: app.db)
            try await VMInterfaceSecurityGroup(
                interfaceID: try nic.requireID(), securityGroupID: try group.requireID()
            ).save(on: app.db)

            let unattachedGroup = SecurityGroup(
                projectID: vm.$project.id, name: "fabric-upgrade-unused")
            unattachedGroup.generation = 0
            try await unattachedGroup.save(on: app.db)

            try await AddNetworkFabricObservations().prepare(on: app.db)

            let upgradedNetwork = try #require(
                try await LogicalNetwork.find(network.id, on: app.db))
            #expect(upgradedNetwork.convergenceDeadline != nil)
            let upgradedGroup = try #require(
                try await SecurityGroup.find(group.id, on: app.db))
            #expect(upgradedGroup.generation == 1)
            #expect(upgradedGroup.observedGeneration == 0)
            #expect(upgradedGroup.convergenceDeadline != nil)
            #expect(
                try await SecurityGroupSiteObservation.query(on: app.db)
                    .filter(\.$securityGroup.$id == group.id!)
                    .count() == 1)
            let upgradedUnattachedGroup = try #require(
                try await SecurityGroup.find(unattachedGroup.id, on: app.db))
            #expect(upgradedUnattachedGroup.generation == 1)
            #expect(upgradedUnattachedGroup.convergenceDeadline == nil)
        }
    }

    @Test("A reported pending create releases its placement reservation")
    func reportReleasesCreateReservation() async throws {
        try await withVMTestApp { app, user, vm, _ in
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: WireProtocol.currentVersion)
            let reservation = ReservationAmounts(cpu: vm.cpu, memory: vm.memory, disk: vm.disk)
            let reserved = await app.coordination.reserveCapacity(
                agentId: agentId,
                vmId: vm.id!.uuidString,
                amounts: reservation,
                capacity: reservation
            )
            #expect(reserved)

            let envelope = try self.report(
                agentId: agentId,
                vms: [
                    ObservedVMState(
                        vmId: vm.id!,
                        status: .shutdown,
                        observedGeneration: vm.generation)
                ]
            )
            await app.agentService.applyObservedStateReport(
                envelope,
                fromAgentKey: agentKey("recon-agent")
            )

            #expect(await app.coordination.activeReservations(agentIds: [agentId])[agentId] == .zero)
        }
    }

    @Test("A convergence failure fails the pending operation with the agent's error")
    func reportFailsOperationWithError() async throws {
        try await withVMTestApp { app, user, vm, _ in
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: WireProtocol.currentVersion)

            vm.setFixtureDesiredStatus(.running)
            vm.extendConvergenceDeadline(by: 600)
            try await vm.save(on: app.db)
            _ = try await ResourceEvent.record(
                .boot, resourceKind: .virtualMachine, resourceID: vm.id!,
                actor: .user(user.id!), on: app.db)

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
            await app.agentService.applyObservedStateReport(envelope, fromAgentKey: agentKey("recon-agent"))

            let refreshed = try #require(await VM.find(vm.id, on: app.db))
            let degraded = try #require(refreshed.conditions.degraded)
            #expect(degraded.reason == "boot failed: no bootable device")
            #expect(degraded.sinceGeneration == 1)
            #expect(refreshed.convergenceDeadline == nil)

            // The unachieved intent must not linger: desired realigns with the
            // observed resting state (and bumps the generation).
            #expect(refreshed.desiredStatus == .shutdown)
            #expect(refreshed.generation == 2)
        }
    }

    @Test("A blocked capacity boot retains intent and converges at the same generation")
    func blockedCapacityBootRetainsIntent() async throws {
        try await withVMTestApp { app, _, vm, _ in
            let agentId = try await self.registerAgent(
                app: app, vm: vm, protocolVersion: WireProtocol.currentVersion)
            vm.setFixtureDesiredStatus(.running)
            vm.extendConvergenceDeadline(by: 600)
            try await vm.save(on: app.db)
            let originalDeadline = try #require(vm.convergenceDeadline)
            let reason = "agent `hv-03` has 12 GiB available; this operation requires 64 GiB additional memory"

            let envelope = try self.report(
                agentId: agentId,
                vms: [
                    ObservedVMState(
                        vmId: vm.id!, status: .shutdown, observedGeneration: 0,
                        lastError: reason, failedGeneration: 1,
                        failureClassification: .blocked)
                ])
            await app.agentService.applyObservedStateReport(
                envelope, fromAgentKey: agentKey("recon-agent"))

            let refreshed = try #require(await VM.find(vm.id, on: app.db))
            #expect(refreshed.conditions.degraded?.reason == reason)
            #expect(refreshed.conditions.degraded?.sinceGeneration == 1)
            #expect(refreshed.convergenceDeadline == originalDeadline)
            #expect(refreshed.desiredStatus == .running)
            #expect(refreshed.generation == 1)

            // Capacity becomes available and the agent's same-generation retry
            // succeeds. The original boot intent now settles normally.
            let recovered = try self.report(
                agentId: agentId,
                vms: [
                    ObservedVMState(
                        vmId: vm.id!, status: .running, observedGeneration: 1)
                ])
            await app.agentService.applyObservedStateReport(
                recovered, fromAgentKey: agentKey("recon-agent"))

            let converged = try #require(await VM.find(vm.id, on: app.db))
            #expect(converged.conditions.converged)
            #expect(converged.conditions.degraded == nil)
            #expect(converged.convergenceDeadline == nil)
            #expect(converged.desiredStatus == .running)
            #expect(converged.generation == 1)
        }
    }

    @Test("A stale error from a previous generation does not degrade the current one")
    func staleErrorFromPreviousGenerationIgnored() async throws {
        try await withVMTestApp { app, _, vm, _ in
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: WireProtocol.currentVersion)

            // Boot at generation 1 failed and capped out; the user retried,
            // minting generation 2.
            vm.setFixtureDesiredStatus(.running)  // gen 1
            vm.setFixtureDesiredStatus(.running)  // gen 2 (retry)
            try await vm.save(on: app.db)

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
            await app.agentService.applyObservedStateReport(envelope, fromAgentKey: agentKey("recon-agent"))

            // The error is recorded verbatim, but tagged with the generation
            // that produced it — so a client comparing `sinceGeneration`
            // against `targetGeneration` sees a superseded failure, not a
            // failure of the retry.
            let refreshed = try #require(await VM.find(vm.id, on: app.db))
            let conditions = refreshed.conditions
            #expect(conditions.targetGeneration == 2)
            #expect(conditions.degraded?.sinceGeneration == 1)
            #expect(conditions.converged == false)
        }
    }

    @Test("Progress-only entries neither settle status nor converge")
    func convergingEntriesAreProgressOnly() async throws {
        try await withVMTestApp { app, _, vm, _ in
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: WireProtocol.currentVersion)

            vm.setFixtureDesiredStatus(.running)
            try await vm.save(on: app.db)

            let envelope = try self.report(
                agentId: agentId,
                vms: [
                    ObservedVMState(
                        vmId: vm.id!, status: .unknown, observedGeneration: 0,
                        convergencePhase: "downloading image")
                ]
            )
            await app.agentService.applyObservedStateReport(envelope, fromAgentKey: agentKey("recon-agent"))

            let refreshed = try #require(await VM.find(vm.id, on: app.db))
            #expect(refreshed.status == .created)  // untouched

            let conditions = refreshed.conditions
            #expect(conditions.converged == false)
            #expect(conditions.degraded == nil)
            #expect(conditions.phase == "downloading image")
        }
    }

    @Test("Absence with desired absent confirms deletion: row removed, terminal event appended")
    func absenceConfirmsDeletion() async throws {
        try await withVMTestApp { app, user, vm, _ in
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: WireProtocol.currentVersion)

            try await ResourceFinalizerService.stampForDeletion(vm, on: app.db)
            vm.setFixtureDesiredStatus(.absent)
            try await vm.save(on: app.db)
            _ = try await ResourceEvent.record(
                .delete, resourceKind: .virtualMachine, resourceID: vm.id!,
                actor: .user(user.id!), on: app.db)

            // The creator binding VM creation writes, plus a checkpoint whose
            // row cascades away with the VM. Bindings have no FK to either, so
            // the confirmed deletion has to drop both (STR-112) — and the
            // checkpoint's only if the revoke reads it before the delete.
            try await RoleBindingService.grant(
                principalType: .user, principalID: user.id!, role: .admin,
                nodeType: .virtualMachine, nodeID: vm.id!, createdBy: user.id!, on: app.db)
            let snapshot = VMSnapshot(
                name: "checkpoint", vmID: vm.id!, projectID: vm.$project.id,
                environment: vm.environment, agentId: agentId, createdByID: user.id!)
            try await snapshot.save(on: app.db)
            let snapshotID = try snapshot.requireID()
            try await RoleBindingService.grant(
                principalType: .user, principalID: user.id!, role: .admin,
                nodeType: .vmSnapshot, nodeID: snapshotID, createdBy: user.id!, on: app.db)

            // Full-list semantics: the VM is missing from the agent's report.
            let envelope = try self.report(agentId: agentId, vms: [])
            await app.agentService.applyObservedStateReport(envelope, fromAgentKey: agentKey("recon-agent"))

            let gone = try await VM.find(vm.id, on: app.db)
            #expect(gone == nil)

            // The reap appended the terminal event a client polling the delete
            // reads as "done" (STR-147).
            let terminal = try await ResourceEvent.latest(
                .completed, resourceKind: .virtualMachine, resourceID: vm.id!, on: app.db)
            #expect(terminal?.mutation == .delete)

            let bindings = try await RoleBinding.query(on: app.db)
                .filter(\.$nodeType == IAMNodeType.virtualMachine.rawValue)
                .filter(\.$nodeID == vm.id!)
                .count()
            #expect(bindings == 0)
            let snapshotBindings = try await RoleBinding.query(on: app.db)
                .filter(\.$nodeType == IAMNodeType.vmSnapshot.rawValue)
                .filter(\.$nodeID == snapshotID)
                .count()
            #expect(snapshotBindings == 0)
        }
    }

    @Test("A timed-out delete keeps converging on absent instead of resurrecting the VM")
    func stuckDeleteKeepsConvergingOnAbsent() async throws {
        try await withVMTestApp { app, user, vm, _ in
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: WireProtocol.currentVersion)

            // A delete leaves `status` non-transitional: the user deleted a
            // running VM and the agent has not reported the absence yet.
            vm.setStatus(.running)
            vm.setFixtureDesiredStatus(.absent)
            // Already past its budget when the sweep runs.
            vm.convergenceDeadline = Date().addingTimeInterval(-100)
            try await vm.save(on: app.db)
            _ = try await ResourceEvent.record(
                .delete, resourceKind: .virtualMachine, resourceID: vm.id!,
                actor: .user(user.id!), on: app.db)

            await app.agentMaintenance.sweepStuckConvergence()

            // The delete is marked degraded, but the deletion intent survives
            // it (issue #734) — reverting desired to `.running` here would have
            // the agent recreate a fresh, blank VM under this id.
            let sweptVM = try #require(try await VM.find(vm.id, on: app.db))
            #expect(sweptVM.conditions.degraded?.sinceGeneration == vm.generation)
            #expect(sweptVM.desiredStatus == .absent)
            #expect(sweptVM.generation == vm.generation)

            // The agent comes back and reports the VM absent: the delete still
            // completes, row removed, rather than being re-materialized.
            let envelope = try self.report(agentId: agentId, vms: [])
            await app.agentService.applyObservedStateReport(envelope, fromAgentKey: agentKey("recon-agent"))

            let gone = try await VM.find(vm.id, on: app.db)
            #expect(gone == nil)
        }
    }

    @Test("Absence of an established VM that should exist marks it as error")
    func absenceOfEstablishedVMIsDrift() async throws {
        try await withVMTestApp { app, _, vm, _ in
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: WireProtocol.currentVersion)

            vm.setFixtureDesiredStatus(.running)
            vm.setStatus(.running)
            try await vm.save(on: app.db)

            let envelope = try self.report(agentId: agentId, vms: [])
            await app.agentService.applyObservedStateReport(envelope, fromAgentKey: agentKey("recon-agent"))

            let refreshed = try await VM.find(vm.id, on: app.db)
            #expect(refreshed?.status == .error)
        }
    }

    @Test("A never-established VM absent from the report is left alone")
    func absenceOfFreshVMIsIgnored() async throws {
        try await withVMTestApp { app, _, vm, _ in
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: WireProtocol.currentVersion)

            // `.created` may be mid-create on an agent that hasn't received
            // the sync yet — absence must not escalate it.
            vm.setFixtureDesiredStatus(.running)
            try await vm.save(on: app.db)

            let envelope = try self.report(agentId: agentId, vms: [])
            await app.agentService.applyObservedStateReport(envelope, fromAgentKey: agentKey("recon-agent"))

            let refreshed = try await VM.find(vm.id, on: app.db)
            #expect(refreshed?.status == .created)
        }
    }

    @Test("Out-of-band drift is applied and detected without a pending operation")
    func driftDetectedWithoutOperation() async throws {
        try await withVMTestApp { app, _, vm, _ in
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: WireProtocol.currentVersion)

            vm.setFixtureDesiredStatus(.running)
            vm.setStatus(.running)
            vm.observedGeneration = 1
            try await vm.save(on: app.db)

            // The guest paused itself out of band; no operation asked for it.
            let envelope = try self.report(
                agentId: agentId,
                vms: [ObservedVMState(vmId: vm.id!, status: .paused, observedGeneration: 1)]
            )
            await app.agentService.applyObservedStateReport(envelope, fromAgentKey: agentKey("recon-agent"))

            let refreshed = try await VM.find(vm.id, on: app.db)
            #expect(refreshed?.status == .paused)
        }
    }

    @Test("A report claiming another agent's identity is ignored")
    func reportOwnershipValidated() async throws {
        try await withVMTestApp { app, _, vm, _ in
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: WireProtocol.currentVersion)

            vm.setFixtureDesiredStatus(.running)
            try await vm.save(on: app.db)

            let envelope = try self.report(
                agentId: agentId,
                vms: [ObservedVMState(vmId: vm.id!, status: .running, observedGeneration: 1)]
            )
            // Delivered over a connection authenticated as a different agent.
            await app.agentService.applyObservedStateReport(envelope, fromAgentKey: agentKey("impostor"))

            let refreshed = try await VM.find(vm.id, on: app.db)
            #expect(refreshed?.status == .created)
            #expect(refreshed?.observedGeneration == 0)
        }
    }

    @Test("An identical report does not rewrite the agent row")
    func identicalReportSkipsAgentSave() async throws {
        try await withVMTestApp { app, _, vm, _ in
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: WireProtocol.currentVersion)
            vm.setFixtureDesiredStatus(.running)
            vm.setStatus(.running)
            vm.observedGeneration = vm.generation
            try await vm.save(on: app.db)

            let envelope = try self.report(
                agentId: agentId,
                vms: [
                    ObservedVMState(
                        vmId: vm.id!,
                        status: .running,
                        observedGeneration: vm.generation)
                ]
            )
            await app.agentService.applyObservedStateReport(
                envelope,
                fromAgentKey: agentKey("recon-agent")
            )
            let afterFirst = try #require(
                try await Agent.find(UUID(uuidString: agentId), on: app.db)
            )
            let firstUpdatedAt = afterFirst.updatedAt
            let firstHeartbeat = afterFirst.lastHeartbeat

            await app.agentService.applyObservedStateReport(
                envelope,
                fromAgentKey: agentKey("recon-agent")
            )
            let afterSecond = try #require(
                try await Agent.find(UUID(uuidString: agentId), on: app.db)
            )
            #expect(afterSecond.updatedAt == firstUpdatedAt)
            #expect(afterSecond.lastHeartbeat == firstHeartbeat)
        }
    }

    @Test("Heartbeat absence no longer duplicates observed-report reconciliation")
    func heartbeatDoesNotReconcileVMAbsence() async throws {
        try await withVMTestApp { app, _, vm, _ in
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: WireProtocol.currentVersion)
            vm.setFixtureDesiredStatus(.running)
            vm.setStatus(.running)
            try await vm.save(on: app.db)

            try await app.agentService.updateAgentHeartbeat(
                AgentHeartbeatMessage(
                    agentId: agentId,
                    resources: AgentResources(
                        totalCPU: 16, availableCPU: 12,
                        totalMemory: 1 << 34, availableMemory: 1 << 33,
                        totalDisk: 1 << 40, availableDisk: 1 << 39
                    )
                ),
                fromAgentKey: agentKey("recon-agent")
            )

            let refreshed = try #require(try await VM.find(vm.id, on: app.db))
            #expect(refreshed.status == .running)
        }
    }

    // MARK: - Guest agent (qga) observed info (issue #563)

    @Test("A report's guestInfo persists hostname, availability, and per-MAC observed addresses")
    func guestInfoPersisted() async throws {
        try await withVMTestApp { app, _, vm, _ in
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: WireProtocol.currentVersion)

            // A NIC to attribute the guest's addresses to, by MAC.
            let nic = VMNetworkInterface(
                vmID: vm.id!, logicalNetworkID: try await self.network(app: app, vm: vm).requireID(),
                macAddress: "52:54:00:ab:cd:ef", deviceName: "net0")
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
            await app.agentService.applyObservedStateReport(envelope, fromAgentKey: agentKey("recon-agent"))

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
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: WireProtocol.currentVersion)
            let nic = VMNetworkInterface(
                vmID: vm.id!, logicalNetworkID: try await self.network(app: app, vm: vm).requireID(),
                macAddress: "52:54:00:ab:cd:ef", deviceName: "net0")
            try await nic.save(on: app.db)

            func send(_ guestInfo: GuestInfo?) async throws {
                let envelope = try self.report(
                    agentId: agentId,
                    vms: [ObservedVMState(vmId: vm.id!, status: .running, observedGeneration: 1, guestInfo: guestInfo)]
                )
                await app.agentService.applyObservedStateReport(envelope, fromAgentKey: agentKey("recon-agent"))
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
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: WireProtocol.currentVersion)
            let nic = VMNetworkInterface(
                vmID: vm.id!, logicalNetworkID: try await self.network(app: app, vm: vm).requireID(),
                macAddress: "52:54:00:ab:cd:ef", deviceName: "net0")
            try await nic.save(on: app.db)

            func send(status: VMStatus, guestInfo: GuestInfo?) async throws {
                let envelope = try self.report(
                    agentId: agentId,
                    vms: [ObservedVMState(vmId: vm.id!, status: status, observedGeneration: 1, guestInfo: guestInfo)]
                )
                await app.agentService.applyObservedStateReport(envelope, fromAgentKey: agentKey("recon-agent"))
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

    // MARK: - Balloon memory stats (issue #567)

    @Test("A report's memoryStats persist and stamp their report time")
    func memoryStatsPersisted() async throws {
        try await withVMTestApp { app, _, vm, _ in
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: WireProtocol.currentVersion)

            let envelope = try self.report(
                agentId: agentId,
                vms: [
                    ObservedVMState(
                        vmId: vm.id!, status: .running, observedGeneration: 1,
                        memoryStats: VMMemoryStats(
                            totalBytes: 8_254_390_272, availableBytes: 6_442_450_944,
                            balloonActualBytes: 8_589_934_592))
                ]
            )
            await app.agentService.applyObservedStateReport(envelope, fromAgentKey: agentKey("recon-agent"))

            let refreshed = try #require(try await VM.find(vm.id, on: app.db))
            #expect(refreshed.guestMemoryTotalBytes == 8_254_390_272)
            #expect(refreshed.guestMemoryAvailableBytes == 6_442_450_944)
            #expect(refreshed.guestMemoryBalloonActualBytes == 8_589_934_592)
            #expect(refreshed.guestMemoryStatsAt != nil)
        }
    }

    @Test("A nil memoryStats preserves the last-known values while running, and clears them once stopped")
    func memoryStatsPreservedOnNilAndClearedWhenNotRunning() async throws {
        try await withVMTestApp { app, _, vm, _ in
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: WireProtocol.currentVersion)

            func send(status: VMStatus, memoryStats: VMMemoryStats?) async throws {
                let envelope = try self.report(
                    agentId: agentId,
                    vms: [
                        ObservedVMState(
                            vmId: vm.id!, status: status, observedGeneration: 1,
                            memoryStats: memoryStats)
                    ]
                )
                await app.agentService.applyObservedStateReport(envelope, fromAgentKey: agentKey("recon-agent"))
            }

            try await send(
                status: .running,
                memoryStats: VMMemoryStats(totalBytes: 4_000_000_000, availableBytes: 3_000_000_000))

            // A transient probe miss (nil stats on a running VM) must NOT wipe
            // the last-known usage.
            try await send(status: .running, memoryStats: nil)
            var refreshed = try #require(try await VM.find(vm.id, on: app.db))
            #expect(refreshed.guestMemoryTotalBytes == 4_000_000_000)
            #expect(refreshed.guestMemoryAvailableBytes == 3_000_000_000)

            // Observed shut down: a stopped guest's last-known usage is stale.
            try await send(status: .shutdown, memoryStats: nil)
            refreshed = try #require(try await VM.find(vm.id, on: app.db))
            #expect(refreshed.guestMemoryTotalBytes == nil)
            #expect(refreshed.guestMemoryAvailableBytes == nil)
            #expect(refreshed.guestMemoryBalloonActualBytes == nil)
            #expect(refreshed.guestMemoryStatsAt == nil)
        }
    }
}
