import Testing
import Vapor
import Fluent
import VaporTesting
@testable import App

/// Tests for choosing a VM's network at create time (VMController.create) and
/// for surfacing a VM's network interfaces in the API response. The NIC row is
/// written inside the create transaction before the 202 is returned, so the
/// tests can assert on `VMNetworkInterface` rows immediately after the response.
@Suite("VM Network Selection Tests", .serialized)
final class VMNetworkSelectionTests {

    // Body mirroring VMController's private CreateVMRequest so tests can POST /api/vms.
    struct CreateVMBody: Content {
        let name: String
        let imageId: UUID?
        let projectId: UUID?
        let environment: String?
        let cpu: Int?
        let memory: Int64?
        let disk: Int64?
        let networkId: UUID?
        let networkName: String?
        var userData: String? = nil
    }

    private func gb(_ value: Double) -> Int64 { Int64(value * 1024 * 1024 * 1024) }

    private func withApp(
        _ test: (Application, User, Organization, Project, Image, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()
            app.spicedbMockAllows = true

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(username: "netseluser", email: "netsel@example.com")
            let org = try await builder.createOrganization(name: "NetSel Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            user.currentOrganizationId = org.id
            try await user.save(on: app.db)

            let project = try await builder.createProject(
                name: "NetSel Project", description: "p", organization: org)
            let image = try await builder.createImage(project: project, uploadedBy: user)
            let token = try await user.generateAPIKey(on: app.db)

            try await test(app, user, org, project, image, token)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    private func nic(forVMNamed name: String, on db: any Database) async throws -> VMNetworkInterface? {
        guard let vm = try await VM.query(on: db).filter(\.$name == name).first() else { return nil }
        return try await VMNetworkInterface.query(on: db)
            .filter(\.$vm.$id == vm.id!)
            .with(\.$addresses)
            .first()
    }

    @Test("POST /api/vms with a networkId attaches the NIC to that network")
    func createWithNetworkId() async throws {
        try await withApp { app, user, _, project, image, token in
            let network = LogicalNetwork(
                name: "selectable-net", subnet: "10.100.0.0/24", gateway: "10.100.0.1",
                projectID: project.id!, createdByID: user.id!)
            try await network.save(on: app.db)

            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateVMBody(
                        name: "net-vm", imageId: image.id, projectId: project.id,
                        environment: "development", cpu: 1, memory: gb(1), disk: gb(10),
                        networkId: network.id, networkName: nil))
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }

            let created = try await nic(forVMNamed: "net-vm", on: app.db)
            #expect(created?.network == "selectable-net")
            // Allocated from the chosen subnet, not the default 192.168.1.0/24.
            let address = created?.ipv4Address
            #expect(address?.address.hasPrefix("10.100.0.") == true)
            #expect(address?.prefixLength == 24)
            #expect(address?.gateway == "10.100.0.1")
        }
    }

    @Test("POST /api/vms persists cloud-init user data verbatim")
    func createWithUserData() async throws {
        try await withApp { app, _, _, project, image, token in
            let payload = "#cloud-config\npackages:\n  - nginx\nruncmd:\n  - touch /root/provisioned\n"
            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateVMBody(
                        name: "userdata-vm", imageId: image.id, projectId: project.id,
                        environment: "development", cpu: 1, memory: gb(1), disk: gb(10),
                        networkId: nil, networkName: nil, userData: payload))
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }

            let vm = try await VM.query(on: app.db).filter(\.$name == "userdata-vm").first()
            #expect(vm?.userData == payload)
        }
    }

    @Test("POST /api/vms rejects user data without a cloud-init header (400)")
    func createWithHeaderlessUserDataRejected() async throws {
        try await withApp { app, _, _, project, image, token in
            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateVMBody(
                        name: "bad-userdata-vm", imageId: image.id, projectId: project.id,
                        environment: "development", cpu: 1, memory: gb(1), disk: gb(10),
                        networkId: nil, networkName: nil, userData: "echo missing shebang\n"))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            let vm = try await VM.query(on: app.db).filter(\.$name == "bad-userdata-vm").first()
            #expect(vm == nil)
        }
    }

    @Test("POST /api/vms is denied (403) when SpiceDB withholds project create")
    func createDeniedWithoutProjectCreatePermission() async throws {
        try await withApp { app, _, _, project, image, token in
            // Org membership alone must not authorize VM creation: withhold the
            // project-scoped `create_resources` permission (deny the "project"
            // resource type) while image read still passes, and the create must 403.
            app.spicedbMockDeniedResources = ["project"]

            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateVMBody(
                        name: "unauthorized-vm", imageId: image.id, projectId: project.id,
                        environment: "development", cpu: 1, memory: gb(1), disk: gb(10),
                        networkId: nil, networkName: nil))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }

            // And no VM row was created as a side effect.
            let leaked = try await VM.query(on: app.db).filter(\.$name == "unauthorized-vm").first()
            #expect(leaked == nil)
        }
    }

    @Test("POST /api/vms on a dual-stack network allocates one address per family")
    func createOnDualStackNetwork() async throws {
        try await withApp { app, user, _, project, image, token in
            let network = LogicalNetwork(
                name: "dual-net", subnet: "10.101.0.0/24", gateway: "10.101.0.1",
                subnet6: "fd00:66::/64", gateway6: "fd00:66::1",
                projectID: project.id!, createdByID: user.id!)
            try await network.save(on: app.db)

            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateVMBody(
                        name: "dual-vm", imageId: image.id, projectId: project.id,
                        environment: "development", cpu: 1, memory: gb(1), disk: gb(10),
                        networkId: network.id, networkName: nil))
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }

            let created = try await nic(forVMNamed: "dual-vm", on: app.db)
            let ipv4 = created?.ipv4Address
            #expect(ipv4?.address.hasPrefix("10.101.0.") == true)
            let ipv6 = created?.ipv6Address
            #expect(ipv6?.address == "fd00:66::100")
            #expect(ipv6?.prefixLength == 64)
            #expect(ipv6?.gateway == "fd00:66::1")
        }
    }

    @Test("POST /api/vms omitting the network falls back to the default network")
    func createWithoutNetworkUsesDefault() async throws {
        try await withApp { app, _, _, project, image, token in
            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateVMBody(
                        name: "default-vm", imageId: image.id, projectId: project.id,
                        environment: "development", cpu: 1, memory: gb(1), disk: gb(10),
                        networkId: nil, networkName: nil))
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }

            let created = try await nic(forVMNamed: "default-vm", on: app.db)
            #expect(created?.network == LogicalNetwork.defaultNetworkName)
        }
    }

    @Test("POST /api/vms rejects a network from a different project (403)")
    func createRejectsCrossProjectNetwork() async throws {
        try await withApp { app, user, org, project, image, token in
            let otherProject = try await TestDataBuilder(db: app.db).createProject(
                name: "Foreign Project", description: "p", organization: org)
            let foreignNetwork = LogicalNetwork(
                name: "foreign-net", subnet: "10.110.0.0/24", gateway: "10.110.0.1",
                projectID: otherProject.id!, createdByID: user.id!)
            try await foreignNetwork.save(on: app.db)

            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateVMBody(
                        name: "cross-vm", imageId: image.id, projectId: project.id,
                        environment: "development", cpu: 1, memory: gb(1), disk: gb(10),
                        networkId: foreignNetwork.id, networkName: nil))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }

            #expect(try await VM.query(on: app.db).filter(\.$name == "cross-vm").count() == 0)
        }
    }

    @Test("POST /api/vms rejects specifying both networkId and networkName (400)")
    func createRejectsBothNetworkFields() async throws {
        try await withApp { app, user, _, project, image, token in
            let network = LogicalNetwork(
                name: "both-net", subnet: "10.120.0.0/24", gateway: "10.120.0.1",
                projectID: project.id!, createdByID: user.id!)
            try await network.save(on: app.db)

            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateVMBody(
                        name: "both-vm", imageId: image.id, projectId: project.id,
                        environment: "development", cpu: 1, memory: gb(1), disk: gb(10),
                        networkId: network.id, networkName: "both-net"))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("POST /api/vms rejects an unknown network id (400)")
    func createRejectsUnknownNetwork() async throws {
        try await withApp { app, _, _, project, image, token in
            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateVMBody(
                        name: "ghost-vm", imageId: image.id, projectId: project.id,
                        environment: "development", cpu: 1, memory: gb(1), disk: gb(10),
                        networkId: UUID(), networkName: nil))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("GET /api/vms/:id includes the VM's network interfaces")
    func showIncludesNetworkInterfaces() async throws {
        try await withApp { app, _, _, project, _, token in
            let vm = try await TestDataBuilder(db: app.db).createVM(name: "iface-vm", project: project)
            let nic = VMNetworkInterface(
                vmID: vm.id!, network: "default",
                macAddress: "00:0c:29:aa:bb:cc",
                deviceName: "net0", orderIndex: 0)
            try await nic.save(on: app.db)
            let address = VMInterfaceAddress(
                interfaceID: nic.id!, network: "default", family: .ipv4,
                address: "192.168.1.42", prefixLength: 24, gateway: "192.168.1.1")
            try await address.save(on: app.db)

            try await app.test(.GET, "/api/vms/\(vm.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let detail = try res.content.decode(VMDetailResponse.self)
                #expect(detail.networkInterfaces.count == 1)
                let iface = detail.networkInterfaces.first
                #expect(iface?.network == "default")
                #expect(iface?.addresses.count == 1)
                let respAddress = iface?.addresses.first
                #expect(respAddress?.family == "ipv4")
                #expect(respAddress?.address == "192.168.1.42")
                #expect(respAddress?.prefixLength == 24)
                #expect(respAddress?.gateway == "192.168.1.1")
                #expect(iface?.macAddress == "00:0c:29:aa:bb:cc")
                #expect(iface?.deviceName == "net0")
            }
        }
    }
}
