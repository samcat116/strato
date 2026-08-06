import Fluent
import StratoShared
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

/// Tests for the floating IP API (issue #344): pool CRUD with CIDR
/// validation, lowest-free allocation, and the attach/detach lifecycle with
/// its guards (egress network required, project match, one per NIC, detach
/// before release).
@Suite("Floating IP Controller Tests", .serialized)
final class FloatingIPControllerTests {

    private func withFloatingIPTestApp(
        _ test: (Application, User, Organization, Project, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "fipuser",
                email: "fip@example.com",
                displayName: "Floating IP User",
                isSystemAdmin: true
            )
            let org = try await builder.createOrganization(name: "FIP Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            user.currentOrganizationId = org.id
            try await user.save(on: app.db)

            let project = try await builder.createProject(
                name: "FIP Project",
                description: "Project for floating IP tests",
                organization: org
            )
            let token = try await user.generateAPIKey(on: app.db)

            try await test(app, user, org, project, token)

        } catch {
            try await app.shutdownForTesting()
            throw error
        }

        try await app.shutdownForTesting()
    }

    /// A pool over 203.0.113.0/29 with .1 as its gateway.
    private func createPool(
        app: Application, org: Organization, token: String, siteId: UUID? = nil
    ) async throws -> FloatingIPPoolResponse {
        var created: FloatingIPPoolResponse?
        try await app.test(.POST, "/api/floating-ip-pools") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
            try req.content.encode([
                "name": "edge", "cidr": "203.0.113.0/29", "gateway": "203.0.113.1",
                "organizationId": org.id!.uuidString,
            ])
        } afterResponse: { res in
            #expect(res.status == .ok)
            created = try res.content.decode(FloatingIPPoolResponse.self)
        }
        return created!
    }

    /// A project VM with one NIC on `network` carrying a fixed IPv4 address,
    /// placed on a fresh current-protocol agent (attach refuses unplaced VMs).
    private func createVMWithNIC(
        app: Application, org: Organization, project: Project, network: LogicalNetwork, fixedIP: String
    ) async throws -> (VM, VMNetworkInterface) {
        let builder = TestDataBuilder(db: app.db)
        let vm = try await builder.createVM(name: "fip-vm-\(UUID().uuidString.prefix(8))", project: project)
        let nic = VMNetworkInterface(
            vmID: vm.id!, logicalNetworkID: try network.requireID(), macAddress: VMNetworkInterface.generateMACAddress()
        )
        try await nic.save(on: app.db)
        try await VMInterfaceAddress(
            interfaceID: nic.id!, logicalNetworkID: try network.requireID(), family: .ipv4,
            address: fixedIP, prefixLength: 24, gateway: network.gateway
        ).save(on: app.db)
        try await placeVM(
            vm, app: app, org: org, protocolVersion: WireProtocol.currentVersion,
            named: "agent-\(UUID().uuidString.prefix(8))")
        return (vm, nic)
    }

    @Test("POST /api/floating-ip-pools validates the CIDR and gateway")
    func poolValidation() async throws {
        try await withFloatingIPTestApp { app, _, org, _, token in
            for body in [
                ["name": "bad", "cidr": "not-a-cidr", "organizationId": org.id!.uuidString],
                ["name": "bad", "cidr": "203.0.113.0/31", "organizationId": org.id!.uuidString],
                [
                    "name": "bad", "cidr": "203.0.113.0/29", "gateway": "198.51.100.1",
                    "organizationId": org.id!.uuidString,
                ],
            ] {
                try await app.test(.POST, "/api/floating-ip-pools") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    try req.content.encode(body)
                } afterResponse: { res in
                    #expect(res.status == .badRequest)
                }
            }

            let pool = try await self.createPool(app: app, org: org, token: token)
            #expect(pool.cidr == "203.0.113.0/29")
            #expect(pool.gateway == "203.0.113.1")
            #expect(pool.allocatedCount == 0)
        }
    }

    @Test("Overlapping pool CIDRs are rejected within a scope but allowed across sites")
    func poolOverlapGuard() async throws {
        try await withFloatingIPTestApp { app, _, org, _, token in
            _ = try await self.createPool(app: app, org: org, token: token)  // 203.0.113.0/29, unpinned

            // Overlapping unpinned pool → 409 (same answering scope).
            try await app.test(.POST, "/api/floating-ip-pools") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "name": "edge-overlap", "cidr": "203.0.113.0/28",
                    "organizationId": org.id!.uuidString,
                ])
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            // The same CIDR pinned to two *different* sites is two fabrics and
            // is allowed — but each still conflicts with the unpinned pool, so
            // use a disjoint range.
            let siteA = Site(name: "site-a", organizationScope: .organization(org.id!))
            let siteB = Site(name: "site-b", organizationScope: .organization(org.id!))
            try await siteA.save(on: app.db)
            try await siteB.save(on: app.db)
            for (name, site) in [("edge-a", siteA), ("edge-b", siteB)] {
                try await app.test(.POST, "/api/floating-ip-pools") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    try req.content.encode([
                        "name": name, "cidr": "198.51.100.0/29",
                        "siteId": site.id!.uuidString,
                        "organizationId": org.id!.uuidString,
                    ])
                } afterResponse: { res in
                    #expect(res.status == .ok)
                }
            }
        }
    }

    @Test("Pool names are unique per owner, not per deployment")
    func poolNameScopedToOwner() async throws {
        try await withFloatingIPTestApp { app, _, org, _, token in
            let builder = TestDataBuilder(db: app.db)
            let otherOrg = try await builder.createOrganization(name: "FIP Other Org")
            let ou = OrganizationalUnit(
                name: "FIP OU", description: "folder-owned pools", organizationID: org.id!,
                path: "/\(org.id!.uuidString)", depth: 1)
            try await ou.save(on: app.db)

            // Every pool below is unpinned, and unpinned pools conflict with
            // everything regardless of owner — so each takes a disjoint CIDR
            // and the only thing under test is the name.
            func createPublicPool(cidr: String, owner: [String: String]) async throws -> HTTPStatus {
                var status: HTTPStatus = .internalServerError
                try await app.test(.POST, "/api/floating-ip-pools") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    try req.content.encode(["name": "public", "cidr": cidr].merging(owner) { a, _ in a })
                } afterResponse: { res in
                    status = res.status
                }
                return status
            }

            let first = try await createPublicPool(
                cidr: "203.0.113.0/29", owner: ["organizationId": org.id!.uuidString])
            #expect(first == .ok)

            // A second organization takes the same name: the whole point.
            let secondOrg = try await createPublicPool(
                cidr: "198.51.100.0/29", owner: ["organizationId": otherOrg.id!.uuidString])
            #expect(secondOrg == .ok)

            // So does a folder inside the first organization — the two owner
            // columns are indexed separately.
            let folderOwned = try await createPublicPool(
                cidr: "192.0.2.0/29", owner: ["organizationalUnitId": ou.id!.uuidString])
            #expect(folderOwned == .ok)

            // Within one owner the name is still taken.
            let duplicate = try await createPublicPool(
                cidr: "203.0.113.8/29", owner: ["organizationId": org.id!.uuidString])
            #expect(duplicate == .conflict)
        }
    }

    @Test("Reverting the owner-scoped name index names the duplicates it can't collapse")
    func poolNameScopeRevertReportsDuplicates() async throws {
        try await withFloatingIPTestApp { app, _, org, _, token in
            let builder = TestDataBuilder(db: app.db)
            let otherOrg = try await builder.createOrganization(name: "FIP Revert Org")
            for owner in [org.id!, otherOrg.id!] {
                try await FloatingIPPool(
                    name: "public", cidr: "203.0.113.0/29", organizationScope: .organization(owner)
                ).save(on: app.db)
            }

            // The revert restores a global unique index, which the two rows
            // above make impossible — it has to say which name is the problem
            // rather than let Postgres fail on an arbitrary row.
            let thrown = await #expect(throws: ScopeFloatingIPPoolNamesToOwners.DuplicatePoolNames.self) {
                try await ScopeFloatingIPPoolNamesToOwners().revert(on: app.db)
            }
            #expect(thrown?.names == ["public"])

            // And it left the schema alone: the scoped index still rejects a
            // same-owner duplicate.
            var status: HTTPStatus = .internalServerError
            try await app.test(.POST, "/api/floating-ip-pools") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "name": "public", "cidr": "198.51.100.0/29", "organizationId": org.id!.uuidString,
                ])
            } afterResponse: { res in
                status = res.status
            }
            #expect(status == .conflict)
        }
    }

    @Test("A gateway update matching an allocated address is rejected")
    func gatewayCollisionGuard() async throws {
        try await withFloatingIPTestApp { app, _, org, project, token in
            let pool = try await self.createPool(app: app, org: org, token: token)
            try await app.test(.POST, "/api/floating-ips") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["poolId": pool.id.uuidString, "projectId": project.id!.uuidString])
            } afterResponse: { res in
                // Lowest free past the .1 gateway.
                let address = try res.content.decode(FloatingIPResponse.self).address
                #expect(address == "203.0.113.2")
            }

            // Re-pointing the gateway onto the live allocation → 409.
            try await app.test(.PUT, "/api/floating-ip-pools/\(pool.id)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["gateway": "203.0.113.2"])
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            // A free address is fine.
            try await app.test(.PUT, "/api/floating-ip-pools/\(pool.id)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["gateway": "203.0.113.3"])
            } afterResponse: { res in
                #expect(res.status == .ok)
                let gateway = try res.content.decode(FloatingIPPoolResponse.self).gateway
                #expect(gateway == "203.0.113.3")
            }
        }
    }

    @Test("Attaching a second floating IP to a NIC fails on the schema backstop even without the pre-check")
    func nicAttachmentUniquenessBackstop() async throws {
        try await withFloatingIPTestApp { app, _, org, project, token in
            let pool = try await self.createPool(app: app, org: org, token: token)
            let network = LogicalNetwork(
                name: "backstop-net", subnet: "10.50.0.0/24", gateway: "10.50.0.1",
                projectID: try project.requireID(), externalAccess: true)
            try await network.save(on: app.db)
            let (_, nic) = try await self.createVMWithNIC(
                app: app, org: org, project: project, network: network, fixedIP: "10.50.0.5")

            // First attachment via direct row write (simulating a concurrent
            // winner the controller's pre-check didn't see).
            let first = FloatingIP(
                poolID: pool.id, address: "203.0.113.2", projectID: project.id!, interfaceID: nic.id!)
            try await first.save(on: app.db)

            // Second row targeting the same NIC hits the partial unique index.
            let second = FloatingIP(
                poolID: pool.id, address: "203.0.113.3", projectID: project.id!, interfaceID: nic.id!)
            await #expect(throws: (any Error).self) {
                try await second.save(on: app.db)
            }
        }
    }

    @Test("Allocation hands out the lowest free address, skips the gateway, and exhausts to 409")
    func allocationSequence() async throws {
        try await withFloatingIPTestApp { app, _, org, project, token in
            let pool = try await self.createPool(app: app, org: org, token: token)

            // /29 host range is .1–.6; .1 is the gateway, so five addresses.
            var allocated: [String] = []
            for _ in 0..<5 {
                try await app.test(.POST, "/api/floating-ips") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    try req.content.encode([
                        "poolId": pool.id.uuidString, "projectId": project.id!.uuidString,
                    ])
                } afterResponse: { res in
                    #expect(res.status == .ok)
                    allocated.append(try res.content.decode(FloatingIPResponse.self).address)
                }
            }
            #expect(allocated == ["203.0.113.2", "203.0.113.3", "203.0.113.4", "203.0.113.5", "203.0.113.6"])

            try await app.test(.POST, "/api/floating-ips") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["poolId": pool.id.uuidString, "projectId": project.id!.uuidString])
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
        }
    }

    @Test("Attach requires an egress network, matches projects, and bumps the network generation")
    func attachLifecycle() async throws {
        try await withFloatingIPTestApp { app, user, org, project, token in
            let pool = try await self.createPool(app: app, org: org, token: token)

            let egress = LogicalNetwork(
                name: "egress-net", subnet: "10.40.0.0/24", gateway: "10.40.0.1",
                projectID: try project.requireID(), externalAccess: true)
            try await egress.save(on: app.db)
            let isolated = LogicalNetwork(
                name: "isolated-net", subnet: "10.41.0.0/24", gateway: "10.41.0.1",
                projectID: try project.requireID(), externalAccess: false)
            try await isolated.save(on: app.db)

            let (vm, nic) = try await self.createVMWithNIC(
                app: app, org: org, project: project, network: egress, fixedIP: "10.40.0.5")
            let (isolatedVM, _) = try await self.createVMWithNIC(
                app: app, org: org, project: project, network: isolated, fixedIP: "10.41.0.5")

            var fipId: UUID?
            try await app.test(.POST, "/api/floating-ips") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["poolId": pool.id.uuidString, "projectId": project.id!.uuidString])
            } afterResponse: { res in
                fipId = try res.content.decode(FloatingIPResponse.self).id
            }

            // No-egress network → 409.
            try await app.test(.POST, "/api/floating-ips/\(fipId!)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["vmId": isolatedVM.id!.uuidString])
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            // Cross-project VM → 400, the one status every cross-project
            // refusal answers with (issue #777); was 409.
            let builder = TestDataBuilder(db: app.db)
            let otherProject = try await builder.createProject(
                name: "Other FIP Project", description: "", organization: org)
            let (foreignVM, _) = try await self.createVMWithNIC(
                app: app, org: org, project: otherProject, network: egress, fixedIP: "10.40.0.6")
            try await app.test(.POST, "/api/floating-ips/\(fipId!)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["vmId": foreignVM.id!.uuidString])
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            // Happy path.
            let generationBefore = egress.generation
            try await app.test(.POST, "/api/floating-ips/\(fipId!)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["vmId": vm.id!.uuidString])
            } afterResponse: { res in
                #expect(res.status == .ok)
                let body = try res.content.decode(FloatingIPResponse.self)
                #expect(body.vmId == vm.id)
                #expect(body.interfaceId == nic.id)
                #expect(body.fixedIP == "10.40.0.5")
                #expect(body.networkName == "egress-net")
            }
            let refreshedNetwork = try await LogicalNetwork.find(egress.id, on: app.db)
            #expect(refreshedNetwork!.generation == generationBefore + 1)

            // Second floating IP on the same NIC → 409.
            var secondId: UUID?
            try await app.test(.POST, "/api/floating-ips") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["poolId": pool.id.uuidString, "projectId": project.id!.uuidString])
            } afterResponse: { res in
                secondId = try res.content.decode(FloatingIPResponse.self).id
            }
            try await app.test(.POST, "/api/floating-ips/\(secondId!)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["vmId": vm.id!.uuidString])
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            // Release while attached → 409; detach, then release succeeds.
            try await app.test(.DELETE, "/api/floating-ips/\(fipId!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
            try await app.test(.POST, "/api/floating-ips/\(fipId!)/detach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let body = try res.content.decode(FloatingIPResponse.self)
                #expect(body.interfaceId == nil)
            }
            try await app.test(.DELETE, "/api/floating-ips/\(fipId!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }
            _ = user
        }
    }

    /// Registers an agent at the given wire protocol version and places the
    /// VM on it, so attach hits the realizing-agent version gate.
    private func placeVM(
        _ vm: VM, app: Application, org: Organization, protocolVersion: Int, named: String = "fip-agent"
    ) async throws {
        let message = AgentRegisterMessage(
            agentId: named,
            hostname: "fip-host",
            version: "1.0.0",
            capabilities: ["qemu"],
            resources: AgentResources(
                totalCPU: 8, availableCPU: 8,
                totalMemory: 1 << 33, availableMemory: 1 << 33,
                totalDisk: 1 << 39, availableDisk: 1 << 39
            ),
            protocolVersion: protocolVersion
        )
        let agentUUID = try await app.agentService.registerAgent(
            message, agentName: named, organizationScope: .organization(org.id!))
        vm.hypervisorId = agentUUID.uuidString
        try await vm.save(on: app.db)
    }

    @Test("Attach is refused while the VM is unplaced")
    func attachUnplacedVMGate() async throws {
        try await withFloatingIPTestApp { app, _, org, project, token in
            let pool = try await self.createPool(app: app, org: org, token: token)
            let network = LogicalNetwork(
                name: "unplaced-net", subnet: "10.85.0.0/24", gateway: "10.85.0.1",
                projectID: try project.requireID(), externalAccess: true)
            try await network.save(on: app.db)
            let (vm, _) = try await self.createVMWithNIC(
                app: app, org: org, project: project, network: network, fixedIP: "10.85.0.5")
            // Simulate a scheduling-pending (or failed-placement) VM: the
            // scheduler has no floating-IP capability requirement, so an
            // attach accepted now could land on a pre-v12 agent later.
            vm.hypervisorId = nil
            try await vm.save(on: app.db)

            var fipId: UUID?
            try await app.test(.POST, "/api/floating-ips") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["poolId": pool.id.uuidString, "projectId": project.id!.uuidString])
            } afterResponse: { res in
                fipId = try res.content.decode(FloatingIPResponse.self).id
            }
            try await app.test(.POST, "/api/floating-ips/\(fipId!)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["vmId": vm.id!.uuidString])
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
        }
    }

    @Test("Attach is refused when the VM's site has no network controller")
    func attachNoControllerGate() async throws {
        try await withFloatingIPTestApp { app, _, org, project, token in
            let pool = try await self.createPool(app: app, org: org, token: token)
            let network = LogicalNetwork(
                name: "no-controller-net", subnet: "10.95.0.0/24", gateway: "10.95.0.1",
                projectID: try project.requireID(), externalAccess: true)
            try await network.save(on: app.db)
            let (vm, _) = try await self.createVMWithNIC(
                app: app, org: org, project: project, network: network, fixedIP: "10.95.0.5")

            // Move the hosting agent into a site with no designated
            // controller: assembly then sends *no* agent the network state,
            // so nothing would realize the NAT rule.
            let site = Site(name: "controllerless", organizationScope: .organization(org.id!))
            try await site.save(on: app.db)
            let agent = try #require(
                try await Agent.find(UUID(uuidString: vm.hypervisorId!), on: app.db))
            agent.$site.id = site.id
            try await agent.save(on: app.db)

            var fipId: UUID?
            try await app.test(.POST, "/api/floating-ips") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["poolId": pool.id.uuidString, "projectId": project.id!.uuidString])
            } afterResponse: { res in
                fipId = try res.content.decode(FloatingIPResponse.self).id
            }
            try await app.test(.POST, "/api/floating-ips/\(fipId!)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["vmId": vm.id!.uuidString])
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            // Designating the (current-protocol) host as controller unblocks it.
            site.$networkControllerAgent.id = agent.id
            try await site.save(on: app.db)
            try await app.test(.POST, "/api/floating-ips/\(fipId!)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["vmId": vm.id!.uuidString])
            } afterResponse: { res in
                #expect(res.status == .ok)
            }
        }
    }

    @Test("Attach is refused when the site's network controller is long offline")
    func attachOfflineControllerGate() async throws {
        try await withFloatingIPTestApp { app, _, org, project, token in
            let pool = try await self.createPool(app: app, org: org, token: token)
            let network = LogicalNetwork(
                name: "offline-ctl-net", subnet: "10.96.0.0/24", gateway: "10.96.0.1",
                projectID: try project.requireID(), externalAccess: true)
            try await network.save(on: app.db)
            let (vm, _) = try await self.createVMWithNIC(
                app: app, org: org, project: project, network: network, fixedIP: "10.96.0.5")

            // A two-node site: the VM's host, plus a separate controller that
            // has gone quiet past the grace window. The controller is the agent
            // that would author the NAT rule, so nothing realizes it — issue
            // #833's cross-node case, distinct from having no controller at all.
            let site = Site(name: "offline-controller", organizationScope: .organization(org.id!))
            try await site.save(on: app.db)
            let host = try #require(try await Agent.find(UUID(uuidString: vm.hypervisorId!), on: app.db))
            host.$site.id = site.id
            try await host.save(on: app.db)

            let controllerUUID = try await app.agentService.registerAgent(
                AgentRegisterMessage(
                    agentId: "fip-offline-ctl", hostname: "fip-offline-ctl-host", version: "1.0.0",
                    capabilities: ["qemu"],
                    resources: AgentResources(
                        totalCPU: 8, availableCPU: 8, totalMemory: 1 << 33, availableMemory: 1 << 33,
                        totalDisk: 1 << 39, availableDisk: 1 << 39),
                    networkCapability: .overlay, protocolVersion: WireProtocol.currentVersion),
                agentName: "fip-offline-ctl", siteID: site.id,
                organizationScope: .organization(org.id!))
            let controller = try #require(try await Agent.find(controllerUUID, on: app.db))
            controller.lastHeartbeat = Date().addingTimeInterval(
                -(SiteNetworkAuthority.controllerOfflineGrace + 600))
            try await controller.save(on: app.db)

            var fipId: UUID?
            try await app.test(.POST, "/api/floating-ips") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["poolId": pool.id.uuidString, "projectId": project.id!.uuidString])
            } afterResponse: { res in
                fipId = try res.content.decode(FloatingIPResponse.self).id
            }
            try await app.test(.POST, "/api/floating-ips/\(fipId!)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["vmId": vm.id!.uuidString])
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("fip-offline-ctl"))
            }

            // A heartbeat from the controller unblocks the same attach.
            controller.lastHeartbeat = Date()
            try await controller.save(on: app.db)
            try await app.test(.POST, "/api/floating-ips/\(fipId!)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["vmId": vm.id!.uuidString])
            } afterResponse: { res in
                #expect(res.status == .ok)
            }
        }
    }

    @Test("System admins list floating IPs without per-project role bindings")
    func adminListBypass() async throws {
        try await withFloatingIPTestApp { app, _, org, project, token in
            let pool = try await self.createPool(app: app, org: org, token: token)
            try await app.test(.POST, "/api/floating-ips") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["poolId": pool.id.uuidString, "projectId": project.id!.uuidString])
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            // A system admin with no membership or binding anywhere: the admin
            // flag alone (the evaluator's tier-1 policy) must be enough to
            // allocate and to list, with and without an explicit project
            // filter.
            let bareAdmin = try await TestDataBuilder(db: app.db).createUser(
                username: "fip-bare-admin", email: "fip-bare-admin@example.com",
                displayName: "Bare Admin", isSystemAdmin: true)
            let bareAdminToken = try await bareAdmin.generateAPIKey(on: app.db)
            try await app.test(.POST, "/api/floating-ips") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: bareAdminToken)
                try req.content.encode(["poolId": pool.id.uuidString, "projectId": project.id!.uuidString])
            } afterResponse: { res in
                #expect(res.status == .ok)
            }
            try await app.test(.GET, "/api/floating-ips") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: bareAdminToken)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let addresses = try res.content.decode(PagedResponse<FloatingIPResponse>.self).items.map(\.address)
                #expect(addresses.contains("203.0.113.2"))
            }
            try await app.test(.GET, "/api/floating-ips?project_id=\(project.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: bareAdminToken)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let addresses = try res.content.decode(PagedResponse<FloatingIPResponse>.self).items.map(\.address)
                #expect(addresses.contains("203.0.113.2"))
            }
        }
    }

    @Test("Site deletion is refused while floating IP pools are pinned to it")
    func siteDeletePoolGuard() async throws {
        try await withFloatingIPTestApp { app, _, org, _, token in
            let site = Site(name: "pool-pinned-site", organizationScope: .organization(org.id!))
            try await site.save(on: app.db)
            try await app.test(.POST, "/api/floating-ip-pools") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "name": "pinned", "cidr": "203.0.113.0/29",
                    "siteId": site.id!.uuidString,
                    "organizationId": org.id!.uuidString,
                ])
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            // The FK would silently unpin the pool, bypassing overlap scoping.
            try await app.test(.DELETE, "/api/sites/\(site.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
        }
    }

    @Test("Pinning a pool to a site requires manage permission on the site")
    func poolSitePinPermission() async throws {
        try await withFloatingIPTestApp { app, _, org, _, token in
            // The site belongs to a different organization: an admin of
            // `org` may create pools in their own scope but must not occupy
            // another tenant's site.
            let builder = TestDataBuilder(db: app.db)
            let foreignOrg = try await builder.createOrganization(name: "Pool Foreign Org")
            let site = Site(name: "gated-site", organizationScope: .organization(foreignOrg.id!))
            try await site.save(on: app.db)

            let member = try await builder.createUser(
                username: "poolmember",
                email: "poolmember@example.com",
                displayName: "Pool Member",
                isSystemAdmin: false
            )
            try await builder.addUserToOrganization(user: member, organization: org, role: "admin")
            let memberToken = try await member.generateAPIKey(on: app.db)

            try await app.test(.POST, "/api/floating-ip-pools") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: memberToken)
                try req.content.encode([
                    "name": "cross-tenant", "cidr": "203.0.113.0/29",
                    "siteId": site.id!.uuidString,
                    "organizationId": org.id!.uuidString,
                ])
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }

            // Unpinned creation by the same caller is fine.
            try await app.test(.POST, "/api/floating-ip-pools") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: memberToken)
                try req.content.encode([
                    "name": "cross-tenant", "cidr": "203.0.113.0/29",
                    "organizationId": org.id!.uuidString,
                ])
            } afterResponse: { res in
                #expect(res.status == .ok)
            }
        }
    }

    @Test("Attach is refused when the realizing agent predates the floating IP protocol")
    func attachOldAgentGate() async throws {
        try await withFloatingIPTestApp { app, _, org, project, token in
            let pool = try await self.createPool(app: app, org: org, token: token)
            let network = LogicalNetwork(
                name: "old-agent-net", subnet: "10.80.0.0/24", gateway: "10.80.0.1",
                projectID: try project.requireID(), externalAccess: true)
            try await network.save(on: app.db)
            let (vm, _) = try await self.createVMWithNIC(
                app: app, org: org, project: project, network: network, fixedIP: "10.80.0.5")
            try await self.placeVM(vm, app: app, org: org, protocolVersion: 11, named: "old-fip-agent")

            var fipId: UUID?
            try await app.test(.POST, "/api/floating-ips") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["poolId": pool.id.uuidString, "projectId": project.id!.uuidString])
            } afterResponse: { res in
                fipId = try res.content.decode(FloatingIPResponse.self).id
            }

            try await app.test(.POST, "/api/floating-ips/\(fipId!)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["vmId": vm.id!.uuidString])
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            // The same attach succeeds once the agent speaks the protocol.
            let agent = try await Agent.query(on: app.db).filter(\.$name == "old-fip-agent").first()
            agent?.wireProtocolVersion = WireProtocol.currentVersion
            try await agent?.save(on: app.db)
            try await app.test(.POST, "/api/floating-ips/\(fipId!)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["vmId": vm.id!.uuidString])
            } afterResponse: { res in
                #expect(res.status == .ok)
            }
        }
    }

    @Test("Attach requires update permission on the target VM")
    func attachRequiresVMPermission() async throws {
        try await withFloatingIPTestApp { app, _, org, project, token in
            let pool = try await self.createPool(app: app, org: org, token: token)
            let network = LogicalNetwork(
                name: "vm-perm-net", subnet: "10.90.0.0/24", gateway: "10.90.0.1",
                projectID: try project.requireID(), externalAccess: true)
            try await network.save(on: app.db)
            let (vm, _) = try await self.createVMWithNIC(
                app: app, org: org, project: project, network: network, fixedIP: "10.90.0.5")

            // A user who holds the floating IP (a resource-level admin
            // binding, what allocation writes for its creator) but nothing on
            // the VM must not be able to change the VM's exposure.
            let builder = TestDataBuilder(db: app.db)
            let member = try await builder.createUser(
                username: "fipmember",
                email: "fipmember@example.com",
                displayName: "FIP Member",
                isSystemAdmin: false
            )
            let memberToken = try await member.generateAPIKey(on: app.db)

            var fipId: UUID?
            try await app.test(.POST, "/api/floating-ips") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["poolId": pool.id.uuidString, "projectId": project.id!.uuidString])
            } afterResponse: { res in
                #expect(res.status == .ok)
                fipId = try res.content.decode(FloatingIPResponse.self).id
            }
            try await RoleBindingService.grant(
                principalType: .user, principalID: member.id!, role: .admin,
                nodeType: .floatingIP, nodeID: fipId!, createdBy: nil, on: app.db)

            try await app.test(.POST, "/api/floating-ips/\(fipId!)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: memberToken)
                try req.content.encode(["vmId": vm.id!.uuidString])
            } afterResponse: { res in
                // 404, not 403: the refusal must not tell a caller with no
                // rights on this VM that the id names a real one (issue #881).
                // `VMAttachTargetDisclosureTests` pins the indistinguishability.
                #expect(res.status == .notFound)
            }

            // Editor on the VM itself flips the verdict.
            try await RoleBindingService.grant(
                principalType: .user, principalID: member.id!, role: .editor,
                nodeType: .virtualMachine, nodeID: vm.id!, createdBy: nil, on: app.db)
            try await app.test(.POST, "/api/floating-ips/\(fipId!)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: memberToken)
                try req.content.encode(["vmId": vm.id!.uuidString])
            } afterResponse: { res in
                #expect(res.status == .ok)
            }
        }
    }

    @Test("Disabling a network's external access is refused while floating IPs are attached")
    func externalAccessDisableGuard() async throws {
        try await withFloatingIPTestApp { app, _, org, project, token in
            let pool = try await self.createPool(app: app, org: org, token: token)
            let network = LogicalNetwork(
                name: "egress-guard-net", subnet: "10.60.0.0/24", gateway: "10.60.0.1",
                projectID: try project.requireID(), externalAccess: true)
            try await network.save(on: app.db)
            let (vm, _) = try await self.createVMWithNIC(
                app: app, org: org, project: project, network: network, fixedIP: "10.60.0.5")

            var fipId: UUID?
            try await app.test(.POST, "/api/floating-ips") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["poolId": pool.id.uuidString, "projectId": project.id!.uuidString])
            } afterResponse: { res in
                fipId = try res.content.decode(FloatingIPResponse.self).id
            }
            try await app.test(.POST, "/api/floating-ips/\(fipId!)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["vmId": vm.id!.uuidString])
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            // Turning egress off would silently drop the attached FIP's NAT.
            try await app.test(.PUT, "/api/networks/\(network.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["externalAccess": false])
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            // Detach, then the same update succeeds.
            try await app.test(.POST, "/api/floating-ips/\(fipId!)/detach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
            }
            try await app.test(.PUT, "/api/networks/\(network.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["externalAccess": false])
            } afterResponse: { res in
                #expect(res.status == .ok)
            }
        }
    }

    @Test("Moving a pool between sites is refused while addresses are attached")
    func poolSiteMoveGuard() async throws {
        try await withFloatingIPTestApp { app, _, org, project, token in
            let pool = try await self.createPool(app: app, org: org, token: token)
            let network = LogicalNetwork(
                name: "site-move-net", subnet: "10.70.0.0/24", gateway: "10.70.0.1",
                projectID: try project.requireID(), externalAccess: true)
            try await network.save(on: app.db)
            let (vm, _) = try await self.createVMWithNIC(
                app: app, org: org, project: project, network: network, fixedIP: "10.70.0.5")

            var fipId: UUID?
            try await app.test(.POST, "/api/floating-ips") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["poolId": pool.id.uuidString, "projectId": project.id!.uuidString])
            } afterResponse: { res in
                fipId = try res.content.decode(FloatingIPResponse.self).id
            }
            try await app.test(.POST, "/api/floating-ips/\(fipId!)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["vmId": vm.id!.uuidString])
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            let site = Site(name: "move-target", organizationScope: .organization(org.id!))
            try await site.save(on: app.db)

            // Pinning the pool to a site while an address is attached to the
            // (unpinned) old scope would strand the attachment.
            try await app.test(.PUT, "/api/floating-ip-pools/\(pool.id)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["siteId": site.id!.uuidString])
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            // Detached, the move goes through.
            try await app.test(.POST, "/api/floating-ips/\(fipId!)/detach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
            }
            try await app.test(.PUT, "/api/floating-ip-pools/\(pool.id)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["siteId": site.id!.uuidString])
            } afterResponse: { res in
                #expect(res.status == .ok)
                let body = try res.content.decode(FloatingIPPoolResponse.self)
                #expect(body.siteId == site.id)
            }
        }
    }

    @Test("Pool deletion is refused while addresses are allocated")
    func poolDeleteGuard() async throws {
        try await withFloatingIPTestApp { app, _, org, project, token in
            let pool = try await self.createPool(app: app, org: org, token: token)
            var fipId: UUID?
            try await app.test(.POST, "/api/floating-ips") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["poolId": pool.id.uuidString, "projectId": project.id!.uuidString])
            } afterResponse: { res in
                fipId = try res.content.decode(FloatingIPResponse.self).id
            }

            try await app.test(.DELETE, "/api/floating-ip-pools/\(pool.id)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            try await app.test(.DELETE, "/api/floating-ips/\(fipId!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }
            try await app.test(.DELETE, "/api/floating-ip-pools/\(pool.id)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }
        }
    }
}
