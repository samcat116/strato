import Fluent
import StratoShared
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

@Suite("Network ACL Controller Tests", .serialized)
final class NetworkACLControllerTests {
    private static func healthyOverlayObservation(at checkedAt: Date = Date())
        -> NodeDependencyObservation
    {
        NodeDependencyObservation(
            id: .ovnOvs,
            role: .networking,
            desiredState: .required,
            ownership: .observeOnly,
            supervisorState: .active,
            compatibility: .compatible,
            functionalState: .healthy,
            checkedAt: checkedAt,
            lastHealthyAt: checkedAt,
            affectedCapabilities: [.overlayNetworking])
    }

    private func withACLTestApp(
        _ test: (Application, User, Organization, Project, LogicalNetwork, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "nacl-user", email: "nacl@example.com", isSystemAdmin: false)
            let organization = try await builder.createOrganization(name: "NACL Organization")
            try await builder.addUserToOrganization(
                user: user, organization: organization, role: "admin")
            user.currentOrganizationId = try organization.requireID()
            try await user.save(on: app.db)
            let project = try await builder.createProject(
                name: "NACL Project", description: "Network ACL tests",
                organization: organization)
            let network = try await builder.createNetwork(
                name: "nacl-network", project: project,
                subnet: "10.42.0.0/24", gateway: "10.42.0.1")
            let token = try await user.generateAPIKey(on: app.db)

            try await test(app, user, organization, project, network, token)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    private func createACL(
        app: Application, networkID: UUID, token: String
    ) async throws -> NetworkACLResponse {
        var result: NetworkACLResponse?
        try await app.test(.POST, "/api/networks/\(networkID)/acl") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
        } afterResponse: { response in
            #expect(response.status == .ok)
            result = try response.content.decode(NetworkACLResponse.self)
        }
        return try #require(result)
    }

