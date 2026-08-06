import Fluent
import StratoShared
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

/// Tests for the project-scoped network management API (`/api/networks`):
/// listing (scoped to the caller's projects), creation with CIDR/gateway
/// validation and per-project name uniqueness, update guards while a network is
/// in use, and the delete-in-use protections.
@Suite("Network Controller Tests", .serialized)
final class NetworkControllerTests {

    private func withNetworkTestApp(
        _ test: (Application, User, Project, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "netuser",
                email: "net@example.com",
                displayName: "Network User",
                isSystemAdmin: false
            )
            let org = try await builder.createOrganization(name: "Network Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            user.currentOrganizationId = org.id
            try await user.save(on: app.db)

            let project = try await builder.createProject(
                name: "Network Project",
                description: "Project for network tests",
                organization: org
            )
            let token = try await user.generateAPIKey(on: app.db)

            try await test(app, user, project, token)

        } catch {
            try await app.shutdownForTesting()
            throw error
        }

        try await app.shutdownForTesting()
    }

    // MARK: - List

    @Test("GET /api/networks lists the caller's project's networks")
    func listIncludesProjectNetworks() async throws {
        try await withNetworkTestApp { app, _, project, token in
            let mine = try await TestDataBuilder(db: app.db).createNetwork(
                name: "listed-net", project: project, subnet: "10.8.0.0/24", gateway: "10.8.0.1")

            try await app.test(.GET, "/api/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let networks = try res.content.decode(PagedResponse<NetworkResponse>.self).items
                let listed = networks.first { $0.id == mine.id }
                #expect(listed?.name == "listed-net")
                #expect(listed?.projectId == project.id)
            }
        }
    }

    @Test("GET /api/networks?project_id excludes other projects' networks")
    func listScopesToProject() async throws {
        try await withNetworkTestApp { app, user, project, token in
            // A network in a different project that must not appear — including
            // one sharing the caller's network name, which is legal now.
            let builder = TestDataBuilder(db: app.db)
            let otherProject = try await builder.createProject(
                name: "Other Project",
                description: "not the caller's project",
                organization: try await Organization.find(user.currentOrganizationId, on: app.db)
            )
            try await builder.createNetwork(
                name: "shared-name", project: project, subnet: "10.8.0.0/24", gateway: "10.8.0.1")
            let hidden = try await builder.createNetwork(
                name: "shared-name", project: otherProject, subnet: "10.9.0.0/24", gateway: "10.9.0.1")

            try await app.test(.GET, "/api/networks?project_id=\(project.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let items = try res.content.decode(PagedResponse<NetworkResponse>.self).items
                #expect(items.allSatisfy { $0.projectId == project.id })
                #expect(!items.contains { $0.id == hidden.id })
            }
        }
    }

