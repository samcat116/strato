import Fluent
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

@Suite("Load Balancer Controller Tests", .serialized)
final class LoadBalancerControllerTests {
    private func withLoadBalancerTestApp(
        _ test: (Application, Organization, Project, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "lbuser",
                email: "lb@example.com",
                displayName: "Load Balancer User",
                isSystemAdmin: true)
            let organization = try await builder.createOrganization(name: "LB Org")
            try await builder.addUserToOrganization(
                user: user, organization: organization, role: "admin")
            user.currentOrganizationId = try organization.requireID()
            try await user.save(on: app.db)
            let project = try await builder.createProject(
                name: "LB Project",
                description: "Project for load-balancer tests",
                organization: organization)
            let token = try await user.generateAPIKey(on: app.db)

            try await test(app, organization, project, token)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    @Test("A VM backend must use a network pinned to the load balancer site")
    func rejectsCrossSiteBackend() async throws {
        try await withLoadBalancerTestApp { app, organization, project, token in
            let projectID = try project.requireID()
            let organizationID = try organization.requireID()
            let siteA = Site(
                name: "site-a", organizationScope: .organization(organizationID))
            let siteB = Site(
                name: "site-b", organizationScope: .organization(organizationID))
            try await siteA.save(on: app.db)
            try await siteB.save(on: app.db)

            let vipNetwork = LogicalNetwork(
                name: "vip-network",
                subnet: "10.10.0.0/24",
                gateway: "10.10.0.1",
                projectID: projectID,
                siteID: try siteA.requireID())
            let remoteBackendNetwork = LogicalNetwork(
                name: "remote-backends",
                subnet: "10.20.0.0/24",
                gateway: "10.20.0.1",
                projectID: projectID,
                siteID: try siteB.requireID())
            try await vipNetwork.save(on: app.db)
            try await remoteBackendNetwork.save(on: app.db)

            let loadBalancer = LoadBalancer(
                name: "api",
                projectID: projectID,
                logicalNetworkID: try vipNetwork.requireID(),
                vip: "10.10.0.10",
                protocolName: .tcp)
            try await loadBalancer.save(on: app.db)

            let vm = try await TestDataBuilder(db: app.db).createVM(
                name: "remote-backend", project: project)
            let nic = VMNetworkInterface(
                vmID: try vm.requireID(),
                logicalNetworkID: try remoteBackendNetwork.requireID(),
                macAddress: VMNetworkInterface.generateMACAddress())
            try await nic.save(on: app.db)
            try await VMInterfaceAddress(
                interfaceID: try nic.requireID(),
                logicalNetworkID: try remoteBackendNetwork.requireID(),
                family: .ipv4,
                address: "10.20.0.20",
                prefixLength: 24,
                gateway: remoteBackendNetwork.gateway
            ).save(on: app.db)

            try await app.test(
                .POST,
                "/api/load-balancers/\(try loadBalancer.requireID())/backends"
            ) { request in
                request.headers.bearerAuthorization = BearerAuthorization(token: token)
                try request.content.encode(
                    CreateLoadBalancerBackendRequest(
                        vmId: try vm.requireID(), nicIndex: 0, ipAddress: nil))
            } afterResponse: { response in
                #expect(response.status == .conflict)
                let body = response.body.string
                #expect(body.contains("pinned to a different site"))
            }

            #expect(try await LoadBalancerBackend.query(on: app.db).count() == 0)
            let unchanged = try #require(
                try await LoadBalancer.find(try loadBalancer.requireID(), on: app.db))
            #expect(unchanged.generation == 1)
        }
    }
}