    private func createRule(
        _ body: CreateNetworkACLRuleRequest,
        app: Application,
        networkID: UUID,
        token: String
    ) async throws -> NetworkACLRuleResponse {
        var result: NetworkACLRuleResponse?
        try await app.test(.POST, "/api/networks/\(networkID)/acl/rules") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
            try req.content.encode(body)
        } afterResponse: { response in
            #expect(response.status == .ok)
            result = try response.content.decode(NetworkACLRuleResponse.self)
        }
        return try #require(result)
    }

    @Test("ACL and immutable-rule lifecycle advances both replay guards")
    func lifecycleAndGenerations() async throws {
        try await withACLTestApp { app, _, _, _, network, token in
            let networkID = try network.requireID()
            let initialNetworkGeneration = network.generation

            try await app.test(.GET, "/api/networks/\(networkID)/acl") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { response in
                #expect(response.status == .notFound)
            }

            let created = try await self.createACL(
                app: app, networkID: networkID, token: token)
            #expect(created.networkId == networkID)
            #expect(created.generation == 1)
            #expect(created.rules.isEmpty)
            #expect(
                try await LogicalNetwork.find(networkID, on: app.db)?.generation
                    == initialNetworkGeneration + 1)

            try await app.test(.POST, "/api/networks/\(networkID)/acl") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { response in
                #expect(response.status == .conflict)
            }

            let ingress = try await self.createRule(
                .init(
                    ruleNumber: 100, direction: .ingress, ethertype: .ipv4,
                    action: .deny, protocolName: "TCP", portRangeMin: 443,
                    portRangeMax: 443, remoteCIDR: "10.0.0.0/8"),
                app: app, networkID: networkID, token: token)
            #expect(ingress.protocolName == "tcp")

            // Rule numbers are independent between ingress and egress.
            let egress = try await self.createRule(
                .init(
                    ruleNumber: 100, direction: .egress, ethertype: .ipv6,
                    action: .allow, remoteCIDR: "::/0"),
                app: app, networkID: networkID, token: token)
            #expect(egress.direction == .egress)

            try await app.test(.POST, "/api/networks/\(networkID)/acl/rules") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateNetworkACLRuleRequest(
                        ruleNumber: 100, direction: .ingress, ethertype: .ipv4,
                        action: .allow, remoteCIDR: "0.0.0.0/0"))
            } afterResponse: { response in
                #expect(response.status == .conflict)
            }

            var reloadedACL = try #require(try await NetworkACL.find(created.id, on: app.db))
            #expect(reloadedACL.generation == 3)
            #expect(
                try await LogicalNetwork.find(networkID, on: app.db)?.generation
                    == initialNetworkGeneration + 3)

            try await app.test(
                .DELETE, "/api/networks/\(networkID)/acl/rules/\(ingress.id)"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { response in
                #expect(response.status == .noContent)
            }
            reloadedACL = try #require(try await NetworkACL.find(created.id, on: app.db))
            #expect(reloadedACL.generation == 4)

            try await app.test(.GET, "/api/networks/\(networkID)/acl") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { response in
                #expect(response.status == .ok)
                let body = try response.content.decode(NetworkACLResponse.self)
                #expect(body.rules.map(\.id) == [egress.id])
            }

            try await app.test(.DELETE, "/api/networks/\(networkID)/acl") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { response in
                #expect(response.status == .noContent)
            }
            #expect(try await NetworkACL.find(created.id, on: app.db) == nil)
            #expect(try await NetworkACLRule.query(on: app.db).count() == 0)
            #expect(
                try await LogicalNetwork.find(networkID, on: app.db)?.generation
                    == initialNetworkGeneration + 5)
        }
    }

    @Test("Rule validation rejects malformed ordering, protocols, ports, and CIDR families")
    func ruleValidation() async throws {
        try await withACLTestApp { app, _, _, _, network, token in
            let networkID = try network.requireID()
            let acl = try await self.createACL(app: app, networkID: networkID, token: token)
            let networkGeneration = try #require(
                try await LogicalNetwork.find(networkID, on: app.db)?.generation)

            let invalid: [CreateNetworkACLRuleRequest] = [
                .init(
                    ruleNumber: 0, direction: .ingress, ethertype: .ipv4,
                    action: .allow, remoteCIDR: "0.0.0.0/0"),
                .init(
                    ruleNumber: 32_767, direction: .ingress, ethertype: .ipv4,
                    action: .allow, remoteCIDR: "0.0.0.0/0"),
                .init(
                    ruleNumber: 1, direction: .ingress, ethertype: .ipv4,
                    action: .allow, protocolName: "sctp", remoteCIDR: "0.0.0.0/0"),
                .init(
                    ruleNumber: 2, direction: .ingress, ethertype: .ipv4,
                    action: .allow, portRangeMin: 80, portRangeMax: 80,
                    remoteCIDR: "0.0.0.0/0"),
                .init(
                    ruleNumber: 3, direction: .ingress, ethertype: .ipv4,
                    action: .allow, protocolName: "tcp", portRangeMin: 80,
                    remoteCIDR: "0.0.0.0/0"),
                .init(
                    ruleNumber: 4, direction: .ingress, ethertype: .ipv4,
                    action: .allow, protocolName: "udp", portRangeMin: 90,
                    portRangeMax: 80, remoteCIDR: "0.0.0.0/0"),
                .init(
                    ruleNumber: 5, direction: .ingress, ethertype: .ipv4,
                    action: .allow, protocolName: "tcp", portRangeMin: 1,
                    portRangeMax: 70_000, remoteCIDR: "0.0.0.0/0"),
                .init(
                    ruleNumber: 6, direction: .ingress, ethertype: .ipv4,
                    action: .allow, protocolName: "icmp", portRangeMax: 0,
                    remoteCIDR: "0.0.0.0/0"),
                .init(
                    ruleNumber: 7, direction: .ingress, ethertype: .ipv4,
                    action: .allow, remoteCIDR: "fd00::/64"),
                .init(
                    ruleNumber: 8, direction: .ingress, ethertype: .ipv6,
                    action: .allow, remoteCIDR: "10.0.0.0/8"),
                .init(
                    ruleNumber: 9, direction: .ingress, ethertype: .ipv4,
                    action: .allow, remoteCIDR: "not-a-cidr"),
                .init(
                    ruleNumber: 10, direction: .ingress, ethertype: .ipv4,
                    action: .allow, remoteCIDR: "0.0.0.0/0",
                    description: String(repeating: "x", count: Validate.textLength + 1)),
            ]

            for body in invalid {
                try await app.test(.POST, "/api/networks/\(networkID)/acl/rules") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    try req.content.encode(body)
                } afterResponse: { response in
                    #expect(response.status == .badRequest)
                }
            }

            #expect(try await NetworkACLRule.query(on: app.db).count() == 0)
            #expect(try await NetworkACL.find(acl.id, on: app.db)?.generation == 1)
            #expect(
                try await LogicalNetwork.find(networkID, on: app.db)?.generation
                    == networkGeneration)
        }
    }

    @Test("CIDRs are canonicalized before persistence")
    func cidrCanonicalization() async throws {
        try await withACLTestApp { app, _, _, _, network, token in
            let networkID = try network.requireID()
            _ = try await self.createACL(app: app, networkID: networkID, token: token)

            let cases: [(number: Int, ethertype: NetworkACLRule.Ethertype, input: String, expected: String)] = [
                (1, .ipv4, "10.0.0.1/8/", "10.0.0.0/8"),
                (2, .ipv6, "2001:0DB8::1//64", "2001:db8::/64"),
            ]

            for testCase in cases {
                try await app.test(.POST, "/api/networks/\(networkID)/acl/rules") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    try req.content.encode(
                        CreateNetworkACLRuleRequest(
                            ruleNumber: testCase.number,
                            direction: .ingress,
                            ethertype: testCase.ethertype,
                            action: .allow,
                            remoteCIDR: testCase.input))
                } afterResponse: { response in
                    #expect(response.status == .ok)
                    let body = try response.content.decode(NetworkACLRuleResponse.self)
                    #expect(body.remoteCIDR == testCase.expected)
                }
            }

            let stored = try await NetworkACLRule.query(on: app.db)
                .sort(\.$ruleNumber)
                .all()
            #expect(stored.map(\.remoteCIDR) == cases.map(\.expected))
        }
    }

    @Test("Read and mutation authorization inherit the owning network")
    func authorization() async throws {
        try await withACLTestApp { app, _, organization, project, network, token in
            let networkID = try network.requireID()
            _ = try await self.createACL(app: app, networkID: networkID, token: token)

            let builder = TestDataBuilder(db: app.db)
            let viewer = try await builder.createUser(
                username: "nacl-viewer", email: "nacl-viewer@example.com")
            try await builder.addUserToOrganization(
                user: viewer, organization: organization, role: "member")
            viewer.currentOrganizationId = try organization.requireID()
            try await viewer.save(on: app.db)
            try await RoleBindingService.grant(
                principalType: .user, principalID: try viewer.requireID(), role: .viewer,
                nodeType: .project, nodeID: try project.requireID(), createdBy: nil,
                on: app.db)
            let viewerToken = try await viewer.generateAPIKey(on: app.db)

            try await app.test(.GET, "/api/networks/\(networkID)/acl") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: viewerToken)
            } afterResponse: { response in
                #expect(response.status == .ok)
            }
            try await app.test(.DELETE, "/api/networks/\(networkID)/acl") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: viewerToken)
            } afterResponse: { response in
                #expect(response.status == .forbidden)
            }

            let outsider = try await builder.createUser(
                username: "nacl-outsider", email: "nacl-outsider@example.com")
            let otherOrganization = try await builder.createOrganization(name: "Other NACL Organization")
            try await builder.addUserToOrganization(
                user: outsider, organization: otherOrganization, role: "admin")
            outsider.currentOrganizationId = try otherOrganization.requireID()
            try await outsider.save(on: app.db)
            let outsiderToken = try await outsider.generateAPIKey(on: app.db)

            for method in [HTTPMethod.GET, .POST, .DELETE] {
                try await app.test(method, "/api/networks/\(networkID)/acl") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: outsiderToken)
                } afterResponse: { response in
                    #expect(response.status == .forbidden)
                }
            }
        }
    }

    @Test("Concurrent rule creates serialize generation increments")
    func concurrentRuleCreates() async throws {
        try await withACLTestApp { app, _, _, _, network, token in
            let networkID = try network.requireID()
            let acl = try await self.createACL(app: app, networkID: networkID, token: token)
            let networkGeneration = try #require(
                try await LogicalNetwork.find(networkID, on: app.db)?.generation)

            let statuses = try await withThrowingTaskGroup(of: HTTPStatus.self) { group in
                for number in [10, 20] {
                    group.addTask {
                        var status = HTTPStatus.internalServerError
                        try await app.test(.POST, "/api/networks/\(networkID)/acl/rules") { req in
                            req.headers.bearerAuthorization = BearerAuthorization(token: token)
                            try req.content.encode(
                                CreateNetworkACLRuleRequest(
                                    ruleNumber: number, direction: .ingress,
                                    ethertype: .ipv4, action: .allow,
                                    remoteCIDR: "0.0.0.0/0"))
                        } afterResponse: { response in
                            status = response.status
                        }
                        return status
                    }
                }
                var result: [HTTPStatus] = []
                for try await status in group { result.append(status) }
                return result
            }

            #expect(statuses.allSatisfy { $0 == .ok })
            #expect(try await NetworkACL.find(acl.id, on: app.db)?.generation == 3)
            #expect(
                try await LogicalNetwork.find(networkID, on: app.db)?.generation
                    == networkGeneration + 2)
            #expect(try await NetworkACLRule.query(on: app.db).count() == 2)
        }
    }

    @Test("The per-ACL rule cap is enforced at the boundary")
    func ruleCap() async throws {
        try await withACLTestApp { app, _, _, _, network, token in
            let networkID = try network.requireID()
            let acl = try await self.createACL(app: app, networkID: networkID, token: token)
            for index in 1...NetworkACL.maxRules {
                try await NetworkACLRule(
                    networkACLID: acl.id,
                    ruleNumber: index,
                    direction: .ingress,
                    ethertype: .ipv4,
                    action: .allow,
                    remoteCIDR: "0.0.0.0/0"
                ).save(on: app.db)
            }

            try await app.test(.POST, "/api/networks/\(networkID)/acl/rules") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateNetworkACLRuleRequest(
                        ruleNumber: NetworkACL.maxRules + 1,
                        direction: .egress, ethertype: .ipv4,
                        action: .deny, remoteCIDR: "0.0.0.0/0"))
            } afterResponse: { response in
                #expect(response.status == .forbidden)
            }
            #expect(try await NetworkACLRule.query(on: app.db).count() == NetworkACL.maxRules)
        }
    }

    @Test("Authoritative desired networks carry one ordered ACL or explicit empty teardown")
    func desiredStateAssembly() async throws {
        try await withACLTestApp { app, _, organization, project, network, _ in
            let builder = TestDataBuilder(db: app.db)
            let site = try #require(try await Site.find(network.$site.id, on: app.db))
            let networkID = try network.requireID()
            let noACL = try await builder.createNetwork(
                name: "no-acl", project: project, subnet: "10.43.0.0/24",
                gateway: "10.43.0.1", site: site)
            let acl = NetworkACL(logicalNetworkID: networkID)
            try await acl.save(on: app.db)
            let aclID = try acl.requireID()

            let rules: [NetworkACLRule] = [
                .init(
                    networkACLID: aclID, ruleNumber: 20, direction: .egress,
                    ethertype: .ipv4, action: .deny, remoteCIDR: "0.0.0.0/0"),
                .init(
                    networkACLID: aclID, ruleNumber: 200, direction: .ingress,
                    ethertype: .ipv6, action: .allow, remoteCIDR: "::/0"),
                .init(
                    networkACLID: aclID, ruleNumber: 10, direction: .ingress,
                    ethertype: .ipv4, action: .deny, protocolName: "tcp",
                    portRangeMin: 22, portRangeMax: 22, remoteCIDR: "10.0.0.0/8"),
            ]
            for rule in rules { try await rule.save(on: app.db) }

            let registration = AgentRegisterMessage(
                agentId: "nacl-controller", hostname: "nacl-controller", version: "1.0.0",
                resources: AgentResources(
                    totalCPU: 8, availableCPU: 8,
                    totalMemory: 1 << 33, availableMemory: 1 << 33,
                    totalDisk: 1 << 39, availableDisk: 1 << 39),
                networkCapability: .overlay,
                protocolVersion: WireProtocol.currentVersion,
                dependencyObservations: [Self.healthyOverlayObservation()])
            let agentID = try await app.agentService.registerAgent(
                registration, agentName: "nacl-controller", siteID: try site.requireID(),
                organizationScope: .organization(try organization.requireID()))
            site.$networkControllerAgent.id = agentID
            try await site.save(on: app.db)

            let message = try await app.desiredStateAssembler.assemble(
                agentId: agentID.uuidString)
            #expect(message.networksAuthoritative)
            let byID = Dictionary(uniqueKeysWithValues: message.networks.map { ($0.networkId, $0) })
            let desiredACLs = try #require(byID[networkID]?.networkACLs)
            #expect(desiredACLs.count == 1)
            #expect(desiredACLs.first?.id == aclID)
            #expect(desiredACLs.first?.generation == 1)
            #expect(
                desiredACLs.first?.rules.map { "\($0.direction):\($0.ruleNumber)" }
                    == ["ingress:10", "ingress:200", "egress:20"])
            #expect(byID[try noACL.requireID()]?.networkACLs == [])
        }
    }
}
