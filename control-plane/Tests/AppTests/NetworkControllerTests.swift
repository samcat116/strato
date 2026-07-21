import Testing
import Vapor
import Fluent
import VaporTesting
@testable import App

/// Tests for the project-scoped network management API (`/api/networks`):
/// listing (globals always visible), creation with CIDR/gateway validation and
/// duplicate-name handling, update guards while a network is in use, and the
/// delete-in-use / default-network protections.
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

    @Test("GET /api/networks always includes the global default network")
    func listIncludesGlobalDefault() async throws {
        try await withNetworkTestApp { app, _, project, token in
            app.spicedbMockAllows = true

            try await app.test(.GET, "/api/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let networks = try res.content.decode([NetworkResponse].self)
                let names = networks.map(\.name)
                #expect(names.contains(LogicalNetwork.defaultNetworkName))
                let defaultNet = networks.first { $0.name == LogicalNetwork.defaultNetworkName }
                #expect(defaultNet?.isDefault == true)
                #expect(defaultNet?.projectId == nil)
            }
            _ = project
        }
    }

    @Test("GET /api/networks?project_id excludes other projects but keeps globals")
    func listScopesToProjectPlusGlobals() async throws {
        try await withNetworkTestApp { app, user, project, token in
            app.spicedbMockAllows = true

            // A network in a different project that must not appear.
            let builder = TestDataBuilder(db: app.db)
            let otherProject = try await builder.createProject(
                name: "Other Project",
                description: "not the caller's project",
                organization: try await Organization.find(user.currentOrganizationId, on: app.db)
            )
            let hiddenNetwork = LogicalNetwork(
                name: "hidden-net", subnet: "10.9.0.0/24", gateway: "10.9.0.1",
                projectID: otherProject.id!, createdByID: user.id!
            )
            try await hiddenNetwork.save(on: app.db)

            try await app.test(.GET, "/api/networks?project_id=\(project.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let names = try res.content.decode([NetworkResponse].self).map(\.name)
                #expect(names.contains(LogicalNetwork.defaultNetworkName))
                #expect(!names.contains("hidden-net"))
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
            app.spicedbMockAllows = true

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
                #expect(network.isDefault == false)
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
            app.spicedbMockAllows = true

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
            app.spicedbMockAllows = true

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
            app.spicedbMockAllows = true

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
            app.spicedbMockAllows = true

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
            app.spicedbMockAllows = true

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
            app.spicedbMockAllows = true

            let network = LogicalNetwork(
                name: "grow6-net", subnet: "10.28.0.0/24", gateway: "10.28.0.1",
                projectID: project.id!, createdByID: user.id!)
            try await network.save(on: app.db)
            // In use by a NIC — additive IPv6 must still be allowed.
            let vm = try await TestDataBuilder(db: app.db).createVM(name: "grow6-vm", project: project)
            let nic = VMNetworkInterface(
                vmID: vm.id!, network: "grow6-net", macAddress: VMNetworkInterface.generateMACAddress())
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
            app.spicedbMockAllows = true

            let network = LogicalNetwork(
                name: "shrink6-net", subnet: "10.29.0.0/24", gateway: "10.29.0.1",
                subnet6: "fd00:29::/64", gateway6: "fd00:29::1",
                projectID: project.id!, createdByID: user.id!)
            try await network.save(on: app.db)
            let vm = try await TestDataBuilder(db: app.db).createVM(name: "shrink6-vm", project: project)
            let nic = VMNetworkInterface(
                vmID: vm.id!, network: "shrink6-net", macAddress: VMNetworkInterface.generateMACAddress())
            try await nic.save(on: app.db)
            let address6 = VMInterfaceAddress(
                interfaceID: nic.id!, network: "shrink6-net", family: .ipv6,
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
            app.spicedbMockAllows = true

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
            app.spicedbMockAllows = true

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

    @Test("POST /api/networks rejects a duplicate name (409)")
    func createRejectsDuplicateName() async throws {
        try await withNetworkTestApp { app, _, project, token in
            app.spicedbMockAllows = true

            // "default" already exists as a global network.
            try await app.test(.POST, "/api/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateNetworkRequest(
                        name: LogicalNetwork.defaultNetworkName, subnet: "10.40.0.0/24", gateway: nil,
                        projectId: project.id!))
            } afterResponse: { res in
                #expect(res.status == .conflict)
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
            app.spicedbMockAllows = true

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
            app.spicedbMockAllows = true

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
            app.spicedbMockAllows = true
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
            app.spicedbMockAllows = true

            let network = LogicalNetwork(
                name: "gw-net", subnet: "10.71.0.0/24", gateway: "10.71.0.1",
                projectID: project.id!, createdByID: user.id!)
            try await network.save(on: app.db)

            let vm = try await TestDataBuilder(db: app.db).createVM(name: "gw-vm", project: project)
            let nic = VMNetworkInterface(
                vmID: vm.id!, network: "gw-net", macAddress: VMNetworkInterface.generateMACAddress())
            try await nic.save(on: app.db)

            try await app.test(.PUT, "/api/networks/\(network.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(UpdateNetworkRequest(gateway: "10.71.0.254"))
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
        }
    }

    @Test("PUT /api/networks rejects a name change while the network is in use (409)")
    func updateRejectsRenameWhileInUse() async throws {
        try await withNetworkTestApp { app, user, project, token in
            app.spicedbMockAllows = true

            let network = LogicalNetwork(
                name: "used-net", subnet: "10.70.0.0/24", gateway: "10.70.0.1",
                projectID: project.id!, createdByID: user.id!)
            try await network.save(on: app.db)

            // Attach a NIC referencing the network by name.
            let vm = try await TestDataBuilder(db: app.db).createVM(name: "nic-vm", project: project)
            let nic = VMNetworkInterface(
                vmID: vm.id!, network: "used-net", macAddress: VMNetworkInterface.generateMACAddress())
            try await nic.save(on: app.db)

            try await app.test(.PUT, "/api/networks/\(network.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(UpdateNetworkRequest(name: "renamed-net", subnet: nil, gateway: nil))
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
        }
    }

    @Test("PUT /api/networks rejects a non-admin mutating the global default (403)")
    func updateDefaultDeniedForNonAdmin() async throws {
        try await withNetworkTestApp { app, _, _, token in
            app.spicedbMockAllows = true

            let defaultNet = try await LogicalNetwork.query(on: app.db)
                .filter(\.$name == LogicalNetwork.defaultNetworkName).first()!

            try await app.test(.PUT, "/api/networks/\(defaultNet.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(UpdateNetworkRequest(name: "not-default", subnet: nil, gateway: nil))
            } afterResponse: { res in
                // Global network mutation requires system admin.
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test("PUT /api/networks rejects a system admin renaming the default network (409)")
    func updateRejectsAdminRenamingDefault() async throws {
        try await withNetworkTestApp { app, _, _, _ in
            app.spicedbMockAllows = true

            let admin = try await TestDataBuilder(db: app.db).createUser(
                username: "netadmin", email: "netadmin@example.com",
                displayName: "Net Admin", isSystemAdmin: true)
            let adminToken = try await admin.generateAPIKey(on: app.db)

            let defaultNet = try await LogicalNetwork.query(on: app.db)
                .filter(\.$name == LogicalNetwork.defaultNetworkName).first()!

            try await app.test(.PUT, "/api/networks/\(defaultNet.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
                try req.content.encode(UpdateNetworkRequest(name: "not-default", subnet: nil, gateway: nil))
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
        }
    }

    // MARK: - Delete

    @Test("DELETE /api/networks removes an unused project network (204)")
    func deleteUnusedNetwork() async throws {
        try await withNetworkTestApp { app, user, project, token in
            app.spicedbMockAllows = true

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
            app.spicedbMockAllows = true

            let network = LogicalNetwork(
                name: "busy-net", subnet: "10.90.0.0/24", gateway: "10.90.0.1",
                projectID: project.id!, createdByID: user.id!)
            try await network.save(on: app.db)

            let vm = try await TestDataBuilder(db: app.db).createVM(name: "busy-vm", project: project)
            let nic = VMNetworkInterface(
                vmID: vm.id!, network: "busy-net", macAddress: VMNetworkInterface.generateMACAddress())
            try await nic.save(on: app.db)

            try await app.test(.DELETE, "/api/networks/\(network.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
        }
    }

    @Test("DELETE /api/networks rejects a non-admin deleting the global default (403)")
    func deleteDefaultDeniedForNonAdmin() async throws {
        try await withNetworkTestApp { app, _, _, token in
            app.spicedbMockAllows = true

            let defaultNet = try await LogicalNetwork.query(on: app.db)
                .filter(\.$name == LogicalNetwork.defaultNetworkName).first()!

            try await app.test(.DELETE, "/api/networks/\(defaultNet.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test("DELETE /api/networks rejects a system admin deleting the default network (409)")
    func deleteRejectsAdminDeletingDefault() async throws {
        try await withNetworkTestApp { app, _, _, _ in
            app.spicedbMockAllows = true

            let admin = try await TestDataBuilder(db: app.db).createUser(
                username: "deladmin", email: "deladmin@example.com",
                displayName: "Delete Admin", isSystemAdmin: true)
            let adminToken = try await admin.generateAPIKey(on: app.db)

            let defaultNet = try await LogicalNetwork.query(on: app.db)
                .filter(\.$name == LogicalNetwork.defaultNetworkName).first()!

            try await app.test(.DELETE, "/api/networks/\(defaultNet.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            let stillThere = try await LogicalNetwork.find(defaultNet.id, on: app.db)
            #expect(stillThere != nil)
        }
    }
}
