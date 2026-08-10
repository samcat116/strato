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

    @Test("POST /api/networks rejects an IPv6 subnet overlapping the reserved service space (400)")
    func createRejectsSubnet6OverlappingServiceSpace() async throws {
        try await withNetworkTestApp { app, _, project, token in
            // The whole documented /32, not just the /64 holding fd00:ec2::254:
            // it also covers the per-network resolvers at fd00:ec2:1::<index>.
            for subnet6 in ["fd00:ec2::/64", "fd00:ec2:1::/64", "fd00:ec2:ffff::/64", "FD00:0EC2:0:0::/64"] {
                try await app.test(.POST, "/api/networks") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    try req.content.encode(
                        CreateNetworkRequest(
                            name: "metadata-clash-net", subnet: "10.31.0.0/24", gateway: nil,
                            subnet6: subnet6, projectId: project.id!))
                } afterResponse: { res in
                    #expect(res.status == .badRequest, "subnet6 '\(subnet6)' should be rejected")
                    // The JSON body escapes the CIDR's slashes, so match the prose.
                    #expect(res.body.string.contains("reserved for Strato's own link-local services"))
                }
            }

            // The neighbouring prefixes are ordinary tenant space.
            try await app.test(.POST, "/api/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateNetworkRequest(
                        name: "metadata-neighbour-net", subnet: "10.32.0.0/24", gateway: nil,
                        subnet6: "fd00:ec3::/64", projectId: project.id!))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }
        }
    }

    @Test("PUT /api/networks rejects an IPv6 subnet overlapping the reserved service space (400)")
    func updateRejectsSubnet6OverlappingServiceSpace() async throws {
        try await withNetworkTestApp { app, user, project, token in
            let network = LogicalNetwork(
                name: "metadata-update-net", subnet: "10.33.0.0/24", gateway: "10.33.0.1",
                projectID: project.id!, createdByID: user.id!)
            try await network.save(on: app.db)

            try await app.test(.PUT, "/api/networks/\(network.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(UpdateNetworkRequest(subnet6: "fd00:ec2::/64"))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("reserved for Strato's own link-local services"))
            }

            let reloaded = try await LogicalNetwork.find(network.id!, on: app.db)
            #expect(reloaded?.subnet6 == nil)
        }
    }

    @Test("STRATO_DEFAULT_NETWORK_SUBNET6 rejects the reserved service space")
    func defaultNetworkSubnet6RejectsServiceSpace() throws {
        let error = #expect(throws: Abort.self) {
            try AddIPv6ToLogicalNetwork.resolveDefaultSubnet6(configured: "fd00:ec2::/64")
        }
        #expect(error?.status == .internalServerError)
        #expect(error?.reason.contains("STRATO_DEFAULT_NETWORK_SUBNET6") == true)
        #expect(
            try AddIPv6ToLogicalNetwork.resolveDefaultSubnet6(configured: "fd00:ec3::/64").description
                == "fd00:ec3::/64")
    }

    @Test("Startup audit finds networks that predate the service-space reservation")
    func startupAuditFindsExistingServiceSpaceCollision() async throws {
        try await withNetworkTestApp { app, user, project, _ in
            let colliding = LogicalNetwork(
                name: "legacy-service-space-net", subnet: "10.34.0.0/24", gateway: "10.34.0.1",
                subnet6: "fd00:ec2:abcd::/64", gateway6: "fd00:ec2:abcd::1",
                projectID: project.id!, createdByID: user.id!)
            try await colliding.save(on: app.db)

            let found = try await NetworkServiceSpaceAudit.collidingNetworks(on: app.db)
            #expect(found.map(\.id).contains(colliding.id))
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

    @Test("An IPv6 enable no-op uses the pair reloaded under the row lock")
    func ipv6NoOpUsesLockedPair() throws {
        let request = UpdateNetworkRequest(ipv6Enabled: true)

        // The request began while the first pair was current. Another update
        // committed the second pair before this request acquired the row lock.
        // Re-deriving from the locked values must not restore the stale pair.
        let result = try NetworkController.requestedIPv6Addressing(
            request: request, currentSubnet6: "fd00:42::/64",
            currentGateway6: "fd00:42::fe")
        let requested = try #require(result)
        #expect(requested.subnet6 == "fd00:42::/64")
        #expect(requested.gateway6 == "fd00:42::fe")
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

    @Test("A non-current agent cannot register into a fleet that already has colliding names")
    func registrationRefusedWhenNamesAlreadyCollide() async throws {
        try await withNetworkTestApp { app, user, project, _ in
            let builder = TestDataBuilder(db: app.db)
            let org = try #require(try await Organization.find(user.currentOrganizationId, on: app.db))
            let neighbour = try await builder.createProject(
                name: "Late Rollback Neighbour", description: "p", organization: org)

            // Two projects legitimately own "default" because every supported
            // agent understands project-scoped network identity. Registration
            // must reject older agents before they can endanger that state.
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
                    protocolVersion: WireProtocol.currentVersion - 1,
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

    @Test("Concurrent L3 updates merge and receive consecutive generations")
    func concurrentL3UpdatesReceiveConsecutiveGenerations() async throws {
        try await withNetworkTestApp { app, user, project, token in
            let network = LogicalNetwork(
                name: "concurrent-l3-net", subnet: "10.62.0.0/24", gateway: "10.62.0.1",
                projectID: project.id!, createdByID: user.id!)
            try await network.save(on: app.db)
            let networkID = try network.requireID()
            let startGeneration = network.generation

            async let gatewayUpdate: Void = {
                try await app.test(.PUT, "/api/networks/\(networkID)") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    try req.content.encode(UpdateNetworkRequest(gateway: "10.62.0.254"))
                } afterResponse: { res in
                    #expect(res.status == .ok)
                }
            }()
            async let externalAccessUpdate: Void = {
                try await app.test(.PUT, "/api/networks/\(networkID)") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    try req.content.encode(UpdateNetworkRequest(externalAccess: false))
                } afterResponse: { res in
                    #expect(res.status == .ok)
                }
            }()
            _ = try await (gatewayUpdate, externalAccessUpdate)

            let persisted = try #require(try await LogicalNetwork.find(networkID, on: app.db))
            #expect(persisted.gateway == "10.62.0.254")
            #expect(persisted.externalAccess == false)
            #expect(persisted.generation == startGeneration + 2)
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

    @Test("The resolver defaults on and toggles without bumping the generation")
    func resolverEnabledDefaultsOnAndDoesNotBumpGeneration() async throws {
        try await withNetworkTestApp { app, user, project, token in
            var created: NetworkResponse?
            try await app.test(.POST, "/api/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateNetworkRequest(
                        name: "res-net", subnet: "10.66.0.0/24", projectId: project.id!))
            } afterResponse: { res in
                #expect(res.status == .ok)
                created = try res.content.decode(NetworkResponse.self)
                // An opt-*out*, like the metadata service. It forwards through
                // the hypervisor's own egress (ADR 0008), so a network that had
                // working resolvers keeps them and one that could not reach a
                // public resolver at all starts being able to.
                #expect(created?.resolverEnabled == true)
                // Allocated on the create that turned it on, not lazily: an
                // address the control plane has not committed to is one no agent
                // may realize, so the sync would carry nil until something else
                // wrote the row.
                #expect(created?.resolverAddresses?.count == 2)
            }
            let networkID = try #require(created?.id)
            let startGeneration = try #require(
                await LogicalNetwork.find(networkID, on: app.db)?.generation)
            let allocated = try #require(
                await LogicalNetwork.find(networkID, on: app.db)?.resolverIndex)

            try await app.test(.PUT, "/api/networks/\(networkID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(UpdateNetworkRequest(resolverEnabled: false))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let disabled = try res.content.decode(NetworkResponse.self)
                #expect(disabled.resolverEnabled == false)
                // Still reported: the response says what the network *holds*,
                // and the index is kept across a disable so re-enabling cannot
                // move a live address. What goes off the wire to agents is
                // `resolverAddressesIfEnabled`, which is a different question.
                #expect(disabled.resolverAddresses?.count == 2)
            }

            let updated = try await LogicalNetwork.find(networkID, on: app.db)
            #expect(updated?.resolverEnabled == false)
            // No bump, for the metadata port's reason: the localport, the DHCP
            // row and the resolver process all converge level-triggered on every
            // network reconcile.
            #expect(updated?.generation == startGeneration)

            try await app.test(.PUT, "/api/networks/\(networkID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(UpdateNetworkRequest(resolverEnabled: true))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }
            let reEnabled = try await LogicalNetwork.find(networkID, on: app.db)
            #expect(reEnabled?.resolverEnabled == true)
            // **The same index, not a fresh one.** Moving it would change what
            // guests were told over DHCP and strand every lease until it
            // renewed, so re-enabling reuses what the network already holds.
            #expect(reEnabled?.resolverIndex == allocated)
        }
    }

    @Test("Every network gets a resolver address of its own")
    func resolverAddressesAreDistinctAcrossNetworks() async throws {
        // The property the host-namespace design rests on (ADR 0008): the
        // addresses are terminated in one shared namespace on any host running
        // NICs on both networks, so two networks sharing a pair is not a
        // cosmetic clash but two resolvers fighting over one bind address.
        try await withNetworkTestApp { app, user, project, token in
            var addresses: [[String]] = []
            var indexes: [Int] = []
            for (offset, name) in ["res-a", "res-b", "res-c"].enumerated() {
                try await app.test(.POST, "/api/networks") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    try req.content.encode(
                        CreateNetworkRequest(
                            name: name, subnet: "10.7\(offset).0.0/24", projectId: project.id!))
                } afterResponse: { res in
                    #expect(res.status == .ok)
                    let created = try res.content.decode(NetworkResponse.self)
                    addresses.append(try #require(created.resolverAddresses))
                    let row = try await LogicalNetwork.find(created.id, on: app.db)
                    indexes.append(try #require(row?.resolverIndex))
                }
            }
            #expect(Set(addresses.flatMap { $0 }).count == 6)
            #expect(Set(indexes).count == 3)
            // IPv4 first, then the v6 ULA — the order the agent reads them in.
            for (pair, index) in zip(addresses, indexes) {
                #expect(
                    pair == [
                        NetworkResolverEndpoint.address(forIndex: index),
                        NetworkResolverEndpoint.addressV6(forIndex: index),
                    ])
                #expect(pair[0].hasPrefix("169.254."))
                #expect(pair[1].hasPrefix("fd00:ec2:1::"))
            }
        }
    }

    @Test("A network that never had a resolver carries no address")
    func disabledAtCreateAllocatesNothing() async throws {
        // Allocation happens on the write that turns the flag on, so a network
        // created with it off consumes nothing from a fleet-wide space.
        try await withNetworkTestApp { app, user, project, token in
            try await app.test(.POST, "/api/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateNetworkRequest(
                        name: "res-none", subnet: "10.68.0.0/24", projectId: project.id!,
                        resolverEnabled: false))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let created = try res.content.decode(NetworkResponse.self)
                #expect(created.resolverEnabled == false)
                #expect(created.resolverAddresses == nil)
                let row = try await LogicalNetwork.find(created.id, on: app.db)
                #expect(row?.resolverIndex == nil)
            }
        }
    }

    @Test("An update that omits the resolver leaves it alone")
    func resolverIsUntouchedByUnrelatedEdits() async throws {
        // Every dialog resubmits the whole form, so an older client that does
        // not know the field must not be able to turn a network's resolver off
        // by omission.
        try await withNetworkTestApp { app, user, project, token in
            var created: NetworkResponse?
            try await app.test(.POST, "/api/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateNetworkRequest(
                        name: "res-keep", subnet: "10.67.0.0/24", projectId: project.id!,
                        resolverEnabled: true))
            } afterResponse: { res in
                #expect(res.status == .ok)
                created = try res.content.decode(NetworkResponse.self)
                #expect(created?.resolverEnabled == true)
            }
            let networkID = try #require(created?.id)

            try await app.test(.PUT, "/api/networks/\(networkID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(UpdateNetworkRequest(dnsServers: ["9.9.9.9"]))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }
            let after = try await LogicalNetwork.find(networkID, on: app.db)
            #expect(after?.resolverEnabled == true)
            // The list itself is unchanged in shape; only what consumes it moved.
            #expect(after?.dnsServers == ["9.9.9.9"])
        }
    }

    @Test("The zone-resolution warning names whichever thing is withholding the resolver")
    func zoneResolutionWarningBranches() {
        let network = LogicalNetwork(
            name: "warn", subnet: "10.90.0.0/24", projectID: UUID(), resolverIndex: 400)

        // Nothing attached: nothing to fail to deliver, whatever the resolver
        // is doing.
        network.resolverEnabled = false
        #expect(
            ResolverCapability.zoneResolutionWarning(
                network: network, attachedZoneCount: 0, incapableAgentNames: ["old-host"]) == nil)

        let off = try! #require(
            ResolverCapability.zoneResolutionWarning(
                network: network, attachedZoneCount: 1, incapableAgentNames: []))
        #expect(off.contains("resolver is off"))
        #expect(off.contains("its attached DNS zone"))

        network.resolverEnabled = true
        #expect(
            ResolverCapability.zoneResolutionWarning(
                network: network, attachedZoneCount: 2, incapableAgentNames: []) == nil)

        let incapable = try! #require(
            ResolverCapability.zoneResolutionWarning(
                network: network, attachedZoneCount: 2, incapableAgentNames: ["hv-1", "hv-2"]))
        #expect(incapable.contains("hv-1, hv-2"))
        // Plural, because the count is the operator's own attachment count.
        #expect(incapable.contains("its 2 attached DNS zones"))

        // The pre-STR-40 state the backfill exists to remove.
        network.resolverIndex = nil
        let unallocated = try! #require(
            ResolverCapability.zoneResolutionWarning(
                network: network, attachedZoneCount: 1, incapableAgentNames: []))
        #expect(unallocated.contains("no address allocated"))
    }

    @Test("The capability index answers per site, and from site-less agents when unpinned")
    func capabilityIndexScopesBySite() {
        let siteA = UUID()
        let siteB = UUID()
        func incapableAgent(named name: String, site: UUID?) -> Agent {
            let agent = Agent(
                name: name, hostname: name, version: "1.0", capabilities: [],
                resources: AgentResources(
                    totalCPU: 1, availableCPU: 1, totalMemory: 1, availableMemory: 1,
                    totalDisk: 1, availableDisk: 1))
            agent.$site.id = site
            return agent
        }
        let index = ResolverCapability.Index(incapable: [
            incapableAgent(named: "old-b", site: siteB),
            incapableAgent(named: "old-a2", site: siteA),
            incapableAgent(named: "old-a1", site: siteA),
            incapableAgent(named: "unsited", site: nil),
        ])

        #expect(index.incapableAgentNames(forSite: siteA) == ["old-a1", "old-a2"])
        #expect(index.incapableAgentNames(forSite: siteB) == ["old-b"])
        // A site with nothing holding it back is capable, not unknown.
        #expect(index.incapableAgentNames(forSite: UUID()).isEmpty)
        // The sync path asks a site-less receiving agent's own flag, so agents
        // assigned to other sites cannot be named as the cause here.
        #expect(index.incapableAgentNames(forSite: nil) == ["unsited"])
    }

    @Test("The backfill gives an address to a resolver-enabled network that has none")
    func backfillAllocatesMissingResolverIndexes() async throws {
        try await withNetworkTestApp { app, _, project, _ in
            let builder = TestDataBuilder(db: app.db)
            // The shape `AddResolverEnabledToLogicalNetwork` left behind: the
            // flag on by default, no index, and nothing that would ever
            // allocate one.
            let stranded = try await builder.createNetwork(name: "pre-str40", project: project)
            #expect(stranded.resolverEnabled)
            #expect(stranded.resolverIndex == nil)

            let held = try await builder.createNetwork(name: "already-has-one", project: project)
            held.resolverIndex = 500
            try await held.save(on: app.db)

            let optedOut = try await builder.createNetwork(name: "no-resolver", project: project)
            optedOut.resolverEnabled = false
            try await optedOut.save(on: app.db)

            try await BackfillResolverIndexes().prepare(on: app.db)

            let filled = try await LogicalNetwork.find(stranded.id, on: app.db)
            let allocated = try #require(filled?.resolverIndex)
            #expect(NetworkResolverEndpoint.isValidIndex(allocated))
            #expect(allocated != 500)
            // A live address is never moved — that would strand every lease
            // already carrying it.
            #expect(try await LogicalNetwork.find(held.id, on: app.db)?.resolverIndex == 500)
            // The flag is off, so there is nothing to point guests at.
            #expect(try await LogicalNetwork.find(optedOut.id, on: app.db)?.resolverIndex == nil)

            // Idempotent: a second run allocates nothing further.
            try await BackfillResolverIndexes().prepare(on: app.db)
            #expect(try await LogicalNetwork.find(stranded.id, on: app.db)?.resolverIndex == allocated)
        }
    }

    @Test("The backfill serializes with a concurrent live resolver allocation")
    func backfillSerializesWithLiveAllocation() async throws {
        try await withNetworkTestApp { app, _, project, _ in
            let builder = TestDataBuilder(db: app.db)
            let stranded = try await builder.createNetwork(name: "backfill-race", project: project)

            // Keep this row out of the backfill's pending set until its live
            // allocation commits. Its transaction chooses an index, pauses,
            // and gives the migration a chance to collide if the migration is
            // not participating in the allocator's advisory lock.
            let live = try await builder.createNetwork(name: "live-race", project: project)
            live.resolverEnabled = false
            try await live.save(on: app.db)
            let liveID = try live.requireID()
            let (selection, selected) = AsyncStream.makeStream(of: Void.self)

            async let liveAllocation: Void = app.db.transaction { db in
                let allocating = try #require(try await LogicalNetwork.find(liveID, on: db))
                allocating.resolverEnabled = true
                _ = try await ResolverAddressAllocator.ensureIndex(for: allocating, on: db)
                selected.yield()
                try await Task.sleep(for: .milliseconds(250))
                try await allocating.save(on: db)
            }

            for await _ in selection {
                break
            }
            async let backfill: Void = BackfillResolverIndexes().prepare(on: app.db)
            _ = try await (liveAllocation, backfill)
            selected.finish()

            let filled = try #require(try await LogicalNetwork.find(stranded.id, on: app.db))
            let allocatedLive = try #require(try await LogicalNetwork.find(liveID, on: app.db))
            #expect(filled.resolverIndex != nil)
            #expect(allocatedLive.resolverIndex != nil)
            #expect(filled.resolverIndex != allocatedLive.resolverIndex)
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

    // MARK: - Search domain
    //
    // `domainName` is not carried as text anywhere it lands: the agent
    // interpolates it into the guest's netplan `network-config` and into OVN's
    // DHCP option map (issue #876). Held to the DNS zone grammar on write, so a
    // value that would restructure either document never reaches the row.

    @Test("POST /api/networks normalizes the search domain to the zone-name spelling")
    func createNormalizesDomainName() async throws {
        try await withNetworkTestApp { app, _, project, token in
            try await app.test(.POST, "/api/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateNetworkRequest(
                        name: "domain-net", subnet: "10.92.0.0/24", projectId: project.id!,
                        domainName: "  Corp.Example.COM.  "))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let created = try res.content.decode(NetworkResponse.self)
                #expect(created.domainName == "corp.example.com")
            }
        }
    }

    @Test("POST /api/networks rejects a search domain carrying netplan structure (400)")
    func createRejectsStructuredDomainName() async throws {
        try await withNetworkTestApp { app, _, project, token in
            // The interior newlines used to survive the trim and land at
            // netplan's key indentation, giving every static NIC on the network
            // an attacker-chosen default route.
            let smuggled = """
                corp.example.com
                    routes:
                      - to: 0.0.0.0/0
                        via: 10.0.0.99
                """

            try await app.test(.POST, "/api/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateNetworkRequest(
                        name: "smuggle-net", subnet: "10.93.0.0/24", projectId: project.id!,
                        domainName: smuggled))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            let stored = try await LogicalNetwork.query(on: app.db).filter(\.$name == "smuggle-net").first()
            #expect(stored == nil)
        }
    }

    @Test("POST /api/networks rejects search domains that break the documents they land in (400)")
    func createRejectsMalformedDomainNames() async throws {
        try await withNetworkTestApp { app, _, project, token in
            // `]`/`,`/`#` make netplan's flow sequence unparseable — cloud-init
            // then discards the whole network-config and the VM boots with no
            // addressing; `"` ends OVN's quoted option early, failing DHCP.
            let rejected = ["corp.example.com]", "a,b.example.com", "corp.example.com # x", "corp\".com"]

            for (index, domain) in rejected.enumerated() {
                try await app.test(.POST, "/api/networks") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    try req.content.encode(
                        CreateNetworkRequest(
                            name: "bad-domain-\(index)", subnet: "10.94.\(index).0/24", projectId: project.id!,
                            domainName: domain))
                } afterResponse: { res in
                    #expect(res.status == .badRequest, "'\(domain)' should be rejected")
                }
            }
        }
    }

    @Test("POST /api/networks accepts a single-label search domain")
    func createAcceptsSingleLabelDomainName() async throws {
        try await withNetworkTestApp { app, _, project, token in
            // Unlike a zone name, which is a name to serve: `internal` is a
            // legitimate thing to append to an unqualified lookup, and both
            // delivery paths take it. The structural safety comes from the
            // label grammar, not from the label count.
            try await app.test(.POST, "/api/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateNetworkRequest(
                        name: "single-label-net", subnet: "10.97.0.0/24", projectId: project.id!,
                        domainName: "internal"))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let created = try res.content.decode(NetworkResponse.self)
                #expect(created.domainName == "internal")
            }
        }
    }

    @Test("POST /api/networks treats a blank search domain as absent")
    func createTreatsBlankDomainNameAsAbsent() async throws {
        try await withNetworkTestApp { app, _, project, token in
            try await app.test(.POST, "/api/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateNetworkRequest(
                        name: "blank-domain-net", subnet: "10.95.0.0/24", projectId: project.id!,
                        domainName: "   "))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let created = try res.content.decode(NetworkResponse.self)
                #expect(created.domainName == nil)
            }
        }
    }

    @Test("PUT /api/networks validates the search domain, leaving the stored one intact on refusal")
    func updateValidatesDomainName() async throws {
        try await withNetworkTestApp { app, user, project, token in
            let network = LogicalNetwork(
                name: "domain-edit-net", subnet: "10.96.0.0/24", gateway: "10.96.0.1",
                projectID: project.id!, createdByID: user.id!, domainName: "corp.example.com")
            try await network.save(on: app.db)

            try await app.test(.PUT, "/api/networks/\(network.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(UpdateNetworkRequest(domainName: "corp.example.com\n    routes: []"))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            let unchanged = try await LogicalNetwork.find(network.id, on: app.db)
            #expect(unchanged?.domainName == "corp.example.com")

            // An empty string still clears it — the one non-domain value the
            // field accepts.
            try await app.test(.PUT, "/api/networks/\(network.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(UpdateNetworkRequest(domainName: ""))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let cleared = try res.content.decode(NetworkResponse.self)
                #expect(cleared.domainName == nil)
            }
        }
    }

    @Test("A primary-zone update preserves a domain claimed before the row lock")
    func primaryZoneUpdateUsesLockedDomain() {
        // The zone request originally saw old.example and would have prepared
        // new.example. While it waited for the lock, an explicit domain update
        // claimed operator.example. The locked value no longer follows the old
        // zone and therefore survives the zone change.
        let preserved = NetworkController.searchDomainAfterPrimaryZoneChange(
            currentDomain: "operator.example", previousZoneName: "old.example",
            nextZoneName: "new.example", domainNameExplicit: false)
        #expect(preserved == "operator.example")

        let followed = NetworkController.searchDomainAfterPrimaryZoneChange(
            currentDomain: "old.example", previousZoneName: "old.example",
            nextZoneName: "new.example", domainNameExplicit: false)
        #expect(followed == "new.example")
    }

    @Test("The index scan is sequential and skips what it must not hand out")
    func resolverIndexScan() {
        // Pure, so it can assert the range's edges without 65k round trips.
        #expect(ResolverAddressAllocator.firstFree(after: []) == NetworkResolverEndpoint.firstIndex)
        #expect(
            ResolverAddressAllocator.firstFree(after: [256, 257, 259]) == 258,
            "lowest free, not next-after-highest — a disabled network's index is reusable")

        // 169.254.169.254 is the metadata service's and falls inside the range;
        // handing it out would point a network's guests at a namespace serving
        // HTTP. 169.254.169.253 was the pre-STR-40 resolver constant.
        let metadata = (169 << 8) | 254
        let legacy = (169 << 8) | 253
        // The two are adjacent, so a scan that reaches them skips both and lands
        // past the metadata address.
        let used = Set(NetworkResolverEndpoint.firstIndex..<legacy)
        #expect(ResolverAddressAllocator.firstFree(after: used) == metadata + 1)

        // Exhaustion is a real outcome, not an infinite scan.
        let all = Set(NetworkResolverEndpoint.firstIndex...NetworkResolverEndpoint.lastIndex)
        #expect(ResolverAddressAllocator.firstFree(after: all) == nil)
    }
}
