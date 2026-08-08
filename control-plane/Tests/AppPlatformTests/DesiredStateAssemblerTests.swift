import Fluent
import StratoShared
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

/// Tests for the instance metadata the desired-state sync carries (STR-51):
/// `DesiredVMState.metadata`, assembled from the VM row, its NICs with their
/// resolved addressing, the project/environment, and the placing agent.
///
/// Two properties are under test. *Content* — the guest is told exactly what
/// the control plane knows, in the same NIC order the spec uses, with no field
/// invented for a VM that has no hostname and no NICs. And *shape* — assembly
/// is a per-sync, per-agent, fleet-wide loop, so metadata must cost zero
/// additional queries; `metadataAddsNoQueriesAsTheFleetGrows` holds that as an
/// equality across sizes rather than a budget.
@Suite("Desired State Assembler Tests", .serialized)
final class DesiredStateAssemblerTests {

    private func withAssemblerApp(
        _ test: (Application, Organization, Project) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "Metadata Org")
            let project = try await builder.createProject(
                name: "Metadata Project", description: "Project for metadata assembly tests",
                organization: org)

            try await test(app, org, project)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    /// Registers an in-memory agent, optionally into a site. Returns the
    /// agent's UUID string, which is also the `hypervisorId` VMs are placed on.
    private func registerAgent(
        app: Application,
        named name: String,
        siteID: UUID? = nil,
        protocolVersion: Int = WireProtocol.currentVersion
    ) async throws -> String {
        let message = AgentRegisterMessage(
            agentId: name,
            hostname: "host-\(name)",
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
        let uuid = try await app.agentService.registerAgent(
            message, agentName: name, siteID: siteID,
            organizationScope: orgID.map { .organization($0) })
        return uuid.uuidString
    }

    private func placeVM(
        app: Application, project: Project, named name: String, onAgent agentId: String,
        environment: String = "development"
    ) async throws -> VM {
        let vm = try await TestDataBuilder(db: app.db).createVM(
            name: name, project: project, environment: environment)
        vm.hypervisorId = agentId
        try await vm.save(on: app.db)
        return vm
    }

    private func attachNIC(
        app: Application,
        vm: VM,
        network: LogicalNetwork,
        deviceName: String,
        orderIndex: Int,
        mac: String,
        mtu: Int? = nil,
        ipv4: (address: String, prefix: Int, gateway: String?)? = nil,
        ipv6: (address: String, prefix: Int, gateway: String?)? = nil
    ) async throws {
        let nic = VMNetworkInterface(
            vmID: try vm.requireID(), logicalNetworkID: try network.requireID(),
            macAddress: mac, mtu: mtu, deviceName: deviceName, orderIndex: orderIndex)
        try await nic.save(on: app.db)
        if let ipv4 {
            try await VMInterfaceAddress(
                interfaceID: try nic.requireID(), logicalNetworkID: try network.requireID(),
                family: .ipv4, address: ipv4.address, prefixLength: ipv4.prefix,
                gateway: ipv4.gateway
            ).save(on: app.db)
        }
        if let ipv6 {
            try await VMInterfaceAddress(
                interfaceID: try nic.requireID(), logicalNetworkID: try network.requireID(),
                family: .ipv6, address: ipv6.address, prefixLength: ipv6.prefix,
                gateway: ipv6.gateway
            ).save(on: app.db)
        }
    }

    // MARK: - Content

    @Test("Instance metadata mirrors the VM row, its NICs, and its placement")
    func metadataMirrorsTheVMAndItsNICs() async throws {
        try await withAssemblerApp { app, org, project in
            let site = Site(name: "dc-meta", organizationScope: .organization(try org.requireID()))
            try await site.save(on: app.db)
            let agentId = try await self.registerAgent(
                app: app, named: "meta-agent", siteID: try site.requireID())

            let vm = try await self.placeVM(
                app: app, project: project, named: "meta-vm", onAgent: agentId,
                environment: "production")
            vm.hostname = "web-01"
            vm.sshPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5 operator@example"
            vm.userData = "#cloud-config\nruncmd: [echo hi]\n"
            try await vm.save(on: app.db)

            // The VM's instance identity (STR-55). Registered explicitly
            // because `placeVM` builds the row directly rather than going
            // through the create endpoint that would register it.
            let identity = try await GuestIdentity.register(
                vmID: try vm.requireID(), organizationID: nil, createdBy: nil, on: app.db)

            // Two networks with different DHCP/DNS config, so a per-NIC field
            // taken from the wrong network row would show up.
            let front = LogicalNetwork(
                name: "front", subnet: "10.40.0.0/24", gateway: "10.40.0.1",
                subnet6: "fd40::/64", gateway6: "fd40::1", projectID: try project.requireID(),
                dnsServers: ["10.40.0.53", "fd40::53"], domainName: "front.example")
            try await front.save(on: app.db)
            let back = LogicalNetwork(
                name: "back", subnet: "10.41.0.0/24", gateway: "10.41.0.1",
                projectID: try project.requireID(), dnsServers: ["10.41.0.53"])
            try await back.save(on: app.db)

            // Attached out of order, so ordering can only come from
            // `orderIndex` — the order the spec's NICs are sent in.
            try await self.attachNIC(
                app: app, vm: vm, network: back, deviceName: "net1", orderIndex: 1,
                mac: "00:0c:29:00:00:02",
                ipv4: ("10.41.0.9", 24, "10.41.0.1"))
            try await self.attachNIC(
                app: app, vm: vm, network: front, deviceName: "net0", orderIndex: 0,
                mac: "00:0c:29:00:00:01", mtu: 9000,
                ipv4: ("10.40.0.5", 24, "10.40.0.1"),
                ipv6: ("fd40::5", 64, "fd40::1"))

            let sync = try await app.desiredStateAssembler.assemble(agentId: agentId)
            let entry = try #require(sync.vms.first { $0.vmId == vm.id })
            let metadata = try #require(entry.metadata)

            #expect(metadata.instanceId == vm.id)
            #expect(metadata.hostname == "web-01")
            #expect(metadata.projectId == project.id)
            #expect(metadata.environment == "production")
            // Placement: the site names the coarse half, the placing agent the
            // fine one.
            #expect(metadata.region == "dc-meta")
            #expect(metadata.availabilityZone == "meta-agent")
            #expect(metadata.sshAuthorizedKeys == [vm.sshPublicKey!])
            #expect(metadata.userData == vm.userData)
            #expect(metadata.vendorData == nil)
            #expect(metadata.tags.isEmpty)
            // The VM's own SPIFFE ID (STR-55): a name, published to the guest
            // because it is not a credential. `audiences` and `ttlSeconds` stay
            // empty — nothing mints tokens for a guest yet (STR-57), and an
            // audience list published before an issuer exists promises what
            // nothing keeps.
            #expect(metadata.identity?.spiffeId == identity.spiffeID)
            #expect(metadata.identity?.audiences == [])
            #expect(metadata.identity?.ttlSeconds == nil)

            #expect(metadata.nics.map(\.deviceName) == ["net0", "net1"])
            let net0 = metadata.nics[0]
            #expect(net0.macAddress == "00:0c:29:00:00:01")
            #expect(net0.networkId == front.id)
            #expect(net0.networkName == "front")
            #expect(net0.ipAddress == "10.40.0.5")
            #expect(net0.prefixLength == 24)
            #expect(net0.gateway == "10.40.0.1")
            #expect(net0.ipv4CIDR == "10.40.0.5/24")
            #expect(net0.ipv6Address == "fd40::5")
            #expect(net0.ipv6PrefixLength == 64)
            #expect(net0.gateway6 == "fd40::1")
            #expect(net0.ipv6CIDR == "fd40::5/64")
            #expect(net0.mtu == 9000)
            #expect(net0.dnsServers == ["10.40.0.53", "fd40::53"])
            #expect(net0.domainName == "front.example")

            let net1 = metadata.nics[1]
            #expect(net1.networkName == "back")
            #expect(net1.ipAddress == "10.41.0.9")
            // Single-stack NIC: no v6 half invented from the network's config.
            #expect(net1.ipv6Address == nil)
            #expect(net1.ipv6CIDR == nil)
            #expect(net1.mtu == nil)
            #expect(net1.dnsServers == ["10.41.0.53"])
            #expect(net1.domainName == nil)

            // The metadata NIC order is the spec's NIC order — a guest matches
            // by MAC, but an operator reading both sees one list.
            #expect(entry.spec.networks.map(\.macAddress) == metadata.nics.map(\.macAddress))
        }
    }

    @Test("A VM whose registration was revoked is vended no identity")
    func revokedIdentityIsNotVended() async throws {
        try await withAssemblerApp { app, _, project in
            let agentId = try await self.registerAgent(app: app, named: "revoked-agent")
            let vm = try await self.placeVM(
                app: app, project: project, named: "revoked-identity-vm", onAgent: agentId)

            // No registration row — the shape an administrator's revocation
            // leaves behind. Nil is the whole answer: the guest is told nothing
            // rather than told an identity nothing will honour.
            let sync = try await app.desiredStateAssembler.assemble(agentId: agentId)
            let metadata = try #require(sync.vms.first { $0.vmId == vm.id }?.metadata)
            #expect(metadata.identity == nil)
        }
    }

    @Test("A VM with no NICs and no hostname still gets metadata")
    func metadataForAVMWithoutNICs() async throws {
        try await withAssemblerApp { app, _, project in
            let agentId = try await self.registerAgent(app: app, named: "bare-agent")
            let vm = try await self.placeVM(
                app: app, project: project, named: "bare-vm", onAgent: agentId)

            let sync = try await app.desiredStateAssembler.assemble(agentId: agentId)
            let metadata = try #require(sync.vms.first { $0.vmId == vm.id }?.metadata)

            #expect(metadata.nics.isEmpty)
            // Nil, not a slug of `name`: the derivation the stored column
            // exists to avoid, and it would disagree with the VM's DNS zone.
            #expect(metadata.hostname == nil)
            #expect(metadata.instanceId == vm.id)
            #expect(metadata.projectId == project.id)
            #expect(metadata.sshAuthorizedKeys.isEmpty)
            #expect(metadata.userData == nil)
            // Site-less agent (the legacy single-node model): no region to
            // report, but the host is still named.
            #expect(metadata.region == nil)
            #expect(metadata.availabilityZone == "bare-agent")
        }
    }

    @Test("An empty environment column publishes as unset, not as an environment named \"\"")
    func metadataEmptyEnvironmentIsUnset() async throws {
        try await withAssemblerApp { app, _, project in
            // `VM.environment` is a non-optional column, so "unset" can only
            // arrive as an empty string. The renderer decides what an unset
            // environment looks like, and it cannot if it is handed one.
            let agentId = try await self.registerAgent(app: app, named: "env-agent")
            let vm = try await self.placeVM(
                app: app, project: project, named: "env-vm", onAgent: agentId, environment: "")

            let sync = try await app.desiredStateAssembler.assemble(agentId: agentId)
            let metadata = try #require(sync.vms.first { $0.vmId == vm.id }?.metadata)
            #expect(metadata.environment == nil)
        }
    }

    @Test("The per-instance kill switch rides the document it governs")
    func metadataCarriesTheKillSwitch() async throws {
        try await withAssemblerApp { app, _, project in
            let agentId = try await self.registerAgent(app: app, named: "switch-agent")

            let served = try await self.placeVM(
                app: app, project: project, named: "served-vm", onAgent: agentId)
            let hardened = try await self.placeVM(
                app: app, project: project, named: "hardened-vm", onAgent: agentId)
            hardened.metadataEnabled = false
            try await hardened.save(on: app.db)

            let sync = try await app.desiredStateAssembler.assemble(agentId: agentId)

            // Sent as the column's literal value both ways rather than omitted
            // when on, so the agent never has to distinguish "left on" from
            // "this control plane has no opinion" for a VM it is being told
            // about right now.
            let servedMetadata = try #require(sync.vms.first { $0.vmId == served.id }?.metadata)
            #expect(servedMetadata.serviceEnabled == true)
            #expect(servedMetadata.isServiceEnabled)

            let hardenedMetadata = try #require(sync.vms.first { $0.vmId == hardened.id }?.metadata)
            #expect(hardenedMetadata.serviceEnabled == false)
            #expect(!hardenedMetadata.isServiceEnabled)
            // The rest of the document still travels: the switch is enforced by
            // the listener refusing the caller, not by withholding the payload,
            // because withholding it would take the VM's addresses out of the
            // listener's caller index — see `MetadataCallerIndex`.
            #expect(hardenedMetadata.instanceId == hardened.id)
            #expect(hardenedMetadata.projectId == project.id)
        }
    }

    @Test("Metadata is omitted entirely for pre-v26 agents")
    func metadataOmittedForOldAgents() async throws {
        try await withAssemblerApp { app, _, project in
            // An agent from before the instance-metadata protocol: it decodes
            // and discards the field, so sending it would only misstate what
            // the sync achieved. It still boots its guests from the seed ISO —
            // the gate costs mutable metadata, not placement.
            let agentId = try await self.registerAgent(
                app: app, named: "old-agent", protocolVersion: 25)
            let vm = try await self.placeVM(
                app: app, project: project, named: "old-vm", onAgent: agentId)

            let sync = try await app.desiredStateAssembler.assemble(agentId: agentId)
            let entry = try #require(sync.vms.first { $0.vmId == vm.id })
            #expect(entry.metadata == nil)
            // The VM itself still syncs — only the metadata is withheld.
            #expect(entry.spec.cpus == vm.cpu)
        }
    }

    // MARK: - Edge nonces (ADR 0001 stage 9, STR-151)

    @Test("Edge nonces reach the sync only once they have been asked for")
    func edgeNoncesRideTheSync() async throws {
        try await withAssemblerApp { app, _, project in
            let agentId = try await self.registerAgent(app: app, named: "nonce-agent")
            let vm = try await self.placeVM(
                app: app, project: project, named: "nonce-vm", onAgent: agentId)

            // A VM nobody has restarted or restored puts nothing on the wire:
            // sending a zero would be a subtly different claim from sending
            // nothing, and it would put both keys in every sync's digest.
            var sync = try await app.desiredStateAssembler.assemble(agentId: agentId)
            var entry = try #require(sync.vms.first { $0.vmId == vm.id })
            #expect(entry.rebootGeneration == nil)
            #expect(entry.restore == nil)

            let snapshotID = UUID()
            vm.requestReboot()
            vm.requestRestore(snapshotID: snapshotID)
            try await vm.save(on: app.db)

            sync = try await app.desiredStateAssembler.assemble(agentId: agentId)
            entry = try #require(sync.vms.first { $0.vmId == vm.id })
            #expect(entry.rebootGeneration == 1)
            #expect(entry.restore?.generation == 1)
            #expect(entry.restore?.snapshotId == snapshotID)
            // A VM checkpoint lives inside the VM's own disks, so it never moves
            // between hosts and there is nothing to stage.
            #expect(entry.restore?.artifacts == nil)
        }
    }

    @Test("Edge nonces are omitted entirely for pre-v34 agents")
    func edgeNoncesOmittedForOldAgents() async throws {
        try await withAssemblerApp { app, _, project in
            // Such an agent decodes and discards them, so sending them would
            // only misstate what the sync achieved — the same posture as the
            // v26 metadata gate. The admission gate has already refused the
            // mutation that could set one, so this is belt to those braces.
            let agentId = try await self.registerAgent(
                app: app, named: "pre-v34-agent",
                protocolVersion: WireProtocol.edgeNonceMinimumVersion - 1)
            let vm = try await self.placeVM(
                app: app, project: project, named: "pre-v34-vm", onAgent: agentId)
            vm.requestReboot()
            try await vm.save(on: app.db)

            let sync = try await app.desiredStateAssembler.assemble(agentId: agentId)
            let entry = try #require(sync.vms.first { $0.vmId == vm.id })
            #expect(entry.rebootGeneration == nil)
            // The VM itself still syncs — only the nonce is withheld.
            #expect(entry.spec.cpus == vm.cpu)
        }
    }

    // MARK: - The shared NIC resolution

    /// The spec's NIC list and the metadata's come from one
    /// `VMSpecBuilder.resolvedInterfaces`, which is what makes them agree — a
    /// guest whose metadata lists a NIC its spec doesn't has no way to tell
    /// which is right. The under-fetch path is where they could once have
    /// diverged, and it is unreachable through `assemble` (the FK guarantees
    /// the network row and the assembly always fetches it), so it is exercised
    /// directly with a deliberately short `networks` map.
    @Test("A NIC whose network wasn't loaded drops out of the spec and the metadata alike")
    func unloadedNetworkDropsFromBothLists() throws {
        let vm = VM(
            name: "drop-vm", description: "d", image: "img", projectID: UUID(),
            environment: "production", cpu: 2, memory: 1 << 31, disk: 1 << 34)
        vm.id = UUID()

        let loadedNetwork = LogicalNetwork(
            id: UUID(), name: "loaded", subnet: "10.60.0.0/24", gateway: "10.60.0.1",
            projectID: vm.$project.id)
        let missingNetworkID = UUID()

        func nic(_ device: String, order: Int, network: UUID, mac: String) -> VMNetworkInterface {
            let interface = VMNetworkInterface(
                id: UUID(), vmID: vm.id!, logicalNetworkID: network, macAddress: mac,
                deviceName: device, orderIndex: order)
            interface.$addresses.value = []
            return interface
        }
        // The middle NIC is the one whose row wasn't loaded, so a drop that
        // shifted the survivors would be visible in the order below.
        let interfaces = [
            nic("net0", order: 0, network: loadedNetwork.id!, mac: "00:0c:29:00:01:00"),
            nic("net1", order: 1, network: missingNetworkID, mac: "00:0c:29:00:01:01"),
            nic("net2", order: 2, network: loadedNetwork.id!, mac: "00:0c:29:00:01:02"),
        ]

        let resolved = VMSpecBuilder.resolvedInterfaces(
            from: interfaces, networks: [loadedNetwork.id!: loadedNetwork])
        #expect(resolved.map(\.interface.deviceName) == ["net0", "net2"])

        let spec = VMSpecBuilder.buildVMSpecWithVolumes(
            from: vm, image: nil, volumes: [], resolvedInterfaces: resolved)
        let metadata = InstanceMetadata.build(
            vm: vm, vmId: vm.id!, resolvedInterfaces: resolved,
            region: "dc-drop", availabilityZone: "drop-agent", instanceSPIFFEID: nil)

        #expect(metadata.nics.map(\.deviceName) == ["net0", "net2"])
        #expect(spec.networks.map(\.macAddress) == metadata.nics.map(\.macAddress))
        #expect(!metadata.nics.contains { $0.networkId == missingNetworkID })
    }

    // MARK: - Shape

    /// The assembler runs for every agent on every sync, so a per-VM query
    /// added here multiplies across the fleet. This varies distinct *projects
    /// and networks* alongside VM rows — the dimension a row-count-only test
    /// misses, since a per-project or per-network read stays invisible when
    /// every row shares one of each.
    @Test("Assembling metadata adds no queries as the fleet grows")
    func metadataAddsNoQueriesAsTheFleetGrows() async throws {
        try await withAssemblerApp { app, org, _ in
            let agentId = try await self.registerAgent(app: app, named: "scale-agent")
            let builder = TestDataBuilder(db: app.db)

            /// Places `count` VMs, each in its own project on its own network
            /// with two addressed NICs.
            func grow(from start: Int, to end: Int) async throws {
                for index in start..<end {
                    let project = try await builder.createProject(
                        name: "scale-project-\(index)", description: "d", organization: org)
                    let network = LogicalNetwork(
                        name: "scale-net-\(index)", subnet: "10.50.\(index % 250).0/24",
                        gateway: "10.50.\(index % 250).1", projectID: try project.requireID(),
                        dnsServers: ["10.50.\(index % 250).53"], domainName: "s\(index).example")
                    try await network.save(on: app.db)
                    let vm = try await self.placeVM(
                        app: app, project: project, named: "scale-vm-\(index)", onAgent: agentId)
                    vm.hostname = "scale-\(index)"
                    try await vm.save(on: app.db)
                    // Registered so the identity lookup measures the loaded
                    // path: a per-VM query hidden behind an always-empty table
                    // would never show up in the counts below.
                    try await GuestIdentity.register(
                        vmID: try vm.requireID(), organizationID: try org.requireID(),
                        createdBy: nil, on: app.db)
                    for nic in 0..<2 {
                        try await self.attachNIC(
                            app: app, vm: vm, network: network, deviceName: "net\(nic)",
                            orderIndex: nic,
                            mac: VMNetworkInterface.generateMACAddress(),
                            ipv4: ("10.50.\(index % 250).\(10 + nic)", 24, "10.50.\(index % 250).1"))
                    }
                }
            }

            func queriesToAssemble(expecting expected: Int) async throws -> Int {
                app.fluent.history.start()
                defer { app.fluent.history.stop() }
                let sync = try await app.desiredStateAssembler.assemble(agentId: agentId)
                #expect(sync.vms.count == expected)
                // Every VM carries metadata for both its NICs and its own
                // identity; a scaling test that measured an empty assembly
                // would prove nothing.
                #expect(sync.vms.allSatisfy { ($0.metadata?.nics.count ?? 0) == 2 })
                #expect(sync.vms.allSatisfy { $0.metadata?.identity != nil })
                return app.fluent.history.queries.count
            }

            try await grow(from: 0, to: 3)
            let three = try await queriesToAssemble(expecting: 3)

            try await grow(from: 3, to: 30)
            let thirty = try await queriesToAssemble(expecting: 30)

            // The equality below is only meaningful if the history recorded
            // the assembly at all: two zeroes would compare equal forever.
            #expect(three > 5, "the query history recorded only \(three) queries for a full assembly")

            // Equal, not merely sub-linear: every read in the assembly is
            // set-based, so fleet size changes the size of the `IN` clauses and
            // nothing else. A per-VM metadata lookup — the project row, the
            // network row, the placing agent — would show up here as a
            // difference of 27 or more.
            #expect(
                thirty == three,
                "assembling 30 VMs issued \(thirty) queries but 3 issued \(three); sync assembly is scaling with fleet size"
            )
        }
    }
}
