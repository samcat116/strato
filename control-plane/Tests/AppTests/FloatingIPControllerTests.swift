import Fluent
import StratoShared
import Testing
import Vapor
import VaporTesting

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
            app.spicedbMockAllows = true

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
            vmID: vm.id!, network: network.name, macAddress: VMNetworkInterface.generateMACAddress())
        try await nic.save(on: app.db)
        try await VMInterfaceAddress(
            interfaceID: nic.id!, network: network.name, family: .ipv4,
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
                projectID: project.id, externalAccess: true)
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
                projectID: project.id, externalAccess: true)
            try await egress.save(on: app.db)
            let isolated = LogicalNetwork(
                name: "isolated-net", subnet: "10.41.0.0/24", gateway: "10.41.0.1",
                projectID: project.id, externalAccess: false)
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

            // Cross-project VM → 409.
            let builder = TestDataBuilder(db: app.db)
            let otherProject = try await builder.createProject(
                name: "Other FIP Project", description: "", organization: org)
            let (foreignVM, _) = try await self.createVMWithNIC(
                app: app, org: org, project: otherProject, network: egress, fixedIP: "10.40.0.6")
            try await app.test(.POST, "/api/floating-ips/\(fipId!)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["vmId": foreignVM.id!.uuidString])
            } afterResponse: { res in
                #expect(res.status == .conflict)
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
                projectID: project.id, externalAccess: true)
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
                projectID: project.id, externalAccess: true)
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

    @Test("System admins list floating IPs without per-project SpiceDB tuples")
    func adminListBypass() async throws {
        try await withFloatingIPTestApp { app, _, org, project, token in
            let pool = try await self.createPool(app: app, org: org, token: token)
            try await app.test(.POST, "/api/floating-ips") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["poolId": pool.id.uuidString, "projectId": project.id!.uuidString])
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            // Deny every project permission: the admin flag alone must be
            // enough to allocate and to list, with and without an explicit
            // project filter.
            app.spicedbMockDeniedResources = ["project"]
            try await app.test(.POST, "/api/floating-ips") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["poolId": pool.id.uuidString, "projectId": project.id!.uuidString])
            } afterResponse: { res in
                #expect(res.status == .ok)
            }
            try await app.test(.GET, "/api/floating-ips") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let addresses = try res.content.decode([FloatingIPResponse].self).map(\.address)
                #expect(addresses.contains("203.0.113.2"))
            }
            try await app.test(.GET, "/api/floating-ips?project_id=\(project.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let addresses = try res.content.decode([FloatingIPResponse].self).map(\.address)
                #expect(addresses.contains("203.0.113.2"))
            }
            app.spicedbMockDeniedResources = []
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
                projectID: project.id, externalAccess: true)
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
                projectID: project.id, externalAccess: true)
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
                #expect(res.status == .forbidden)
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
                projectID: project.id, externalAccess: true)
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
                projectID: project.id, externalAccess: true)
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
