import Fluent
import StratoShared
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

/// The DNS zones the desired-state sync carries (STR-39).
///
/// The property under test throughout is the one that makes this phase
/// different from every other list in the sync: a zone's records are assembled
/// **fleet-wide**, while the decision to send the zone at all is scoped to the
/// receiving agent's topology authority. A test that placed every VM on the
/// receiving agent would pass against an implementation that only ever looked
/// at that agent's own workloads, so the multi-agent fixture below is the point
/// rather than extra coverage.
@Suite("Desired State DNS Zone Tests", .serialized)
final class DesiredStateDNSZoneTests {

    private func withDNSSyncApp(
        _ test: (Application, Organization, Project) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "DNS Sync Org")
            let project = try await builder.createProject(
                name: "DNS Sync Project", description: "Zone realization assembly", organization: org)

            try await test(app, org, project)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    private func registerAgent(
        app: Application,
        named name: String,
        siteID: UUID? = nil,
        protocolVersion: Int = WireProtocol.currentVersion,
        resolverCapable: Bool = false
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
            protocolVersion: protocolVersion,
            resolverCapable: resolverCapable
        )
        let orgID = try await Organization.query(on: app.db).sort(\.$createdAt).first()?.id
        let uuid = try await app.agentService.registerAgent(
            message, agentName: name, siteID: siteID,
            organizationScope: orgID.map { .organization($0) })
        return uuid.uuidString
    }

    /// A VM with a hostname and one addressed NIC on `network`, placed on
    /// `agentId`.
    @discardableResult
    private func placeVM(
        app: Application,
        project: Project,
        named name: String,
        hostname: String,
        onAgent agentId: String,
        network: LogicalNetwork,
        ipv4: String,
        ipv6: String? = nil
    ) async throws -> VM {
        let vm = try await TestDataBuilder(db: app.db).createVM(name: name, project: project)
        vm.hypervisorId = agentId
        vm.hostname = hostname
        try await vm.save(on: app.db)

        let nic = VMNetworkInterface(
            vmID: try vm.requireID(), logicalNetworkID: try network.requireID(),
            macAddress: "00:0c:29:00:00:01", deviceName: "net0", orderIndex: 0)
        try await nic.save(on: app.db)
        try await VMInterfaceAddress(
            interfaceID: try nic.requireID(), logicalNetworkID: try network.requireID(),
            family: .ipv4, address: ipv4, prefixLength: 24, gateway: network.gateway
        ).save(on: app.db)
        if let ipv6 {
            try await VMInterfaceAddress(
                interfaceID: try nic.requireID(), logicalNetworkID: try network.requireID(),
                family: .ipv6, address: ipv6, prefixLength: 64, gateway: network.gateway6
            ).save(on: app.db)
        }
        return vm
    }

    private func attachZone(
        app: Application, zone: DNSZone, to network: LogicalNetwork, primary: Bool
    ) async throws {
        try await DNSZoneNetwork(
            zoneID: try zone.requireID(), logicalNetworkID: try network.requireID()
        ).save(on: app.db)
        if primary {
            network.$primaryDNSZone.id = try zone.requireID()
            try await network.save(on: app.db)
        }
    }

    // MARK: - Scope

    @Test("The site's controller receives records for VMs it does not host")
    func authorityCarriesOtherAgentsRecords() async throws {
        try await withDNSSyncApp { app, org, project in
            let site = Site(name: "dc-dns", organizationScope: .organization(try org.requireID()))
            try await site.save(on: app.db)
            let siteID = try site.requireID()

            let controller = try await self.registerAgent(app: app, named: "controller", siteID: siteID)
            let peer = try await self.registerAgent(app: app, named: "peer", siteID: siteID)
            site.$networkControllerAgent.id = UUID(uuidString: controller)
            try await site.save(on: app.db)

            let network = try await TestDataBuilder(db: app.db).createNetwork(
                name: "dns-net", project: project, subnet: "10.60.0.0/24", gateway: "10.60.0.1",
                site: site)
            let zone = DNSZone(name: "acme.internal", projectID: try project.requireID())
            try await zone.save(on: app.db)
            try await self.attachZone(app: app, zone: zone, to: network, primary: true)

            // One VM on each host. The controller hosts neither of the other's
            // NICs, so a scope that only read its own workloads would lose half
            // the zone.
            try await self.placeVM(
                app: app, project: project, named: "vm-here", hostname: "here",
                onAgent: controller, network: network, ipv4: "10.60.0.5")
            try await self.placeVM(
                app: app, project: project, named: "vm-there", hostname: "there",
                onAgent: peer, network: network, ipv4: "10.60.0.6")

            let sync = try await app.desiredStateAssembler.assemble(agentId: controller)
            let zones = try #require(sync.dnsZones)
            #expect(zones.count == 1)
            let assembled = zones[0]
            #expect(assembled.zoneId == zone.id)
            #expect(assembled.zoneName == "acme.internal")
            #expect(assembled.networkIds == [try network.requireID()])

            let forward = assembled.records.filter { $0.type == "A" }
            #expect(
                forward.map(\.name).sorted() == ["here.acme.internal", "there.acme.internal"])
            #expect(forward.first { $0.name == "there.acme.internal" }?.values == ["10.60.0.6"])

            // Both directions, so a reverse lookup from either VM resolves.
            let reverse = assembled.records.filter { $0.type == "PTR" }
            #expect(reverse.map(\.name).sorted() == ["5.0.60.10.in-addr.arpa", "6.0.60.10.in-addr.arpa"])
            #expect(
                reverse.first { $0.name == "6.0.60.10.in-addr.arpa" }?.values == ["there.acme.internal"])
        }
    }

    @Test("A non-authoritative agent is sent no DNS opinion at all")
    func peerReceivesNilZones() async throws {
        try await withDNSSyncApp { app, org, project in
            let site = Site(name: "dc-peer", organizationScope: .organization(try org.requireID()))
            try await site.save(on: app.db)
            let siteID = try site.requireID()
            let controller = try await self.registerAgent(app: app, named: "controller", siteID: siteID)
            let peer = try await self.registerAgent(app: app, named: "peer", siteID: siteID)
            site.$networkControllerAgent.id = UUID(uuidString: controller)
            try await site.save(on: app.db)

            let network = try await TestDataBuilder(db: app.db).createNetwork(
                name: "dns-net", project: project, subnet: "10.61.0.0/24", gateway: "10.61.0.1",
                site: site)
            let zone = DNSZone(name: "acme.internal", projectID: try project.requireID())
            try await zone.save(on: app.db)
            try await self.attachZone(app: app, zone: zone, to: network, primary: true)
            try await self.placeVM(
                app: app, project: project, named: "vm-peer", hostname: "peer-vm",
                onAgent: peer, network: network, ipv4: "10.61.0.5")

            // Nil, not `[]`: the rows are the controller's, and an empty
            // opinion would have the peer sweep them.
            let peerSync = try await app.desiredStateAssembler.assemble(agentId: peer)
            #expect(peerSync.dnsZones == nil)
            #expect(try await app.desiredStateAssembler.assemble(agentId: controller).dnsZones != nil)
        }
    }

    @Test("A site-less agent realizes the zones its own VMs' networks attach")
    func siteLessAgentIsItsOwnAuthority() async throws {
        try await withDNSSyncApp { app, _, project in
            let agentId = try await self.registerAgent(app: app, named: "solo")
            let network = try await TestDataBuilder(db: app.db).createNetwork(
                name: "solo-net", project: project, subnet: "10.62.0.0/24", gateway: "10.62.0.1")
            let zone = DNSZone(name: "solo.internal", projectID: try project.requireID())
            try await zone.save(on: app.db)
            try await self.attachZone(app: app, zone: zone, to: network, primary: true)
            try await self.placeVM(
                app: app, project: project, named: "vm-solo", hostname: "solo-vm",
                onAgent: agentId, network: network, ipv4: "10.62.0.5")

            let zones = try #require(try await app.desiredStateAssembler.assemble(agentId: agentId).dnsZones)
            #expect(zones.map(\.zoneName) == ["solo.internal"])
            #expect(zones[0].records.contains { $0.name == "solo-vm.solo.internal" })
        }
    }

    @Test("A pre-v36 agent is sent no DNS zones")
    func oldAgentReceivesNoZones() async throws {
        try await withDNSSyncApp { app, _, project in
            let agentId = try await self.registerAgent(
                app: app, named: "old", protocolVersion: WireProtocol.dnsZoneMinimumVersion - 1)
            let network = try await TestDataBuilder(db: app.db).createNetwork(
                name: "old-net", project: project, subnet: "10.63.0.0/24", gateway: "10.63.0.1")
            let zone = DNSZone(name: "old.internal", projectID: try project.requireID())
            try await zone.save(on: app.db)
            try await self.attachZone(app: app, zone: zone, to: network, primary: true)
            try await self.placeVM(
                app: app, project: project, named: "vm-old", hostname: "old-vm",
                onAgent: agentId, network: network, ipv4: "10.63.0.5")

            #expect(try await app.desiredStateAssembler.assemble(agentId: agentId).dnsZones == nil)
        }
    }

    @Test("An agent whose networks attach no zone gets an empty, authoritative list")
    func noZonesIsAnOpinion() async throws {
        try await withDNSSyncApp { app, _, project in
            let agentId = try await self.registerAgent(app: app, named: "zoneless")
            let network = try await TestDataBuilder(db: app.db).createNetwork(
                name: "zoneless-net", project: project, subnet: "10.64.0.0/24", gateway: "10.64.0.1")
            try await self.placeVM(
                app: app, project: project, named: "vm", hostname: "vm", onAgent: agentId,
                network: network, ipv4: "10.64.0.5")

            // `[]`, not nil: the agent must remove any managed row it still
            // holds, which is what makes detaching the last zone take effect.
            #expect(try await app.desiredStateAssembler.assemble(agentId: agentId).dnsZones == [])
        }
    }

    // MARK: - Contents

    @Test("Authored records ride the zone; the hash moves only when they do")
    func authoredRecordsAndHash() async throws {
        try await withDNSSyncApp { app, _, project in
            let agentId = try await self.registerAgent(app: app, named: "hash-agent")
            let network = try await TestDataBuilder(db: app.db).createNetwork(
                name: "hash-net", project: project, subnet: "10.65.0.0/24", gateway: "10.65.0.1")
            let zone = DNSZone(name: "hash.internal", projectID: try project.requireID())
            try await zone.save(on: app.db)
            let zoneID = try zone.requireID()
            try await self.attachZone(app: app, zone: zone, to: network, primary: true)
            try await self.placeVM(
                app: app, project: project, named: "vm", hostname: "web", onAgent: agentId,
                network: network, ipv4: "10.65.0.5", ipv6: "fd65::5")

            let first = try #require(
                try await app.desiredStateAssembler.assemble(agentId: agentId).dnsZones?.first)
            // A dual-stack VM registers both families as separate RRsets: the
            // driver decides how to join them, not the wire.
            #expect(first.records.filter { $0.name == "web.hash.internal" }.map(\.type).sorted() == ["A", "AAAA"])

            // Re-assembling identical state must hash identically, or the agent
            // rewrites the whole record map on every sync.
            let again = try #require(
                try await app.desiredStateAssembler.assemble(agentId: agentId).dnsZones?.first)
            #expect(again.recordsHash == first.recordsHash)

            // An authored record the OVN driver can't express still moves the
            // hash: the stamp means "written from this version of the zone".
            try await DNSRecord(zoneID: zoneID, name: "www", type: .cname, value: "web.hash.internal")
                .save(on: app.db)
            let third = try #require(
                try await app.desiredStateAssembler.assemble(agentId: agentId).dnsZones?.first)
            #expect(third.recordsHash != first.recordsHash)
            #expect(third.records.contains { $0.type == "CNAME" && $0.name == "www.hash.internal" })
        }
    }

    @Test("Zones assembled together stay separate, each with only its own networks' addresses")
    func batchedAssemblyKeepsZonesSeparate() async throws {
        // The sync assembles every zone in one batch, so the grouping is the
        // thing that can break: a VM multi-homed across two networks with
        // different primary zones registers in both, and each zone must carry
        // that zone's suffix and only the addresses its own networks allocated.
        try await withDNSSyncApp { app, _, project in
            let agentId = try await self.registerAgent(app: app, named: "batch-agent")
            let builder = TestDataBuilder(db: app.db)
            let front = try await builder.createNetwork(
                name: "front", project: project, subnet: "10.68.0.0/24", gateway: "10.68.0.1")
            let back = try await builder.createNetwork(
                name: "back", project: project, subnet: "10.69.0.0/24", gateway: "10.69.0.1")
            let frontZone = DNSZone(name: "front.internal", projectID: try project.requireID())
            try await frontZone.save(on: app.db)
            let backZone = DNSZone(name: "back.internal", projectID: try project.requireID())
            try await backZone.save(on: app.db)
            try await self.attachZone(app: app, zone: frontZone, to: front, primary: true)
            try await self.attachZone(app: app, zone: backZone, to: back, primary: true)

            let vm = try await self.placeVM(
                app: app, project: project, named: "multi", hostname: "multi", onAgent: agentId,
                network: front, ipv4: "10.68.0.5")
            // A second NIC on the other network, so one VM lands in both zones.
            let nic = VMNetworkInterface(
                vmID: try vm.requireID(), logicalNetworkID: try back.requireID(),
                macAddress: "00:0c:29:00:00:02", deviceName: "net1", orderIndex: 1)
            try await nic.save(on: app.db)
            try await VMInterfaceAddress(
                interfaceID: try nic.requireID(), logicalNetworkID: try back.requireID(),
                family: .ipv4, address: "10.69.0.9", prefixLength: 24, gateway: back.gateway
            ).save(on: app.db)

            let zones = try #require(try await app.desiredStateAssembler.assemble(agentId: agentId).dnsZones)
            #expect(zones.count == 2)
            let assembledFront = try #require(zones.first { $0.zoneName == "front.internal" })
            let assembledBack = try #require(zones.first { $0.zoneName == "back.internal" })
            #expect(
                assembledFront.records.first { $0.type == "A" }.map { ($0.name, $0.values) } ?? ("", [])
                    == ("multi.front.internal", ["10.68.0.5"]))
            #expect(
                assembledBack.records.first { $0.type == "A" }.map { ($0.name, $0.values) } ?? ("", [])
                    == ("multi.back.internal", ["10.69.0.9"]))
            // Each zone's PTR points at the name published in that zone.
            #expect(
                assembledFront.records.first { $0.type == "PTR" }?.values == ["multi.front.internal"])
            #expect(assembledBack.records.first { $0.type == "PTR" }?.values == ["multi.back.internal"])
        }
    }

    @Test("Records marked for external publication only are not sent to agents")
    func externalViewRecordsAreWithheld() async throws {
        try await withDNSSyncApp { app, _, project in
            let agentId = try await self.registerAgent(app: app, named: "view-agent")
            let network = try await TestDataBuilder(db: app.db).createNetwork(
                name: "view-net", project: project, subnet: "10.66.0.0/24", gateway: "10.66.0.1")
            let zone = DNSZone(name: "view.internal", projectID: try project.requireID())
            try await zone.save(on: app.db)
            let zoneID = try zone.requireID()
            try await self.attachZone(app: app, zone: zone, to: network, primary: true)
            try await self.placeVM(
                app: app, project: project, named: "vm", hostname: "vm", onAgent: agentId,
                network: network, ipv4: "10.66.0.5")

            try await DNSRecord(
                zoneID: zoneID, name: "public", type: .a, value: "203.0.113.7", view: .external
            ).save(on: app.db)
            try await DNSRecord(
                zoneID: zoneID, name: "shared", type: .a, value: "10.66.0.9", view: .both
            ).save(on: app.db)

            let assembled = try #require(
                try await app.desiredStateAssembler.assemble(agentId: agentId).dnsZones?.first)
            #expect(!assembled.records.contains { $0.name == "public.view.internal" })
            #expect(assembled.records.contains { $0.name == "shared.view.internal" })
        }
    }

    @Test("A zone attached without being primary still resolves, without registrations")
    func attachedButNotPrimary() async throws {
        try await withDNSSyncApp { app, _, project in
            let agentId = try await self.registerAgent(app: app, named: "shared-agent")
            let network = try await TestDataBuilder(db: app.db).createNetwork(
                name: "shared-net", project: project, subnet: "10.67.0.0/24", gateway: "10.67.0.1")
            let shared = DNSZone(name: "services.internal", projectID: try project.requireID())
            try await shared.save(on: app.db)
            try await self.attachZone(app: app, zone: shared, to: network, primary: false)
            try await DNSRecord(
                zoneID: try shared.requireID(), name: "db", type: .a, value: "10.67.0.20"
            ).save(on: app.db)
            try await self.placeVM(
                app: app, project: project, named: "vm", hostname: "client", onAgent: agentId,
                network: network, ipv4: "10.67.0.5")

            let assembled = try #require(
                try await app.desiredStateAssembler.assemble(agentId: agentId).dnsZones?.first)
            // Attachment grants resolution; registration is the primary
            // pointer, which this network doesn't have.
            #expect(assembled.records.map(\.name) == ["db.services.internal"])
        }
    }

    // MARK: - The per-network resolver (STR-40)

    @Test("A non-authoritative agent running a NIC on the network is sent its zones")
    func resolverPeerReceivesZones() async throws {
        // The widening phase 4 needs: OVN `DNS` rows stay switch-scoped and only
        // the controller writes them, but a resolver runs wherever the guests
        // are, so the peer needs the zone's contents to render its zone files.
        try await withDNSSyncApp { app, org, project in
            let site = Site(name: "dc-resolver", organizationScope: .organization(try org.requireID()))
            try await site.save(on: app.db)
            let siteID = try site.requireID()
            let controller = try await self.registerAgent(
                app: app, named: "res-controller", siteID: siteID, resolverCapable: true)
            let peer = try await self.registerAgent(
                app: app, named: "res-peer", siteID: siteID, resolverCapable: true)
            site.$networkControllerAgent.id = UUID(uuidString: controller)
            try await site.save(on: app.db)

            let network = try await TestDataBuilder(db: app.db).createNetwork(
                name: "res-net", project: project, subnet: "10.70.0.0/24", gateway: "10.70.0.1",
                site: site)
            network.resolverEnabled = true
            try await network.save(on: app.db)
            let zone = DNSZone(name: "res.internal", projectID: try project.requireID())
            try await zone.save(on: app.db)
            try await self.attachZone(app: app, zone: zone, to: network, primary: true)
            try await self.placeVM(
                app: app, project: project, named: "vm-res", hostname: "res-vm",
                onAgent: peer, network: network, ipv4: "10.70.0.5")

            let sync = try await app.desiredStateAssembler.assemble(agentId: peer)
            #expect(sync.networksAuthoritative == false)
            let zones = try #require(sync.dnsZones)
            #expect(zones.map(\.zoneName) == ["res.internal"])
            // Fleet-wide records still, and the peer knows it may not author
            // topology — which is how it decides to realize only the resolver
            // half.
            #expect(zones[0].records.contains { $0.name == "res-vm.res.internal" })
        }
    }

    @Test("A non-authoritative agent with no local NIC on a zoned network still gets nil")
    func resolverPeerWithoutLocalNICStillNil() async throws {
        // Sending `[]` to a peer of the controller would have it read the
        // controller's live rows as garbage to sweep, which is the reason nil
        // exists here. Widening the scope must not weaken that.
        try await withDNSSyncApp { app, org, project in
            let site = Site(name: "dc-idle", organizationScope: .organization(try org.requireID()))
            try await site.save(on: app.db)
            let siteID = try site.requireID()
            let controller = try await self.registerAgent(
                app: app, named: "idle-controller", siteID: siteID, resolverCapable: true)
            let peer = try await self.registerAgent(
                app: app, named: "idle-peer", siteID: siteID, resolverCapable: true)
            site.$networkControllerAgent.id = UUID(uuidString: controller)
            try await site.save(on: app.db)

            let network = try await TestDataBuilder(db: app.db).createNetwork(
                name: "idle-net", project: project, subnet: "10.71.0.0/24", gateway: "10.71.0.1",
                site: site)
            network.resolverEnabled = true
            try await network.save(on: app.db)
            let zone = DNSZone(name: "idle.internal", projectID: try project.requireID())
            try await zone.save(on: app.db)
            try await self.attachZone(app: app, zone: zone, to: network, primary: true)
            try await self.placeVM(
                app: app, project: project, named: "vm-idle", hostname: "idle-vm",
                onAgent: controller, network: network, ipv4: "10.71.0.5")

            #expect(try await app.desiredStateAssembler.assemble(agentId: peer).dnsZones == nil)
        }
    }

    @Test("resolverEnabled reaches the network state and every NIC spec")
    func resolverReachesBothCarriers() async throws {
        try await withDNSSyncApp { app, _, project in
            let agentId = try await self.registerAgent(
                app: app, named: "res-solo", resolverCapable: true)
            let network = try await TestDataBuilder(db: app.db).createNetwork(
                name: "res-solo-net", project: project, subnet: "10.72.0.0/24", gateway: "10.72.0.1")
            network.resolverEnabled = true
            try await network.save(on: app.db)
            try await self.placeVM(
                app: app, project: project, named: "vm", hostname: "vm", onAgent: agentId,
                network: network, ipv4: "10.72.0.5")

            let sync = try await app.desiredStateAssembler.assemble(agentId: agentId)
            // Both halves, and they must agree: the network carrier authors the
            // localport and the DHCP row, the per-NIC copy reaches the chassis.
            #expect(sync.networks.first?.resolverEnabled == true)
            #expect(sync.vms.first?.spec.networks.first?.resolverEnabled == true)
        }
    }

    @Test("One incapable agent withholds the resolver from every network in the site")
    func siteWideCapabilityGate() async throws {
        // The DHCP option is authored once per network by the topology
        // authority while the listener is per chassis, so enabling it with one
        // un-provisioned host would give the network DNS that works until a VM
        // lands somewhere else.
        try await withDNSSyncApp { app, org, project in
            let site = Site(name: "dc-mixed", organizationScope: .organization(try org.requireID()))
            try await site.save(on: app.db)
            let siteID = try site.requireID()
            let controller = try await self.registerAgent(
                app: app, named: "mixed-controller", siteID: siteID, resolverCapable: true)
            _ = try await self.registerAgent(
                app: app, named: "mixed-laggard", siteID: siteID, resolverCapable: false)
            site.$networkControllerAgent.id = UUID(uuidString: controller)
            try await site.save(on: app.db)

            let network = try await TestDataBuilder(db: app.db).createNetwork(
                name: "mixed-net", project: project, subnet: "10.73.0.0/24", gateway: "10.73.0.1",
                site: site)
            network.resolverEnabled = true
            try await network.save(on: app.db)
            try await self.placeVM(
                app: app, project: project, named: "vm", hostname: "vm", onAgent: controller,
                network: network, ipv4: "10.73.0.5")

            let sync = try await app.desiredStateAssembler.assemble(agentId: controller)
            // False, not nil: the agent speaks v37, so the control plane has an
            // opinion — and that opinion is "not yet".
            #expect(sync.networks.first?.resolverEnabled == false)
            #expect(sync.vms.first?.spec.networks.first?.resolverEnabled == false)
        }
    }

    @Test("A pre-v37 agent is sent no resolver opinion at all")
    func preV37AgentGetsNilResolver() async throws {
        try await withDNSSyncApp { app, _, project in
            let agentId = try await self.registerAgent(
                app: app, named: "res-old",
                protocolVersion: WireProtocol.networkResolverMinimumVersion - 1,
                resolverCapable: true)
            let network = try await TestDataBuilder(db: app.db).createNetwork(
                name: "res-old-net", project: project, subnet: "10.74.0.0/24", gateway: "10.74.0.1")
            network.resolverEnabled = true
            try await network.save(on: app.db)
            try await self.placeVM(
                app: app, project: project, named: "vm", hostname: "vm", onAgent: agentId,
                network: network, ipv4: "10.74.0.5")

            let sync = try await app.desiredStateAssembler.assemble(agentId: agentId)
            // Nil rather than false, so the agent's own absence check and the
            // version gate say the same thing: "no opinion", never "off".
            #expect(sync.networks.first?.resolverEnabled == nil)
            #expect(sync.vms.first?.spec.networks.first?.resolverEnabled == nil)
        }
    }

    @Test("Turning the network's resolver off reaches both carriers as false")
    func resolverOptOutIsHonored() async throws {
        try await withDNSSyncApp { app, _, project in
            let agentId = try await self.registerAgent(
                app: app, named: "res-off", resolverCapable: true)
            let network = try await TestDataBuilder(db: app.db).createNetwork(
                name: "res-off-net", project: project, subnet: "10.75.0.0/24", gateway: "10.75.0.1")
            network.resolverEnabled = false
            try await network.save(on: app.db)
            try await self.placeVM(
                app: app, project: project, named: "vm", hostname: "vm", onAgent: agentId,
                network: network, ipv4: "10.75.0.5")

            let sync = try await app.desiredStateAssembler.assemble(agentId: agentId)
            #expect(sync.networks.first?.resolverEnabled == false)
            #expect(sync.vms.first?.spec.networks.first?.resolverEnabled == false)
        }
    }

    @Test("A record's TTL travels, and moves the zone's hash")
    func recordTTLTravelsAndHashes() async throws {
        // v36 dropped the TTL because an OVN row has nowhere to put it; a zone
        // file writes one per RRset, so a TTL-only edit has to reach the
        // resolver — which means it has to move the hash the agent skips on.
        try await withDNSSyncApp { app, _, project in
            let agentId = try await self.registerAgent(app: app, named: "ttl-agent")
            let network = try await TestDataBuilder(db: app.db).createNetwork(
                name: "ttl-net", project: project, subnet: "10.76.0.0/24", gateway: "10.76.0.1")
            let zone = DNSZone(name: "ttl.internal", projectID: try project.requireID())
            try await zone.save(on: app.db)
            try await self.attachZone(app: app, zone: zone, to: network, primary: true)
            try await self.placeVM(
                app: app, project: project, named: "vm", hostname: "vm", onAgent: agentId,
                network: network, ipv4: "10.76.0.5")

            let record = DNSRecord(
                zoneID: try zone.requireID(), name: "www", type: .cname, value: "vm.ttl.internal",
                ttl: 60)
            try await record.save(on: app.db)

            let before = try #require(
                try await app.desiredStateAssembler.assemble(agentId: agentId).dnsZones?.first)
            let cname = try #require(before.records.first { $0.type == "CNAME" })
            #expect(cname.ttl == 60)

            record.ttl = 120
            try await record.save(on: app.db)
            let after = try #require(
                try await app.desiredStateAssembler.assemble(agentId: agentId).dnsZones?.first)
            #expect(after.recordsHash != before.recordsHash)
            #expect(after.records.first { $0.type == "CNAME" }?.ttl == 120)
        }
    }

    @Test("An agent this assembly cannot load is told nothing about resolvers")
    func unknownAgentGetsSilence() async throws {
        // `false` here would be an opinion, and an opinion is a teardown: it
        // strips the resolver's addresses from the localport, reverts the DHCP
        // row, and stops CoreDNS — on the one path that knows nothing about the
        // host it is describing. Silence is the only honest answer.
        try await withDNSSyncApp { app, _, project in
            let network = try await TestDataBuilder(db: app.db).createNetwork(
                name: "ghost-net", project: project, subnet: "10.77.0.0/24", gateway: "10.77.0.1")
            network.resolverEnabled = true
            try await network.save(on: app.db)

            // An agent id no row matches — the synthetic and backstop syncs.
            let sync = try await app.desiredStateAssembler.assemble(agentId: UUID().uuidString)
            #expect(sync.networks.allSatisfy { $0.resolverEnabled == nil })
            #expect(
                sync.vms.allSatisfy { vm in
                    vm.spec.networks.allSatisfy { $0.resolverEnabled == nil }
                })
        }
    }
}
