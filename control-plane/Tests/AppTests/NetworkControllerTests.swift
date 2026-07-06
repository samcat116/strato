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
            try await builder.addUserToOrganization(user: user, organization: org, role: "member")
            user.currentOrganizationId = org.id
            try await user.save(on: app.db)

            let project = try await builder.createProject(
                name: "Network Project",
                description: "Project for network tests",
                organization: org
            )
            let token = try await user.generateAPIKey(on: app.db)

            try await test(app, user, project, token)

            try await app.autoRevert()
        } catch {
            try? await app.autoRevert()
            try await app.asyncShutdown()
            app.cleanupTestDatabase()
            throw error
        }

        try await app.asyncShutdown()
        app.cleanupTestDatabase()
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

    @Test("GET /api/networks?project_id denied when project read is withheld (403)")
    func listDeniedForInaccessibleProject() async throws {
        try await withNetworkTestApp { app, _, project, token in
            app.spicedbMockAllows = true
            app.spicedbMockDeniedResources = ["project"]

            try await app.test(.GET, "/api/networks?project_id=\(project.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
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
        try await withNetworkTestApp { app, _, project, token in
            app.spicedbMockAllows = true
            app.spicedbMockDeniedResources = ["project"]

            try await app.test(.POST, "/api/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
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