    @Test("GET /api/networks?project_id denied when no binding grants project read (403)")
    func listDeniedForInaccessibleProject() async throws {
        try await withNetworkTestApp { app, _, project, _ in
            // A bare org member: membership grants org:read + project:create
            // only, so the project_id filter's view_project check denies.
            let member = try await TestDataBuilder(db: app.db).createUser(
                username: "net-member", email: "net-member@example.com")
            let memberToken = try await member.generateAPIKey(on: app.db)

            try await app.test(.GET, "/api/networks?project_id=\(project.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: memberToken)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    // MARK: - Create

    @Test("POST /api/networks persists a valid network (200)")
    func createValidNetwork() async throws {
        try await withNetworkTestApp { app, _, project, token in
            try await app.test(.POST, "/api/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateNetworkRequest(
                        name: "app-net", subnet: "10.20.0.0/24", gateway: nil, projectId: project.id!))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let network = try res.content.decode(NetworkResponse.self)
                #expect(network.name == "app-net")
                #expect(network.subnet == "10.20.0.0/24")
                #expect(network.gateway == "10.20.0.1")  // defaulted to first host
                #expect(network.projectId == project.id)
                #expect(network.attachedInterfaceCount == 0)
            }

            let persisted = try await LogicalNetwork.query(on: app.db)
                .filter(\.$name == "app-net").first()
            #expect(persisted != nil)
        }
    }

    @Test("POST /api/networks defaults new networks to dual-stack with a generated ULA /64")
    func createDefaultsToGeneratedULA() async throws {
        try await withNetworkTestApp { app, _, project, token in
            try await app.test(.POST, "/api/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateNetworkRequest(
                        name: "dual-net", subnet: "10.21.0.0/24", gateway: nil, projectId: project.id!))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let network = try res.content.decode(NetworkResponse.self)
                let subnet6 = try #require(network.subnet6)
                // RFC 4193 ULA: fd-prefixed, canonical, and always a /64.
                #expect(subnet6.hasPrefix("fd"))
                #expect(subnet6.hasSuffix("::/64"))
                let gateway6 = try #require(network.gateway6)
                #expect(gateway6 == subnet6.replacingOccurrences(of: "::/64", with: "::1"))
            }
        }
    }

    @Test("POST /api/networks accepts an explicit IPv6 /64 and defaults its gateway")
    func createWithExplicitSubnet6() async throws {
        try await withNetworkTestApp { app, _, project, token in
            try await app.test(.POST, "/api/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateNetworkRequest(
                        name: "explicit6-net", subnet: "10.22.0.0/24", gateway: nil,
                        subnet6: "FD00:AB:CD:12:0:0:0:0/64", projectId: project.id!))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let network = try res.content.decode(NetworkResponse.self)
                // Canonicalized before storage.
                #expect(network.subnet6 == "fd00:ab:cd:12::/64")
                #expect(network.gateway6 == "fd00:ab:cd:12::1")
            }
        }
    }

    @Test("POST /api/networks with ipv6Enabled=false creates a v4-only network")
    func createV4Only() async throws {
        try await withNetworkTestApp { app, _, project, token in
            try await app.test(.POST, "/api/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateNetworkRequest(
                        name: "v4only-net", subnet: "10.23.0.0/24", gateway: nil,
                        ipv6Enabled: false, projectId: project.id!))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let network = try res.content.decode(NetworkResponse.self)
                #expect(network.subnet6 == nil)
                #expect(network.gateway6 == nil)
            }

            // subnet6 combined with the opt-out is contradictory → 400.
            try await app.test(.POST, "/api/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateNetworkRequest(
                        name: "contradiction-net", subnet: "10.24.0.0/24", gateway: nil,
                        subnet6: "fd00:1::/64", ipv6Enabled: false, projectId: project.id!))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("POST /api/networks rejects non-/64 and non-routable IPv6 subnets (400)")
    func createRejectsInvalidSubnet6() async throws {
        try await withNetworkTestApp { app, _, project, token in
            for subnet6 in ["fd00:1::/48", "fd00:1::/80", "ff02::/64", "fe80::/64", "::/64", "junk"] {
                try await app.test(.POST, "/api/networks") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    try req.content.encode(
                        CreateNetworkRequest(
                            name: "bad6-net", subnet: "10.25.0.0/24", gateway: nil,
                            subnet6: subnet6, projectId: project.id!))
                } afterResponse: { res in
                    #expect(res.status == .badRequest, "subnet6 '\(subnet6)' should be rejected")
                }
            }
        }
    }

    @Test("POST /api/networks rejects an IPv6 subnet overlapping a project sibling (409)")
    func createRejectsOverlappingSubnet6() async throws {
        try await withNetworkTestApp { app, user, project, token in
            let existing = LogicalNetwork(
                name: "sibling6-net", subnet: "10.26.0.0/24", gateway: "10.26.0.1",
                subnet6: "fd00:aa:bb:cc::/64", gateway6: "fd00:aa:bb:cc::1",
                projectID: project.id!, createdByID: user.id!)
            try await existing.save(on: app.db)

            try await app.test(.POST, "/api/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateNetworkRequest(
                        name: "clash6-net", subnet: "10.27.0.0/24", gateway: nil,
                        subnet6: "fd00:00aa:bb:cc::/64", projectId: project.id!))
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
        }
    }

    @Test("PUT /api/networks adds IPv6 to an in-use v4-only network, bumping the generation")
    func updateAddsIPv6ToInUseNetwork() async throws {
        try await withNetworkTestApp { app, user, project, token in
            let network = LogicalNetwork(
                name: "grow6-net", subnet: "10.28.0.0/24", gateway: "10.28.0.1",
                projectID: project.id!, createdByID: user.id!)
            try await network.save(on: app.db)
            // In use by a NIC — additive IPv6 must still be allowed.
            let vm = try await TestDataBuilder(db: app.db).createVM(name: "grow6-vm", project: project)
            let nic = VMNetworkInterface(
                vmID: vm.id!, logicalNetworkID: network.id!, macAddress: VMNetworkInterface.generateMACAddress())
            try await nic.save(on: app.db)

            try await app.test(.PUT, "/api/networks/\(network.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(UpdateNetworkRequest(ipv6Enabled: true))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let updated = try res.content.decode(NetworkResponse.self)
                #expect(updated.subnet6?.hasPrefix("fd") == true)
                #expect(updated.gateway6 != nil)
            }

            let persisted = try await LogicalNetwork.find(network.id, on: app.db)
            #expect(persisted?.generation == 2)
        }
    }

    @Test("PUT /api/networks rejects removing IPv6 while v6 addresses are allocated (409)")
    func updateRejectsRemovingIPv6InUse() async throws {
        try await withNetworkTestApp { app, user, project, token in
            let network = LogicalNetwork(
                name: "shrink6-net", subnet: "10.29.0.0/24", gateway: "10.29.0.1",
                subnet6: "fd00:29::/64", gateway6: "fd00:29::1",
                projectID: project.id!, createdByID: user.id!)
            try await network.save(on: app.db)
            let vm = try await TestDataBuilder(db: app.db).createVM(name: "shrink6-vm", project: project)
            let nic = VMNetworkInterface(
                vmID: vm.id!, logicalNetworkID: network.id!, macAddress: VMNetworkInterface.generateMACAddress())
            try await nic.save(on: app.db)
            let address6 = VMInterfaceAddress(
                interfaceID: nic.id!, logicalNetworkID: network.id!, family: .ipv6,
                address: "fd00:29::100", prefixLength: 64, gateway: "fd00:29::1")
            try await address6.save(on: app.db)

            try await app.test(.PUT, "/api/networks/\(network.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(UpdateNetworkRequest(ipv6Enabled: false))
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            // Changing the established subnet6 is equally rejected.
            try await app.test(.PUT, "/api/networks/\(network.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(UpdateNetworkRequest(subnet6: "fd00:99::/64"))
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
        }
    }

    @Test("POST /api/networks rejects an invalid subnet (400)")
    func createRejectsInvalidSubnet() async throws {
        try await withNetworkTestApp { app, _, project, token in
            try await app.test(.POST, "/api/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateNetworkRequest(
                        name: "bad-net", subnet: "10.0.0.0/31", gateway: nil, projectId: project.id!))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("POST /api/networks rejects a gateway outside the subnet (400)")
    func createRejectsGatewayOutsideSubnet() async throws {
        try await withNetworkTestApp { app, _, project, token in
            try await app.test(.POST, "/api/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateNetworkRequest(
                        name: "bad-gw", subnet: "10.30.0.0/24", gateway: "10.31.0.1", projectId: project.id!))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("POST /api/networks rejects a name already used in the same project (409)")
    func createRejectsDuplicateNameInProject() async throws {
        try await withNetworkTestApp { app, _, project, token in
            try await TestDataBuilder(db: app.db).createNetwork(
                name: "taken-net", project: project, subnet: "10.39.0.0/24", gateway: "10.39.0.1")

            try await app.test(.POST, "/api/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateNetworkRequest(
                        name: "taken-net", subnet: "10.40.0.0/24", gateway: nil,
                        projectId: project.id!))
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
        }
    }

    @Test("POST /api/networks refuses a cross-project name collision against a pre-v21 fleet")
    func createRefusesCollidingNameOnOldAgents() async throws {
        try await withNetworkTestApp { app, user, project, token in
            let builder = TestDataBuilder(db: app.db)
            let org = try #require(try await Organization.find(user.currentOrganizationId, on: app.db))
            let otherProject = try await builder.createProject(
                name: "Old Fleet Neighbour", description: "p", organization: org)
            try await builder.createNetwork(
                name: "collide-net", project: otherProject, subnet: "10.42.0.0/24", gateway: "10.42.0.1")

            // A pre-v21 agent keys its DHCP rows on the network *name*, so it
            // cannot tell two same-named networks apart (issue #765).
            let message = AgentRegisterMessage(
                agentId: "legacy-dhcp-agent",
                hostname: "legacy-host",
                version: "1.0.0",
                capabilities: ["qemu"],
                resources: AgentResources(
                    totalCPU: 8, availableCPU: 8,
                    totalMemory: 1 << 33, availableMemory: 1 << 33,
                    totalDisk: 1 << 39, availableDisk: 1 << 39
                ),
                protocolVersion: WireProtocol.projectNetworkIsolationMinimumVersion - 1
            )
            _ = try await app.agentService.registerAgent(
                message, agentName: message.agentId, organizationScope: .organization(org.id!))

            try await app.test(.POST, "/api/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateNetworkRequest(
                        name: "collide-net", subnet: "10.43.0.0/24", gateway: nil,
                        projectId: project.id!))
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("legacy-dhcp-agent"))
            }

            // A name nobody else uses is unaffected by the old agent.
            try await app.test(.POST, "/api/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateNetworkRequest(
                        name: "unique-net", subnet: "10.44.0.0/24", gateway: nil,
                        projectId: project.id!))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }
        }
    }

    @Test("A pre-v21 agent cannot register into a fleet that already has colliding names")
    func registrationRefusedWhenNamesAlreadyCollide() async throws {
        try await withNetworkTestApp { app, user, project, _ in
            let builder = TestDataBuilder(db: app.db)
            let org = try #require(try await Organization.find(user.currentOrganizationId, on: app.db))
            let neighbour = try await builder.createProject(
                name: "Late Rollback Neighbour", description: "p", organization: org)

            // Two projects legitimately own "default" while the whole fleet is
            // current. The create-time guard cannot see an agent that joins
            // afterwards, so registration runs the mirror check (issue #765).
            try await builder.createNetwork(
                name: "default", project: project, subnet: "10.50.0.0/24", gateway: "10.50.0.1")
            try await builder.createNetwork(
                name: "default", project: neighbour, subnet: "10.51.0.0/24", gateway: "10.51.0.1")

            func register(protocolVersion: Int, named name: String) async throws -> UUID {
                let message = AgentRegisterMessage(
                    agentId: name,
                    hostname: "rollback-host",
                    version: "1.0.0",
                    capabilities: ["qemu"],
                    resources: AgentResources(
                        totalCPU: 8, availableCPU: 8,
                        totalMemory: 1 << 33, availableMemory: 1 << 33,
                        totalDisk: 1 << 39, availableDisk: 1 << 39
                    ),
                    protocolVersion: protocolVersion
                )
                return try await app.agentService.registerAgent(
                    message, agentName: name, organizationScope: .organization(org.id!))
            }

            await #expect(throws: AgentServiceError.self) {
                _ = try await register(
                    protocolVersion: WireProtocol.projectNetworkIsolationMinimumVersion - 1,
                    named: "rolled-back-agent")
            }
            // The refusal is total: no half-registered row survives it.
            let rows = try await Agent.query(on: app.db).filter(\.$name == "rolled-back-agent").count()
            #expect(rows == 0)

            // A current agent joins the same fleet without complaint.
            _ = try await register(
                protocolVersion: WireProtocol.currentVersion, named: "current-agent")
            let current = try await Agent.query(on: app.db).filter(\.$name == "current-agent").count()
            #expect(current == 1)
        }
    }

    @Test("POST /api/networks accepts a name another project already uses")
    func createAllowsDuplicateNameAcrossProjects() async throws {
        try await withNetworkTestApp { app, user, project, token in
            // The acceptance criterion of issue #765: two projects can each own
            // a network called "default", on the same subnet, without sharing
            // an L2 domain or an IP pool.
            let builder = TestDataBuilder(db: app.db)
            let otherProject = try await builder.createProject(
                name: "Neighbour Project", description: "p",
                organization: try await Organization.find(user.currentOrganizationId, on: app.db))
            let theirs = try await builder.createNetwork(
                name: "default", project: otherProject, subnet: "10.41.0.0/24", gateway: "10.41.0.1")

            try await app.test(.POST, "/api/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateNetworkRequest(
                        name: "default", subnet: "10.41.0.0/24", gateway: nil,
                        projectId: project.id!))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let mine = try res.content.decode(NetworkResponse.self)
                #expect(mine.name == theirs.name)
                #expect(mine.subnet == theirs.subnet)
                #expect(mine.id != theirs.id)
                #expect(mine.projectId == project.id)
            }
        }
    }

    @Test("POST /api/networks denied without create_network permission (403)")
    func createDeniedWithoutPermission() async throws {
        try await withNetworkTestApp { app, _, project, _ in
            // A project viewer can see the project but holds no
            // network:create.
            let viewer = try await TestDataBuilder(db: app.db).createUser(
                username: "net-viewer", email: "net-viewer@example.com")
            try await RoleBindingService.grant(
                principalType: .user, principalID: viewer.id!, role: .viewer,
                nodeType: .project, nodeID: project.id!, createdBy: nil, on: app.db)
            let viewerToken = try await viewer.generateAPIKey(on: app.db)

            try await app.test(.POST, "/api/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: viewerToken)
                try req.content.encode(
                    CreateNetworkRequest(
                        name: "denied-net", subnet: "10.50.0.0/24", gateway: nil, projectId: project.id!))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    // MARK: - Update

    @Test("PUT /api/networks allows a gateway change on an unused network (200)")
    func updateGatewayOnUnusedNetwork() async throws {
        try await withNetworkTestApp { app, user, project, token in
            let network = LogicalNetwork(
                name: "editable-net", subnet: "10.60.0.0/24", gateway: "10.60.0.1",
                projectID: project.id!, createdByID: user.id!)
            try await network.save(on: app.db)

            try await app.test(.PUT, "/api/networks/\(network.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(UpdateNetworkRequest(name: nil, subnet: nil, gateway: "10.60.0.254"))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let updated = try res.content.decode(NetworkResponse.self)
                #expect(updated.gateway == "10.60.0.254")
            }
        }
    }

    @Test("PUT /api/networks toggling external access bumps the realization generation")
    func updateExternalAccessBumpsGeneration() async throws {
        try await withNetworkTestApp { app, user, project, token in
            let network = LogicalNetwork(
                name: "l3-net", subnet: "10.61.0.0/24", gateway: "10.61.0.1",
                projectID: project.id!, createdByID: user.id!)
            try await network.save(on: app.db)
            let startGeneration = network.generation

            // Toggling external access is L3-affecting → generation bumps.
            try await app.test(.PUT, "/api/networks/\(network.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(UpdateNetworkRequest(externalAccess: false))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let updated = try res.content.decode(NetworkResponse.self)
                #expect(updated.externalAccess == false)
            }
            let afterToggle = try await LogicalNetwork.find(network.id, on: app.db)
            #expect(afterToggle?.generation == startGeneration + 1)

            // A DHCP-only edit does not bump the generation (no L3 change).
            try await app.test(.PUT, "/api/networks/\(network.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(UpdateNetworkRequest(dhcpEnabled: false))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }
            let afterDHCP = try await LogicalNetwork.find(network.id, on: app.db)
            #expect(afterDHCP?.generation == startGeneration + 1)
        }
    }

    @Test("The metadata service defaults on and toggles without bumping the generation")
    func metadataEnabledDefaultsOnAndDoesNotBumpGeneration() async throws {
        try await withNetworkTestApp { app, user, project, token in
            // Created through the API, not the model, so this covers the
            // controller's default rather than the model's.
            var created: NetworkResponse?
            try await app.test(.POST, "/api/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateNetworkRequest(
                        name: "md-net", subnet: "10.62.0.0/24", projectId: project.id!))
            } afterResponse: { res in
                #expect(res.status == .ok)
                created = try res.content.decode(NetworkResponse.self)
                // An opt-out: the metadata service replaces the seed ISO, so a
                // network that never mentions it still publishes it.
                #expect(created?.metadataEnabled == true)
            }
            let networkID = try #require(created?.id)
            let startGeneration = try #require(
                await LogicalNetwork.find(networkID, on: app.db)?.generation)

            try await app.test(.PUT, "/api/networks/\(networkID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(UpdateNetworkRequest(metadataEnabled: false))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let disabled = try res.content.decode(NetworkResponse.self)
                #expect(disabled.metadataEnabled == false)
            }

            let updated = try await LogicalNetwork.find(networkID, on: app.db)
            #expect(updated?.metadataEnabled == false)
            // Deliberately no bump: the metadata port converges level-triggered
            // on every network reconcile, like the DHCP rows, so bumping would
            // only make agents skip legitimately concurrent syncs as stale.
            #expect(updated?.generation == startGeneration)

            // And back on, since turning it off is the half that has to delete
            // a live port.
            try await app.test(.PUT, "/api/networks/\(networkID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(UpdateNetworkRequest(metadataEnabled: true))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }
            let reEnabled = try await LogicalNetwork.find(networkID, on: app.db)
            #expect(reEnabled?.metadataEnabled == true)
        }
    }

    @Test("subnetsOverlap detects containment, equality, and disjoint ranges")
    func subnetOverlapLogic() {
        #expect(NetworkController.subnetsOverlap("10.0.0.0/16", "10.0.1.0/24"))
        #expect(NetworkController.subnetsOverlap("10.0.1.0/24", "10.0.0.0/16"))
        #expect(NetworkController.subnetsOverlap("10.0.0.0/24", "10.0.0.0/24"))
        #expect(!NetworkController.subnetsOverlap("10.0.0.0/24", "10.0.1.0/24"))
        #expect(!NetworkController.subnetsOverlap("192.168.1.0/24", "10.0.0.0/8"))
    }

    @Test("POST /api/networks rejects a subnet overlapping a sibling in the same project (409)")
    func createRejectsOverlappingSubnet() async throws {
        try await withNetworkTestApp { app, user, project, token in
            let existing = LogicalNetwork(
                name: "net-a", subnet: "10.50.0.0/16", gateway: "10.50.0.1",
                projectID: project.id!, createdByID: user.id!)
            try await existing.save(on: app.db)

            try await app.test(.POST, "/api/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateNetworkRequest(name: "net-b", subnet: "10.50.1.0/24", projectId: project.id))
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
        }
    }

    @Test("PUT /api/networks rejects a gateway change while the network is in use (409)")
    func updateRejectsGatewayChangeWhileInUse() async throws {
        try await withNetworkTestApp { app, user, project, token in
            let network = LogicalNetwork(
                name: "gw-net", subnet: "10.71.0.0/24", gateway: "10.71.0.1",
                projectID: project.id!, createdByID: user.id!)
            try await network.save(on: app.db)

            let vm = try await TestDataBuilder(db: app.db).createVM(name: "gw-vm", project: project)
            let nic = VMNetworkInterface(
                vmID: vm.id!, logicalNetworkID: network.id!, macAddress: VMNetworkInterface.generateMACAddress())
            try await nic.save(on: app.db)

            try await app.test(.PUT, "/api/networks/\(network.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(UpdateNetworkRequest(gateway: "10.71.0.254"))
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
        }
    }

    @Test("PUT /api/networks renames a network that is in use")
    func updateRenamesWhileInUse() async throws {
        try await withNetworkTestApp { app, user, project, token in
            let network = LogicalNetwork(
                name: "used-net", subnet: "10.70.0.0/24", gateway: "10.70.0.1",
                projectID: project.id!, createdByID: user.id!)
            try await network.save(on: app.db)

            let vm = try await TestDataBuilder(db: app.db).createVM(name: "nic-vm", project: project)
            let nic = VMNetworkInterface(
                vmID: vm.id!, logicalNetworkID: network.id!, macAddress: VMNetworkInterface.generateMACAddress())
            try await nic.save(on: app.db)

            // Safe since issue #765: the NIC references the row by id, so the
            // name is a label nothing resolves through.
            try await app.test(.PUT, "/api/networks/\(network.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(UpdateNetworkRequest(name: "renamed-net", subnet: nil, gateway: nil))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let renamed = try res.content.decode(NetworkResponse.self)
                #expect(renamed.name == "renamed-net")
            }

            let reloaded = try await VMNetworkInterface.find(nic.id, on: app.db)
            #expect(reloaded?.logicalNetworkID == network.id)
        }
    }

    // MARK: - Delete

    @Test("DELETE /api/networks removes an unused project network (204)")
    func deleteUnusedNetwork() async throws {
        try await withNetworkTestApp { app, user, project, token in
            let network = LogicalNetwork(
                name: "throwaway-net", subnet: "10.80.0.0/24", gateway: "10.80.0.1",
                projectID: project.id!, createdByID: user.id!)
            try await network.save(on: app.db)

            try await app.test(.DELETE, "/api/networks/\(network.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            let gone = try await LogicalNetwork.find(network.id, on: app.db)
            #expect(gone == nil)
        }
    }

    @Test("DELETE /api/networks rejects a network in use (409)")
    func deleteRejectsNetworkInUse() async throws {
        try await withNetworkTestApp { app, user, project, token in
            let network = LogicalNetwork(
                name: "busy-net", subnet: "10.90.0.0/24", gateway: "10.90.0.1",
                projectID: project.id!, createdByID: user.id!)
            try await network.save(on: app.db)

            let vm = try await TestDataBuilder(db: app.db).createVM(name: "busy-vm", project: project)
            let nic = VMNetworkInterface(
                vmID: vm.id!, logicalNetworkID: network.id!, macAddress: VMNetworkInterface.generateMACAddress())
            try await nic.save(on: app.db)

            try await app.test(.DELETE, "/api/networks/\(network.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
        }
    }

    @Test("DELETE /api/networks rejects a network carrying only sandbox interfaces (409)")
    func deleteRejectsNetworkWithSandboxInterface() async throws {
        try await withNetworkTestApp { app, _, project, token in
            let builder = TestDataBuilder(db: app.db)
            let network = try await builder.createNetwork(
                name: "sandbox-net", project: project, subnet: "10.91.0.0/24", gateway: "10.91.0.1")
            let sandbox = try await builder.createSandbox(name: "sb", project: project)
            let nic = SandboxNetworkInterface(
                sandboxID: try sandbox.requireID(), logicalNetworkID: try network.requireID(),
                macAddress: VMNetworkInterface.generateMACAddress())
            try await nic.save(on: app.db)

            // A sandbox NIC holds an address from the same pool, so the network
            // is in use — the guard used to count VM interfaces only.
            try await app.test(.DELETE, "/api/networks/\(network.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            let stillThere = try await LogicalNetwork.find(network.id, on: app.db)
            #expect(stillThere != nil)
        }
    }
}
