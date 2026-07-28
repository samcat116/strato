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
        var hypervisorType: String? = nil
    }

    private func gb(_ value: Double) -> Int64 { Int64(value * 1024 * 1024 * 1024) }

    private func withApp(
        _ test: (Application, User, Organization, Project, Image, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(username: "netseluser", email: "netsel@example.com")
            let org = try await builder.createOrganization(name: "NetSel Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            user.currentOrganizationId = org.id
            try await user.save(on: app.db)

            let project = try await builder.createProject(
                name: "NetSel Project", description: "p", organization: org)
            // Nothing provisions a network with a project (issue #765), so the
            // fixture makes the one most tests here select by name.
            try await builder.createNetwork(name: "default", project: project)
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
            #expect(created?.logicalNetworkID == network.id)
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
                        networkId: nil, networkName: "default", userData: payload))
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
                        networkId: nil, networkName: "default", userData: "echo missing shebang\n"))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            let vm = try await VM.query(on: app.db).filter(\.$name == "bad-userdata-vm").first()
            #expect(vm == nil)
        }
    }

    @Test("POST /api/vms rejects user data for firecracker VMs (400)")
    func createFirecrackerWithUserDataRejected() async throws {
        try await withApp { app, _, _, project, image, token in
            // Cloud-init user data only reaches the guest on the QEMU
            // disk-boot path; a firecracker create must fail loudly instead
            // of accepting a payload the agent would silently ignore.
            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateVMBody(
                        name: "fc-userdata-vm", imageId: image.id, projectId: project.id,
                        environment: "development", cpu: 1, memory: gb(1), disk: gb(10),
                        networkId: nil, networkName: "default",
                        userData: "#cloud-config\npackages: [nginx]\n",
                        hypervisorType: "firecracker"))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("firecracker"))
            }

            let vm = try await VM.query(on: app.db).filter(\.$name == "fc-userdata-vm").first()
            #expect(vm == nil)
        }
    }

    @Test("VM status and update responses do not expose cloud-init user data")
    func statusAndUpdateRedactUserData() async throws {
        try await withApp { app, _, _, project, image, token in
            // The payload doubles as the leak marker: it must never appear in
            // any read/update response body (user data can carry secrets).
            let secret = "#cloud-config\nwrite_files:\n  - path: /etc/token\n    content: sup3rs3cret\n"
            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateVMBody(
                        name: "secret-vm", imageId: image.id, projectId: project.id,
                        environment: "development", cpu: 1, memory: gb(1), disk: gb(10),
                        networkId: nil, networkName: "default", userData: secret))
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }

            let vm = try await VM.query(on: app.db).filter(\.$name == "secret-vm").first()
            #expect(vm?.userData == secret)
            let vmId = try #require(vm?.id)

            try await app.test(.GET, "/api/vms/\(vmId)/status") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                #expect(!res.body.string.contains("sup3rs3cret"))
                #expect(!res.body.string.contains("userData"))
                #expect(res.body.string.contains("\"status\""))
            }

            try await app.test(.PUT, "/api/vms/\(vmId)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["description": "updated"])
            } afterResponse: { res in
                #expect(res.status == .ok)
                #expect(!res.body.string.contains("sup3rs3cret"))
                #expect(!res.body.string.contains("userData"))
            }
        }
    }

    @Test("POST /api/vms is denied (403) when the caller lacks vm:create on the project")
    func createDeniedWithoutProjectCreatePermission() async throws {
        try await withApp { app, _, org, project, image, _ in
            // A project *viewer* can read the image but does not hold
            // vm:create — org membership plus read access must not authorize
            // VM creation.
            let builder = TestDataBuilder(db: app.db)
            let viewer = try await builder.createUser(
                username: "vm-net-viewer", email: "vm-net-viewer@example.com")
            try await builder.addUserToOrganization(user: viewer, organization: org, role: "member")
            viewer.currentOrganizationId = org.id
            try await viewer.save(on: app.db)
            try await RoleBindingService.grant(
                principalType: .user, principalID: viewer.id!, role: .viewer,
                nodeType: .project, nodeID: project.id!, createdBy: nil, on: app.db)
            let viewerToken = try await viewer.generateAPIKey(on: app.db)

            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: viewerToken)
                try req.content.encode(
                    CreateVMBody(
                        name: "unauthorized-vm", imageId: image.id, projectId: project.id,
                        environment: "development", cpu: 1, memory: gb(1), disk: gb(10),
                        networkId: nil, networkName: "default"))
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

    @Test("POST /api/vms by network name resolves the caller's own project's network")
    func createByNameResolvesWithinProject() async throws {
        try await withApp { app, _, org, project, image, token in
            // A same-named network in another project must not be reachable —
            // and must not even perturb the lookup (issue #765).
            let otherProject = try await TestDataBuilder(db: app.db).createProject(
                name: "Twin Project", description: "p", organization: org)
            let twin = try await TestDataBuilder(db: app.db).createNetwork(
                name: "default", project: otherProject, subnet: "10.130.0.0/24", gateway: "10.130.0.1")

            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateVMBody(
                        name: "named-vm", imageId: image.id, projectId: project.id,
                        environment: "development", cpu: 1, memory: gb(1), disk: gb(10),
                        networkId: nil, networkName: "default"))
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }

            let created = try await nic(forVMNamed: "named-vm", on: app.db)
            #expect(created?.logicalNetworkID != twin.id)
            // The caller's own "default", whose subnet is the fixture's.
            #expect(created?.ipv4Address?.address.hasPrefix("192.168.1.") == true)
        }
    }

    @Test("POST /api/vms with no network at all is rejected (400)")
    func createWithoutNetworkRejected() async throws {
        try await withApp { app, _, _, project, image, token in
            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateVMBody(
                        name: "networkless-vm", imageId: image.id, projectId: project.id,
                        environment: "development", cpu: 1, memory: gb(1), disk: gb(10),
                        networkId: nil, networkName: nil))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            #expect(try await VM.query(on: app.db).filter(\.$name == "networkless-vm").count() == 0)
        }
    }

    @Test("POST /api/vms reports a network from a different project as not found (404)")
    func createRejectsCrossProjectNetwork() async throws {
        try await withApp { app, user, org, project, image, token in
            let otherProject = try await TestDataBuilder(db: app.db).createProject(
                name: "Foreign Project", description: "p", organization: org)
            let foreignNetwork = LogicalNetwork(
                name: "foreign-net", subnet: "10.110.0.0/24", gateway: "10.110.0.1",
                projectID: otherProject.id!, createdByID: user.id!)
            try await foreignNetwork.save(on: app.db)

            // 404, not 403: confirming the id exists elsewhere would disclose
            // another tenant's networks (issue #765).
            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateVMBody(
                        name: "cross-vm", imageId: image.id, projectId: project.id,
                        environment: "development", cpu: 1, memory: gb(1), disk: gb(10),
                        networkId: foreignNetwork.id, networkName: nil))
            } afterResponse: { res in
                #expect(res.status == .notFound)
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

    @Test("POST /api/vms rejects an unknown network id (404)")
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
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("GET /api/vms/:id includes the VM's network interfaces")
    func showIncludesNetworkInterfaces() async throws {
        try await withApp { app, _, _, project, _, token in
            let builder = TestDataBuilder(db: app.db)
            let vm = try await builder.createVM(name: "iface-vm", project: project)
            let network = try await builder.createNetwork(
                name: "iface-net", project: project, subnet: "192.168.9.0/24", gateway: "192.168.9.1")
            let nic = VMNetworkInterface(
                vmID: vm.id!, logicalNetworkID: try network.requireID(),
                macAddress: "00:0c:29:aa:bb:cc",
                deviceName: "net0", orderIndex: 0)
            try await nic.save(on: app.db)
            let address = VMInterfaceAddress(
                interfaceID: nic.id!, logicalNetworkID: try network.requireID(), family: .ipv4,
                address: "192.168.1.42", prefixLength: 24, gateway: "192.168.1.1")
            try await address.save(on: app.db)

            try await app.test(.GET, "/api/vms/\(vm.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let detail = try res.content.decode(VMDetailResponse.self)
                #expect(detail.networkInterfaces.count == 1)
                let iface = detail.networkInterfaces.first
                #expect(iface?.networkId == network.id)
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
