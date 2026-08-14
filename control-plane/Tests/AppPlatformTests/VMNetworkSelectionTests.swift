import Testing
import Vapor
import Fluent
import VaporTesting
import AppTestSupport
import StratoShared
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
        var guestAgentEnabled: Bool? = nil
        var metadataEnabled: Bool? = nil
        var metadataSource: String? = nil
    }

    struct CreateNICBody: Content {
        let networkId: UUID?
        let networkName: String?
        var securityGroupIds: [UUID]? = nil
        var mtu: Int? = nil
    }

    struct CreateMultiVMBody: Content {
        let name: String
        let imageId: UUID
        let projectId: UUID
        let networkInterfaces: [CreateNICBody]
        var networkId: UUID? = nil
        var securityGroupIds: [UUID]? = nil
        var metadataSource: String? = nil
    }

    private func gb(_ value: Double) -> Int64 { Int64(value * 1024 * 1024 * 1024) }

    private func addFirecrackerArtifacts(to image: Image, on db: any Database) async throws {
        let imageID = try image.requireID()
        let checksum = String(repeating: "c", count: 64)
        try await ImageArtifact(
            imageID: imageID, kind: .kernel, format: nil,
            architecture: image.architecture, filename: "vmlinux", size: 1,
            checksum: checksum, storagePath: "images/\(imageID)/kernel/vmlinux"
        ).save(on: db)
        try await ImageArtifact(
            imageID: imageID, kind: .rootfs, format: .raw,
            architecture: image.architecture, filename: "rootfs.raw", size: 1,
            checksum: checksum, storagePath: "images/\(imageID)/rootfs/rootfs.raw"
        ).save(on: db)
    }

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

    private func placementSiteID(for project: Project, on db: any Database) async throws -> UUID {
        try await TestDataBuilder(db: db).placementSite(for: project).requireID()
    }

    @Test("POST /api/vms with a networkId attaches the NIC to that network")
    func createWithNetworkId() async throws {
        try await withApp { app, user, _, project, image, token in
            let network = LogicalNetwork(
                name: "selectable-net", subnet: "10.100.0.0/24", gateway: "10.100.0.1",
                projectID: project.id!, createdByID: user.id!,
                siteID: try await placementSiteID(for: project, on: app.db))
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

    @Test("POST /api/vms creates multiple stable NICs, including duplicate network selections")
    func createWithMultipleInterfaces() async throws {
        try await withApp { app, _, _, project, image, token in
            let network = try #require(
                try await LogicalNetwork.query(on: app.db)
                    .filter(\.$project.$id == project.id!)
                    .filter(\.$name == "default")
                    .first())
            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateMultiVMBody(
                        name: "multi-nic-vm",
                        imageId: image.id!,
                        projectId: project.id!,
                        networkInterfaces: [
                            CreateNICBody(networkId: network.id, networkName: nil, mtu: 1400),
                            CreateNICBody(networkId: network.id, networkName: nil, mtu: 9000),
                        ]))
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }

            let vm = try #require(
                try await VM.query(on: app.db).filter(\.$name == "multi-nic-vm").first())
            let nics = try await VMNetworkInterface.query(on: app.db)
                .filter(\.$vm.$id == vm.id!)
                .with(\.$addresses)
                .sort(\.$orderIndex)
                .all()
            #expect(nics.count == 2)
            #expect(nics.map(\.orderIndex) == [0, 1])
            #expect(nics.map(\.deviceName) == ["net0", "net1"])
            #expect(nics.map(\.mtu) == [1400, 9000])
            #expect(Set(nics.compactMap(\.ipv4Address?.address)).count == 2)
            #expect(
                try await VMInterfaceSecurityGroup.query(on: app.db)
                    .filter(\.$interface.$id ~~ nics.compactMap(\.id)).count() == 2)

            // Exercise the same create-derived rows through the wire spec the
            // agent consumes. This is the API-reachable source shape for the
            // existing two-interface domain XML golden.
            let volumes = try await Volume.query(on: app.db)
                .filter(\.$vm.$id == vm.id!).all()
            let spec = try VMSpecBuilder.buildVMSpec(
                from: vm, image: image, volumes: volumes, networkInterfaces: nics,
                networks: [try network.requireID(): network])
            #expect(spec.networks.map(\.interfaceId) == nics.map(\.id))
            #expect(spec.networks.map(\.deviceName) == ["net0", "net1"])
            #expect(spec.networks.map(\.orderIndex) == [0, 1])
            #expect(spec.networks.map(\.mtu) == [1400, 9000])
        }
    }

    @Test("POST /api/vms rejects mixed scalar and multi-NIC forms")
    func createRejectsMixedNetworkForms() async throws {
        try await withApp { app, _, _, project, image, token in
            let network = try #require(
                try await LogicalNetwork.query(on: app.db)
                    .filter(\.$project.$id == project.id!)
                    .first())
            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateMultiVMBody(
                        name: "mixed-network-vm",
                        imageId: image.id!,
                        projectId: project.id!,
                        networkInterfaces: [
                            CreateNICBody(networkId: network.id, networkName: nil)
                        ],
                        networkId: network.id))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
            #expect(try await VM.query(on: app.db).filter(\.$name == "mixed-network-vm").count() == 0)
        }
    }

    @Test("POST /api/vms enforces the eight-interface creation limit")
    func createRejectsNineInterfaces() async throws {
        try await withApp { app, _, _, project, image, token in
            let network = try #require(
                try await LogicalNetwork.query(on: app.db)
                    .filter(\.$project.$id == project.id!)
                    .first())
            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateMultiVMBody(
                        name: "nine-nic-vm",
                        imageId: image.id!,
                        projectId: project.id!,
                        networkInterfaces: (0..<9).map { _ in
                            CreateNICBody(networkId: network.id, networkName: nil)
                        }))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("POST /api/vms enforces the IPv6 minimum MTU per interface")
    func createRejectsIPv6InterfaceBelowMinimumMTU() async throws {
        try await withApp { app, user, _, project, image, token in
            let network = LogicalNetwork(
                name: "ipv6-mtu-net", subnet: "10.102.0.0/24", gateway: "10.102.0.1",
                subnet6: "fd00:102::/64", gateway6: "fd00:102::1",
                projectID: try project.requireID(), createdByID: try user.requireID(),
                siteID: try await placementSiteID(for: project, on: app.db))
            try await network.save(on: app.db)

            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateMultiVMBody(
                        name: "low-ipv6-mtu-vm", imageId: try image.requireID(),
                        projectId: try project.requireID(),
                        networkInterfaces: [
                            CreateNICBody(
                                networkId: try network.requireID(), networkName: nil, mtu: 1_279)
                        ]))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
            #expect(
                try await VM.query(on: app.db)
                    .filter(\.$name == "low-ipv6-mtu-vm").count() == 0)
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

    @Test("POST /api/vms persists an explicit guest-agent opt-in and defaults it off")
    func createWithGuestAgentFlag() async throws {
        try await withApp { app, _, _, project, image, token in
            for (name, enabled) in [("guest-agent-on", true), ("guest-agent-off", nil)] {
                try await app.test(.POST, "/api/vms") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    try req.content.encode(
                        CreateVMBody(
                            name: name, imageId: image.id, projectId: project.id,
                            environment: "development", cpu: 1, memory: gb(1), disk: gb(10),
                            networkId: nil, networkName: "default",
                            guestAgentEnabled: enabled))
                } afterResponse: { res in
                    #expect(res.status == .accepted)
                    #expect(res.body.string.contains("\"guestAgentEnabled\":\(enabled ?? false)"))
                }
            }

            let optedIn = try await VM.query(on: app.db).filter(\.$name == "guest-agent-on").first()
            let defaulted = try await VM.query(on: app.db).filter(\.$name == "guest-agent-off").first()
            #expect(optedIn?.guestAgentEnabled == true)
            #expect(defaulted?.guestAgentEnabled == false)
        }
    }

    @Test("POST /api/vms persists metadataSource and defaults it to the full ISO")
    func createWithMetadataSource() async throws {
        try await withApp { app, _, _, project, image, token in
            for (name, source) in [("bootstrap-imds", "imds"), ("bootstrap-default", nil)] {
                try await app.test(.POST, "/api/vms") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    try req.content.encode(
                        CreateVMBody(
                            name: name, imageId: image.id, projectId: project.id,
                            environment: "development", cpu: 1, memory: gb(1), disk: gb(10),
                            networkId: nil, networkName: "default",
                            metadataSource: source))
                } afterResponse: { res in
                    #expect(res.status == .accepted)
                    #expect(res.body.string.contains("\"metadataSource\":\"\(source ?? "iso")\""))
                }
            }

            let imds = try await VM.query(on: app.db).filter(\.$name == "bootstrap-imds").first()
            let defaulted = try await VM.query(on: app.db).filter(\.$name == "bootstrap-default").first()
            #expect(imds?.metadataSource == .imds)
            #expect(defaulted?.metadataSource == .iso)
        }
    }

    @Test("POST /api/vms requires a reachable metadata service for IMDS bootstrap")
    func createIMDSRequiresMetadataReachability() async throws {
        try await withApp { app, user, _, project, image, token in
            let defaultNetwork = try #require(
                try await LogicalNetwork.query(on: app.db)
                    .filter(\.$project.$id == project.id!)
                    .filter(\.$name == "default")
                    .first())

            // A VM-level opt-out makes the bootstrap endpoint refuse this VM
            // even when its selected network publishes the service.
            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateVMBody(
                        name: "imds-disabled-vm", imageId: image.id, projectId: project.id,
                        environment: "development", cpu: 1, memory: gb(1), disk: gb(10),
                        networkId: nil, networkName: "default",
                        metadataEnabled: false, metadataSource: "imds"))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("metadataEnabled"))
            }

            // A network-level opt-out means the agent creates no metadata
            // localport or listener for the seedfrom URL.
            defaultNetwork.metadataEnabled = false
            try await defaultNetwork.save(on: app.db)
            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateVMBody(
                        name: "imds-disabled-network", imageId: image.id, projectId: project.id,
                        environment: "development", cpu: 1, memory: gb(1), disk: gb(10),
                        networkId: nil, networkName: "default", metadataSource: "imds"))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("at least one selected network"))
            }
            #expect(
                try await VM.query(on: app.db)
                    .filter(\.$name == "imds-disabled-vm")
                    .first() == nil)
            #expect(
                try await VM.query(on: app.db)
                    .filter(\.$name == "imds-disabled-network")
                    .first() == nil)

            // The compatibility ISO does not need the metadata service.
            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateVMBody(
                        name: "iso-disabled-network", imageId: image.id, projectId: project.id,
                        environment: "development", cpu: 1, memory: gb(1), disk: gb(10),
                        networkId: nil, networkName: "default", metadataSource: "iso"))
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }

            // One enabled network is sufficient even when another selected
            // network has opted out.
            defaultNetwork.metadataEnabled = true
            try await defaultNetwork.save(on: app.db)
            let disabledNetwork = LogicalNetwork(
                name: "metadata-off", subnet: "10.121.0.0/24", gateway: "10.121.0.1",
                projectID: project.id!, createdByID: user.id!, metadataEnabled: false,
                siteID: defaultNetwork.$site.id)
            try await disabledNetwork.save(on: app.db)
            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateMultiVMBody(
                        name: "imds-mixed-networks", imageId: image.id!, projectId: project.id!,
                        networkInterfaces: [
                            CreateNICBody(networkId: defaultNetwork.id, networkName: nil),
                            CreateNICBody(networkId: disabledNetwork.id, networkName: nil),
                        ],
                        metadataSource: "imds"))
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }
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

    @Test("POST /api/vms persists user data for Firecracker MMDS delivery")
    func createFirecrackerWithUserData() async throws {
        try await withApp { app, _, _, project, image, token in
            try await addFirecrackerArtifacts(to: image, on: app.db)

            let userData = "#cloud-config\npackages: [nginx]\n"
            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateVMBody(
                        name: "fc-userdata-vm", imageId: image.id, projectId: project.id,
                        environment: "development", cpu: 1, memory: gb(1), disk: gb(10),
                        networkId: nil, networkName: "default",
                        userData: userData,
                        hypervisorType: "firecracker"))
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }

            let vm = try await VM.query(on: app.db).filter(\.$name == "fc-userdata-vm").first()
            #expect(vm?.hypervisorType == .firecracker)
            #expect(vm?.userData == userData)
        }
    }

    @Test("POST /api/vms validates Firecracker user data format and size")
    func createFirecrackerValidatesUserData() async throws {
        try await withApp { app, _, _, project, image, token in
            try await addFirecrackerArtifacts(to: image, on: app.db)
            let invalidPayloads = [
                ("fc-userdata-headerless", "echo missing shebang\n"),
                (
                    "fc-userdata-oversized",
                    "#cloud-config\n" + String(repeating: "a", count: CloudInitUserDataFormat.maxBytes)
                ),
            ]

            for (name, userData) in invalidPayloads {
                try await app.test(.POST, "/api/vms") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    try req.content.encode(
                        CreateVMBody(
                            name: name, imageId: image.id, projectId: project.id,
                            environment: "development", cpu: 1, memory: gb(1), disk: gb(10),
                            networkId: nil, networkName: "default",
                            userData: userData,
                            hypervisorType: "firecracker"))
                } afterResponse: { res in
                    #expect(res.status == .badRequest)
                }
                #expect(try await VM.query(on: app.db).filter(\.$name == name).first() == nil)
            }
        }
    }

    @Test("POST /api/vms rejects Firecracker user data without reachable MMDS")
    func createFirecrackerUserDataRequiresReachableMMDS() async throws {
        try await withApp { app, _, _, project, image, token in
            try await addFirecrackerArtifacts(to: image, on: app.db)
            let userData = "#cloud-config\npackages: [nginx]\n"

            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateVMBody(
                        name: "fc-userdata-disabled-vm", imageId: image.id, projectId: project.id,
                        environment: "development", cpu: 1, memory: gb(1), disk: gb(10),
                        networkId: nil, networkName: "default",
                        userData: userData, hypervisorType: "firecracker",
                        metadataEnabled: false))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("metadataEnabled"))
            }

            let defaultNetwork = try #require(
                try await LogicalNetwork.query(on: app.db)
                    .filter(\.$project.$id == project.id!)
                    .filter(\.$name == "default")
                    .first())
            defaultNetwork.metadataEnabled = false
            try await defaultNetwork.save(on: app.db)

            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateVMBody(
                        name: "fc-userdata-disabled-network", imageId: image.id, projectId: project.id,
                        environment: "development", cpu: 1, memory: gb(1), disk: gb(10),
                        networkId: nil, networkName: "default",
                        userData: userData, hypervisorType: "firecracker"))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("at least one selected network"))
            }

            defaultNetwork.metadataEnabled = true
            defaultNetwork.dhcpEnabled = false
            try await defaultNetwork.save(on: app.db)

            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateVMBody(
                        name: "fc-userdata-no-dhcp", imageId: image.id, projectId: project.id,
                        environment: "development", cpu: 1, memory: gb(1), disk: gb(10),
                        networkId: nil, networkName: "default",
                        userData: userData, hypervisorType: "firecracker"))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("DHCP"))
            }

            #expect(
                try await VM.query(on: app.db)
                    .filter(\.$name == "fc-userdata-disabled-vm").first() == nil)
            #expect(
                try await VM.query(on: app.db)
                    .filter(\.$name == "fc-userdata-disabled-network").first() == nil)
            #expect(
                try await VM.query(on: app.db)
                    .filter(\.$name == "fc-userdata-no-dhcp").first() == nil)
        }
    }

    @Test("POST /api/vms rejects IMDS bootstrap for firecracker VMs (400)")
    func createFirecrackerWithIMDSRejected() async throws {
        try await withApp { app, _, _, project, image, token in
            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateVMBody(
                        name: "fc-imds-vm", imageId: image.id, projectId: project.id,
                        environment: "development", cpu: 1, memory: gb(1), disk: gb(10),
                        networkId: nil, networkName: "default",
                        hypervisorType: "firecracker", metadataSource: "imds"))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("metadataSource: imds"))
                #expect(res.body.string.contains("firecracker"))
            }

            let vm = try await VM.query(on: app.db).filter(\.$name == "fc-imds-vm").first()
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
                projectID: project.id!, createdByID: user.id!,
                siteID: try await placementSiteID(for: project, on: app.db))
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
                projectID: otherProject.id!, createdByID: user.id!,
                siteID: try await placementSiteID(for: project, on: app.db))
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
                projectID: project.id!, createdByID: user.id!,
                siteID: try await placementSiteID(for: project, on: app.db))
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
