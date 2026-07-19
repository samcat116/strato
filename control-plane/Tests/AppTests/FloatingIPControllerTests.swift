import Fluent
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
            try await builder.addUserToOrganization(user: user, organization: org, role: "member")
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

    /// A project VM with one NIC on `network` carrying a fixed IPv4 address.
    private func createVMWithNIC(
        app: Application, project: Project, network: LogicalNetwork, fixedIP: String
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
                app: app, project: project, network: egress, fixedIP: "10.40.0.5")
            let (isolatedVM, _) = try await self.createVMWithNIC(
                app: app, project: project, network: isolated, fixedIP: "10.41.0.5")

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
                app: app, project: otherProject, network: egress, fixedIP: "10.40.0.6")
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
