import Fluent
import StratoShared
import Testing
import Vapor
import VaporTesting

@testable import App

/// Tests for sites (availability zones, issue #343): the sites API and its
/// topology-safety guards, site assignment at agent registration, the
/// scheduler's site hard constraint, and site-aware desired-state assembly
/// (network-controller authority and site-wide network scoping).
@Suite("Site Tests", .serialized)
final class SiteTests {

    private func withSiteTestApp(
        _ test: (Application, User, Project, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            // Site topology endpoints are system-admin only.
            let admin = try await builder.createUser(
                username: "siteadmin",
                email: "siteadmin@example.com",
                displayName: "Site Admin",
                isSystemAdmin: true
            )
            let org = try await builder.createOrganization(name: "Site Org")
            try await builder.addUserToOrganization(user: admin, organization: org, role: "admin")
            admin.currentOrganizationId = org.id
            try await admin.save(on: app.db)

            let project = try await builder.createProject(
                name: "Site Project",
                description: "Project for site tests",
                organization: org
            )
            let token = try await admin.generateAPIKey(on: app.db)

            try await test(app, admin, project, token)

        } catch {
            try await app.shutdownForTesting()
            throw error
        }

        try await app.shutdownForTesting()
    }

    /// Registers an in-memory agent, optionally into a site (as its
    /// registration token would). Returns the agent's UUID string.
    private func registerAgent(
        app: Application, named name: String, siteID: UUID? = nil,
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
        let uuid = try await app.agentService.registerAgent(message, agentName: name, siteID: siteID)
        return uuid.uuidString
    }

    private func placeVM(
        app: Application, project: Project, named name: String, onAgent agentId: String, network: String
    ) async throws {
        let builder = TestDataBuilder(db: app.db)
        let vm = try await builder.createVM(name: name, project: project)
        vm.hypervisorId = agentId
        try await vm.save(on: app.db)
        let nic = VMNetworkInterface(
            vmID: vm.id!, network: network, macAddress: VMNetworkInterface.generateMACAddress())
        try await nic.save(on: app.db)
    }

    // MARK: - Sites API

    @Test("Site CRUD round-trips and rejects duplicate names")
    func siteCRUD() async throws {
        try await withSiteTestApp { app, _, _, token in
            var siteId: UUID?
            try await app.test(.POST, "/api/sites") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(CreateSiteRequest(name: "dc-east", description: "rack 1"))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let site = try res.content.decode(SiteResponse.self)
                #expect(site.name == "dc-east")
                #expect(site.networkControllerAgentId == nil)
                siteId = site.id
            }

            try await app.test(.POST, "/api/sites") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(CreateSiteRequest(name: "dc-east", description: nil))
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            try await app.test(.GET, "/api/sites/\(siteId!.uuidString)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let site = try res.content.decode(SiteResponse.self)
                #expect(site.id == siteId)
            }
        }
    }

    @Test("Designating a network controller requires site membership")
    func controllerMustBeMember() async throws {
        try await withSiteTestApp { app, _, _, token in
            let site = Site(name: "dc-a")
            try await site.save(on: app.db)
            let outsiderId = try await self.registerAgent(app: app, named: "outsider")

            try await app.test(.PUT, "/api/sites/\(site.id!.uuidString)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    UpdateSiteRequest(description: nil, networkControllerAgentId: UUID(uuidString: outsiderId)))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            // Once the agent is a member, designation succeeds.
            let memberId = try await self.registerAgent(app: app, named: "member", siteID: site.id)
            try await app.test(.PUT, "/api/sites/\(site.id!.uuidString)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    UpdateSiteRequest(description: nil, networkControllerAgentId: UUID(uuidString: memberId)))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let updated = try res.content.decode(SiteResponse.self)
                #expect(updated.networkControllerAgentId?.uuidString == memberId)
            }
        }
    }

    @Test("A site with members or pinned networks refuses deletion")
    func deleteGuards() async throws {
        try await withSiteTestApp { app, _, _, token in
            let site = Site(name: "dc-b")
            try await site.save(on: app.db)
            _ = try await self.registerAgent(app: app, named: "occupant", siteID: site.id)

            try await app.test(.DELETE, "/api/sites/\(site.id!.uuidString)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
        }
    }

    @Test("The designated network controller cannot be removed from its site")
    func controllerRemovalGuard() async throws {
        try await withSiteTestApp { app, _, _, token in
            let site = Site(name: "dc-c")
            try await site.save(on: app.db)
            let controllerId = try await self.registerAgent(app: app, named: "ctl", siteID: site.id)
            site.$networkControllerAgent.id = UUID(uuidString: controllerId)
            try await site.save(on: app.db)

            try await app.test(.DELETE, "/api/sites/\(site.id!.uuidString)/agents/\(controllerId)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
        }
    }

    @Test("Assigning an agent that controls another site is refused")
    func controllerMoveGuard() async throws {
        try await withSiteTestApp { app, _, _, token in
            let oldSite = Site(name: "dc-old")
            try await oldSite.save(on: app.db)
            let newSite = Site(name: "dc-new")
            try await newSite.save(on: app.db)

            let controllerId = try await self.registerAgent(app: app, named: "moving-ctl", siteID: oldSite.id)
            oldSite.$networkControllerAgent.id = UUID(uuidString: controllerId)
            try await oldSite.save(on: app.db)

            // Moving the old site's controller would leave that site pointing
            // at a non-member and stop its network reconciliation.
            try await app.test(.POST, "/api/sites/\(newSite.id!.uuidString)/agents/\(controllerId)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
            let agent = try #require(try await Agent.find(UUID(uuidString: controllerId), on: app.db))
            #expect(agent.$site.id == oldSite.id)

            // A registration token targeting the new site must not move it
            // either — the assignment is ignored, not applied.
            _ = try await self.registerAgent(app: app, named: "moving-ctl", siteID: newSite.id)
            let after = try #require(try await Agent.find(UUID(uuidString: controllerId), on: app.db))
            #expect(after.$site.id == oldSite.id)
        }
    }

    @Test("An agent hosting VMs cannot change site (API and token paths)")
    func hostedVMMoveGuard() async throws {
        try await withSiteTestApp { app, _, project, token in
            let oldSite = Site(name: "dc-vm-old")
            try await oldSite.save(on: app.db)
            let newSite = Site(name: "dc-vm-new")
            try await newSite.save(on: app.db)

            let agentId = try await self.registerAgent(app: app, named: "loaded", siteID: oldSite.id)
            try await self.placeVM(
                app: app, project: project, named: "resident-vm", onAgent: agentId,
                network: LogicalNetwork.defaultNetworkName)

            // Moving it would drop its VMs' networks out of the old site's
            // shared NB while the VMs keep running.
            try await app.test(.POST, "/api/sites/\(newSite.id!.uuidString)/agents/\(agentId)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            // The token path refuses the same move (logged, not fatal).
            _ = try await self.registerAgent(app: app, named: "loaded", siteID: newSite.id)
            let agent = try #require(try await Agent.find(UUID(uuidString: agentId), on: app.db))
            #expect(agent.$site.id == oldSite.id)

            // Re-registering into the SAME site is a no-op, not a refusal.
            _ = try await self.registerAgent(app: app, named: "loaded", siteID: oldSite.id)
            let unchanged = try #require(try await Agent.find(UUID(uuidString: agentId), on: app.db))
            #expect(unchanged.$site.id == oldSite.id)
        }
    }

    @Test("Sites API requires a system admin")
    func sitesRequireAdmin() async throws {
        try await withSiteTestApp { app, _, _, _ in
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "plainuser", email: "plain@example.com",
                displayName: "Plain", isSystemAdmin: false)
            let token = try await user.generateAPIKey(on: app.db)

            try await app.test(.GET, "/api/sites") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    // MARK: - Registration site assignment

    @Test("Registration assigns the token's site; re-registration without one preserves it")
    func registrationSiteAssignment() async throws {
        try await withSiteTestApp { app, _, _, _ in
            let site = Site(name: "dc-d")
            try await site.save(on: app.db)

            let agentId = try await self.registerAgent(app: app, named: "node-1", siteID: site.id)
            var agent = try #require(try await Agent.find(UUID(uuidString: agentId), on: app.db))
            #expect(agent.$site.id == site.id)

            // Reconnect with a rotated token that carries no site: the
            // assignment is durable on the agent row.
            _ = try await self.registerAgent(app: app, named: "node-1", siteID: nil)
            agent = try #require(try await Agent.find(UUID(uuidString: agentId), on: app.db))
            #expect(agent.$site.id == site.id)
        }
    }

    // MARK: - Scheduler site constraint

    private func makeSchedulable(
        id: String = UUID().uuidString, name: String, siteID: UUID? = nil,
        wireProtocolVersion: Int = WireProtocol.currentVersion
    ) -> SchedulableAgent {
        SchedulableAgent(
            id: id, name: name,
            totalCPU: 16, availableCPU: 16,
            totalMemory: 1 << 34, availableMemory: 1 << 34,
            totalDisk: 1 << 40, availableDisk: 1 << 40,
            status: .online, runningVMCount: 0,
            supportedHypervisors: [.qemu],
            siteID: siteID,
            wireProtocolVersion: wireProtocolVersion
        )
    }

    @Test("Site requirement filters placement to the site's agents")
    func schedulerSiteFilter() throws {
        let siteA = UUID()
        let siteB = UUID()
        let inSite = makeSchedulable(name: "in-site", siteID: siteA)
        let elsewhere = makeSchedulable(name: "elsewhere", siteID: siteB)
        let siteless = makeSchedulable(name: "siteless")

        let scheduler = SchedulerService(logger: Logger(label: "test"))
        let requirements = VMPlacementRequirements(
            cpu: 1, memory: 1 << 30, disk: 1 << 30, siteID: siteA)

        let selected = try scheduler.selectAgent(
            requirements: requirements, from: [elsewhere, siteless, inSite])
        #expect(selected == inSite.id)
    }

    @Test("Site requirement with no member agents fails with the site error")
    func schedulerSiteUnsatisfied() {
        let scheduler = SchedulerService(logger: Logger(label: "test"))
        let requirements = VMPlacementRequirements(
            cpu: 1, memory: 1 << 30, disk: 1 << 30, siteID: UUID())

        #expect(throws: SchedulerError.self) {
            try scheduler.selectAgent(
                requirements: requirements,
                from: [self.makeSchedulable(name: "siteless"), self.makeSchedulable(name: "other", siteID: UUID())]
            )
        }
    }

    @Test("Site requirement excludes members on a pre-site-authority protocol")
    func schedulerSiteFilterExcludesOldProtocol() throws {
        let siteA = UUID()
        // A pre-v4 member is kept on legacy per-node network scoping, so a
        // pinned-network VM placed there would land in its private local NB.
        let oldMember = makeSchedulable(name: "old-member", siteID: siteA, wireProtocolVersion: 3)
        let newMember = makeSchedulable(name: "new-member", siteID: siteA)

        let scheduler = SchedulerService(logger: Logger(label: "test"))
        let requirements = VMPlacementRequirements(
            cpu: 1, memory: 1 << 30, disk: 1 << 30, siteID: siteA)

        let selected = try scheduler.selectAgent(
            requirements: requirements, from: [oldMember, newMember])
        #expect(selected == newMember.id)

        #expect(throws: SchedulerError.self) {
            try scheduler.selectAgent(requirements: requirements, from: [oldMember])
        }
    }

    @Test("Unconstrained VMs still place on sited and site-less agents alike")
    func schedulerNoSiteRequirement() throws {
        let scheduler = SchedulerService(logger: Logger(label: "test"))
        let requirements = VMPlacementRequirements(cpu: 1, memory: 1 << 30, disk: 1 << 30)
        let agents = [makeSchedulable(name: "sited", siteID: UUID())]
        let selected = try scheduler.selectAgent(requirements: requirements, from: agents)
        #expect(selected == agents[0].id)
    }

    // MARK: - Site-aware desired-state assembly

    @Test("The site's network controller gets the whole site's networks, authoritative")
    func controllerAssembly() async throws {
        try await withSiteTestApp { app, _, project, _ in
            let site = Site(name: "dc-e")
            try await site.save(on: app.db)

            let controllerId = try await self.registerAgent(app: app, named: "ctl-agent", siteID: site.id)
            let peerId = try await self.registerAgent(app: app, named: "peer-agent", siteID: site.id)
            site.$networkControllerAgent.id = UUID(uuidString: controllerId)
            try await site.save(on: app.db)

            // One network referenced only by a VM on the peer, one pinned to
            // the site with no VMs at all.
            let peerNet = LogicalNetwork(
                name: "peer-net", subnet: "10.30.0.0/24", gateway: "10.30.0.1",
                projectID: project.id)
            try await peerNet.save(on: app.db)
            let pinnedNet = LogicalNetwork(
                name: "pinned-net", subnet: "10.31.0.0/24", gateway: "10.31.0.1",
                projectID: project.id, siteID: site.id!)
            try await pinnedNet.save(on: app.db)
            try await self.placeVM(
                app: app, project: project, named: "peer-vm", onAgent: peerId, network: "peer-net")

            // Controller: authoritative, sees the peer's network and the
            // pinned-but-unused one — even with no VMs of its own.
            let controllerSync = try await app.agentService.assembleDesiredState(agentId: controllerId)
            #expect(controllerSync.networksAuthoritative)
            let names = Set(controllerSync.networks.map(\.name))
            #expect(names.contains("peer-net"))
            #expect(names.contains("pinned-net"))

            // Peer: hosts the VM (so the VM itself syncs to it), but topology
            // belongs to the controller.
            let peerSync = try await app.agentService.assembleDesiredState(agentId: peerId)
            #expect(!peerSync.networksAuthoritative)
            #expect(peerSync.networks.isEmpty)
            #expect(peerSync.vms.count == 1)
        }
    }

    @Test("A site with no designated controller gives no agent authority")
    func noControllerAssembly() async throws {
        try await withSiteTestApp { app, _, project, _ in
            let site = Site(name: "dc-f")
            try await site.save(on: app.db)
            let agentId = try await self.registerAgent(app: app, named: "lone-agent", siteID: site.id)
            try await self.placeVM(
                app: app, project: project, named: "lone-vm", onAgent: agentId,
                network: LogicalNetwork.defaultNetworkName)

            let sync = try await app.agentService.assembleDesiredState(agentId: agentId)
            #expect(!sync.networksAuthoritative)
            #expect(sync.networks.isEmpty)
            // The VM still syncs — only topology is withheld.
            #expect(sync.vms.count == 1)
        }
    }

    @Test("A sited agent on a pre-v4 protocol keeps legacy scoping (rolling-upgrade safety)")
    func preSiteAuthorityAgentAssembly() async throws {
        try await withSiteTestApp { app, _, project, _ in
            let site = Site(name: "dc-skew")
            try await site.save(on: app.db)

            // A v3 binary predates `networksAuthoritative`: it would read the
            // non-authoritative shape (networks: [] + false) as an
            // authoritative teardown of all its L3. It must keep receiving its
            // own networks, authoritative, even though it's in a site.
            let oldAgentId = try await self.registerAgent(
                app: app, named: "old-binary", siteID: site.id, protocolVersion: 3)
            try await self.placeVM(
                app: app, project: project, named: "old-vm", onAgent: oldAgentId,
                network: LogicalNetwork.defaultNetworkName)

            let sync = try await app.agentService.assembleDesiredState(agentId: oldAgentId)
            #expect(sync.networksAuthoritative)
            #expect(sync.networks.contains { $0.name == LogicalNetwork.defaultNetworkName })
        }
    }

    @Test("A site-less agent keeps the legacy model: own networks, authoritative")
    func sitelessAssembly() async throws {
        try await withSiteTestApp { app, _, project, _ in
            let agentId = try await self.registerAgent(app: app, named: "legacy-agent")
            try await self.placeVM(
                app: app, project: project, named: "legacy-vm", onAgent: agentId,
                network: LogicalNetwork.defaultNetworkName)

            let sync = try await app.agentService.assembleDesiredState(agentId: agentId)
            #expect(sync.networksAuthoritative)
            #expect(sync.networks.contains { $0.name == LogicalNetwork.defaultNetworkName })
        }
    }
}
