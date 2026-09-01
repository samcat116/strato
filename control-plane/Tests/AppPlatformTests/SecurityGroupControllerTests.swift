import Fluent
import SQLKit
import StratoShared
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

/// Tests for the security-group API: default-group invariants, rule
/// validation, the attach/detach lifecycle with its guards (≥1 group per NIC,
/// project match, agent-version gate), delete protection, the VM-create
/// default attachment, and desired-state assembly (scoping, reference
/// closure, old-agent omission).
@Suite("Security Group Controller Tests", .serialized)
final class SecurityGroupControllerTests {

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

    private func withSecurityGroupTestApp(
        _ test: (Application, User, Organization, Project, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "sguser",
                email: "sg@example.com",
                displayName: "Security Group User",
                isSystemAdmin: true
            )
            let org = try await builder.createOrganization(name: "SG Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            user.currentOrganizationId = org.id
            try await user.save(on: app.db)

            let project = try await builder.createProject(
                name: "SG Project",
                description: "Project for security group tests",
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

    private func createGroup(
        app: Application, project: Project, token: String, name: String
    ) async throws -> SecurityGroupResponse {
        var created: SecurityGroupResponse?
        try await app.test(.POST, "/api/security-groups") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
            try req.content.encode(
                CreateSecurityGroupRequest(name: name, projectId: project.id!))
        } afterResponse: { res in
            #expect(res.status == .ok)
            created = try res.content.decode(SecurityGroupResponse.self)
        }
        return created!
    }

    /// A project VM with one NIC, placed on an agent speaking `protocolVersion`.
    private func createVMWithNIC(
        app: Application, org: Organization, project: Project, protocolVersion: Int?
    ) async throws -> (VM, VMNetworkInterface) {
        let builder = TestDataBuilder(db: app.db)
        let vm = try await builder.createVM(name: "sg-vm-\(UUID().uuidString.prefix(8))", project: project)
        let network = try await builder.createNetwork(
            name: "sg-net-\(UUID().uuidString.prefix(8))", project: project)
        let nic = VMNetworkInterface(
            vmID: vm.id!, logicalNetworkID: try network.requireID(),
            macAddress: MACAllocator.generateCandidate().description)
        try await nic.save(on: app.db)
        if let protocolVersion {
            let message = AgentRegisterMessage(
                agentId: "sg-agent-\(UUID().uuidString.prefix(8))",
                hostname: "sg-host",
                version: "1.0.0",
                resources: AgentResources(
                    totalCPU: 8, availableCPU: 8,
                    totalMemory: 1 << 33, availableMemory: 1 << 33,
                    totalDisk: 1 << 39, availableDisk: 1 << 39
                ),
                networkCapability: .overlay,
                protocolVersion: protocolVersion,
                dependencyObservations: [Self.healthyOverlayObservation()]
            )
            let agentUUID = try await app.agentService.registerAgent(
                message, agentName: message.agentId, siteID: network.$site.id,
                organizationScope: .organization(org.id!))
            vm.hypervisorId = agentUUID.uuidString
            try await vm.save(on: app.db)
        }
        return (vm, nic)
    }

    /// A project sandbox with one NIC, mirroring `createVMWithNIC`. A nil
    /// `protocolVersion` leaves it unplaced; a version places it on a fresh
    /// agent, which is what lets the assembly tests below reach it (STR-102 —
    /// a sandbox's groups ride the sync even though its NIC spec does not).
    private func createSandboxWithNIC(
        app: Application, org: Organization, project: Project, protocolVersion: Int? = nil,
        sandboxNetworkingCapable: Bool = false
    ) async throws -> (Sandbox, SandboxNetworkInterface) {
        let builder = TestDataBuilder(db: app.db)
        let sandbox = try await builder.createSandbox(
            name: "sg-sbx-\(UUID().uuidString.prefix(8))", project: project)
        let network = try await builder.createNetwork(
            name: "sg-sbx-net-\(UUID().uuidString.prefix(8))", project: project)
        let nic = SandboxNetworkInterface(
            sandboxID: try sandbox.requireID(), logicalNetworkID: try network.requireID(),
            macAddress: MACAllocator.generateCandidate().description)
        try await nic.save(on: app.db)
        if let protocolVersion {
            let message = AgentRegisterMessage(
                agentId: "sg-sbx-agent-\(UUID().uuidString.prefix(8))",
                hostname: "sg-sbx-host",
                version: "1.0.0",
                resources: AgentResources(
                    totalCPU: 8, availableCPU: 8,
                    totalMemory: 1 << 33, availableMemory: 1 << 33,
                    totalDisk: 1 << 39, availableDisk: 1 << 39
                ),
                networkCapability: sandboxNetworkingCapable ? .overlay : nil,
                protocolVersion: protocolVersion,
                sandboxCapable: sandboxNetworkingCapable,
                sandboxNetworkingCapable: sandboxNetworkingCapable,
                dependencyObservations: sandboxNetworkingCapable
                    ? [Self.healthyOverlayObservation()] : []
            )
            let agentUUID = try await app.agentService.registerAgent(
                message, agentName: message.agentId, siteID: network.$site.id,
                organizationScope: .organization(org.id!))
            sandbox.hypervisorId = agentUUID.uuidString
            try await sandbox.save(on: app.db)
        }
        return (sandbox, nic)
    }

    // MARK: - Default group

    @Test("ensureDefaultGroup creates AWS-semantics rules once and is idempotent")
    func defaultGroupProvisioning() async throws {
        try await withSecurityGroupTestApp { app, _, _, project, _ in
            let group = try await SecurityGroupService.ensureDefaultGroup(
                projectID: project.id!, on: app.db)
            #expect(group.isDefault)
            #expect(group.name == SecurityGroup.defaultGroupName)

            let rules = try await SecurityGroupRule.query(on: app.db)
                .filter(\.$securityGroup.$id == group.id!)
                .all()
            // Two families × (ingress-from-self + egress-any), no blanket
            // ingress: fresh projects get the pure AWS posture.
            #expect(rules.count == 4)
            let ingress = rules.filter { $0.direction == .ingress }
            #expect(ingress.count == 2)
            #expect(ingress.allSatisfy { $0.$remoteGroup.id == group.id })
            let egress = rules.filter { $0.direction == .egress }
            #expect(egress.count == 2)
            #expect(egress.allSatisfy { $0.$remoteGroup.id == nil && $0.remoteCIDR == nil })

            let again = try await SecurityGroupService.ensureDefaultGroup(
                projectID: project.id!, on: app.db)
            #expect(again.id == group.id)
            let count = try await SecurityGroup.query(on: app.db)
                .filter(\.$project.$id == project.id!)
                .count()
            #expect(count == 1)
        }
    }

    @Test("The default group cannot be renamed or deleted")
    func defaultGroupImmutability() async throws {
        try await withSecurityGroupTestApp { app, _, _, project, token in
            let group = try await SecurityGroupService.ensureDefaultGroup(
                projectID: project.id!, on: app.db)

            try await app.test(.PUT, "/api/security-groups/\(group.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["name": "renamed"])
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
            try await app.test(.DELETE, "/api/security-groups/\(group.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
            // Its rules stay editable (AWS semantics): deleting one works and
            // bumps the generation.
            let rule = try await SecurityGroupRule.query(on: app.db)
                .filter(\.$securityGroup.$id == group.id!)
                .first()
            try await app.test(.DELETE, "/api/security-groups/\(group.id!)/rules/\(rule!.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }
            let reloaded = try await SecurityGroup.find(group.id, on: app.db)
            #expect(reloaded?.generation == 1)
        }
    }

    // MARK: - CRUD

    @Test("Group CRUD: create, list, update, delete; reserved and duplicate names refused")
    func groupLifecycle() async throws {
        try await withSecurityGroupTestApp { app, _, _, project, token in
            let group = try await self.createGroup(app: app, project: project, token: token, name: "web")
            #expect(group.name == "web")
            #expect(!group.isDefault)
            #expect(group.rules.isEmpty)
            #expect(group.attachmentCount == 0)

            // Reserved name.
            try await app.test(.POST, "/api/security-groups") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateSecurityGroupRequest(name: "default", projectId: project.id!))
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
            // Duplicate name.
            try await app.test(.POST, "/api/security-groups") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateSecurityGroupRequest(name: "web", projectId: project.id!))
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            try await app.test(.GET, "/api/security-groups?project_id=\(project.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let groups = try res.content.decode(PagedResponse<SecurityGroupResponse>.self).items
                #expect(groups.map(\.name) == ["web"])
            }

            try await app.test(.PUT, "/api/security-groups/\(group.id)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["name": "web-tier", "description": "frontends"])
            } afterResponse: { res in
                #expect(res.status == .ok)
                let updated = try res.content.decode(SecurityGroupResponse.self)
                #expect(updated.name == "web-tier")
                #expect(updated.description == "frontends")
            }

            try await app.test(.DELETE, "/api/security-groups/\(group.id)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }
            let remaining = try await SecurityGroup.query(on: app.db)
                .filter(\.$project.$id == project.id!)
                .count()
            #expect(remaining == 0)
        }
    }

    // MARK: - Rules

    @Test("Rule validation rejects malformed peers, ports, and protocols")
    func ruleValidationMatrix() async throws {
        try await withSecurityGroupTestApp { app, _, org, project, token in
            let group = try await self.createGroup(app: app, project: project, token: token, name: "rules")

            // A group in another project, for the cross-project reference case.
            let builder = TestDataBuilder(db: app.db)
            let otherProject = try await builder.createProject(
                name: "Other Project", description: "p", organization: org)
            let foreign = try await SecurityGroupService.ensureDefaultGroup(
                projectID: otherProject.id!, on: app.db)

            let badRules: [CreateSecurityGroupRuleRequest] = [
                // Both peers at once.
                .init(
                    direction: .ingress, ethertype: .ipv4, remoteCIDR: "10.0.0.0/8",
                    remoteGroupId: group.id),
                // Unsupported protocol.
                .init(direction: .ingress, ethertype: .ipv4, protocolName: "sctp"),
                // Ports without a protocol.
                .init(direction: .ingress, ethertype: .ipv4, portRangeMin: 80, portRangeMax: 80),
                // Half a port range.
                .init(direction: .ingress, ethertype: .ipv4, protocolName: "tcp", portRangeMin: 80),
                // Inverted range.
                .init(
                    direction: .ingress, ethertype: .ipv4, protocolName: "tcp",
                    portRangeMin: 90, portRangeMax: 80),
                // Out-of-range port.
                .init(
                    direction: .ingress, ethertype: .ipv4, protocolName: "tcp",
                    portRangeMin: 1, portRangeMax: 70000),
                // ICMP code without a type.
                .init(direction: .ingress, ethertype: .ipv4, protocolName: "icmp", portRangeMax: 0),
                // CIDR family mismatch, both ways.
                .init(direction: .ingress, ethertype: .ipv4, remoteCIDR: "fd00::/64"),
                .init(direction: .ingress, ethertype: .ipv6, remoteCIDR: "10.0.0.0/8"),
                // Garbage CIDR.
                .init(direction: .ingress, ethertype: .ipv4, remoteCIDR: "not-a-cidr"),
                // Cross-project group reference.
                .init(direction: .ingress, ethertype: .ipv4, remoteGroupId: foreign.id!),
            ]
            for body in badRules {
                try await app.test(.POST, "/api/security-groups/\(group.id)/rules") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    try req.content.encode(body)
                } afterResponse: { res in
                    #expect(res.status == .badRequest)
                }
            }

            // Valid rules of each shape land and bump the generation.
            let goodRules: [CreateSecurityGroupRuleRequest] = [
                .init(
                    direction: .ingress, ethertype: .ipv4, protocolName: "tcp",
                    portRangeMin: 443, portRangeMax: 443, remoteCIDR: "0.0.0.0/0"),
                .init(
                    direction: .ingress, ethertype: .ipv6, protocolName: "udp",
                    portRangeMin: 5000, portRangeMax: 6000, remoteCIDR: "fd00::/64"),
                .init(
                    direction: .ingress, ethertype: .ipv4, protocolName: "icmp",
                    portRangeMin: 8, portRangeMax: 0),
                .init(direction: .egress, ethertype: .ipv4),
                .init(direction: .ingress, ethertype: .ipv4, remoteGroupId: group.id),
            ]
            for body in goodRules {
                try await app.test(.POST, "/api/security-groups/\(group.id)/rules") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    try req.content.encode(body)
                } afterResponse: { res in
                    #expect(res.status == .ok)
                }
            }
            let reloaded = try await SecurityGroup.find(group.id, on: app.db)
            #expect(reloaded?.generation == Int64(goodRules.count))
        }
    }

    // MARK: - Delete protection

    @Test("Deleting a group is refused while attached or referenced by another group")
    func deleteGuards() async throws {
        try await withSecurityGroupTestApp { app, _, org, project, token in
            let web = try await self.createGroup(app: app, project: project, token: token, name: "web")
            let app_ = try await self.createGroup(app: app, project: project, token: token, name: "app")

            // app references web (app accepts traffic from web).
            try await app.test(.POST, "/api/security-groups/\(app_.id)/rules") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateSecurityGroupRuleRequest(
                        direction: .ingress, ethertype: .ipv4, protocolName: "tcp",
                        portRangeMin: 5432, portRangeMax: 5432, remoteGroupId: web.id))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }
            try await app.test(.DELETE, "/api/security-groups/\(web.id)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            // Attached group: attach app to a NIC (v20 agent), then delete → 409.
            let (vm, nic) = try await self.createVMWithNIC(
                app: app, org: org, project: project,
                protocolVersion: WireProtocol.currentVersion)
            // Give the NIC a second group so `app` is not load-bearing later.
            let defaultGroup = try await SecurityGroupService.ensureDefaultGroup(
                projectID: project.id!, on: app.db)
            try await VMInterfaceSecurityGroup(
                interfaceID: nic.id!, securityGroupID: defaultGroup.id!
            ).save(on: app.db)
            try await app.test(.POST, "/api/security-groups/\(app_.id)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(AttachSecurityGroupRequest(vmId: vm.id!))
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }
            try await app.test(.DELETE, "/api/security-groups/\(app_.id)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            // A group whose only reference is its own self-rule deletes fine.
            let solo = try await self.createGroup(app: app, project: project, token: token, name: "solo")
            try await app.test(.POST, "/api/security-groups/\(solo.id)/rules") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateSecurityGroupRuleRequest(
                        direction: .ingress, ethertype: .ipv4, remoteGroupId: solo.id))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }
            try await app.test(.DELETE, "/api/security-groups/\(solo.id)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }
        }
    }

    // MARK: - Attach / detach

    @Test("Attach/detach lifecycle: caps, idempotence, ≥1-group invariant, project match")
    func attachDetachLifecycle() async throws {
        try await withSecurityGroupTestApp { app, _, org, project, token in
            let (vm, nic) = try await self.createVMWithNIC(
                app: app, org: org, project: project,
                protocolVersion: WireProtocol.currentVersion)
            let defaultGroup = try await SecurityGroupService.ensureDefaultGroup(
                projectID: project.id!, on: app.db)
            try await VMInterfaceSecurityGroup(
                interfaceID: nic.id!, securityGroupID: defaultGroup.id!
            ).save(on: app.db)

            let web = try await self.createGroup(app: app, project: project, token: token, name: "web")

            // Attach, then an idempotent repeat.
            for _ in 0..<2 {
                try await app.test(.POST, "/api/security-groups/\(web.id)/attach") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    try req.content.encode(AttachSecurityGroupRequest(vmId: vm.id!, interfaceId: nic.id!))
                } afterResponse: { res in
                    #expect(res.status == .noContent)
                }
            }
            let memberships = try await VMInterfaceSecurityGroup.query(on: app.db)
                .filter(\.$interface.$id == nic.id!)
                .count()
            #expect(memberships == 2)

            // Cross-project attach → 400, the one status every cross-project
            // refusal answers with (issue #777); was 409.
            let builder = TestDataBuilder(db: app.db)
            let otherProject = try await builder.createProject(
                name: "Elsewhere", description: "p", organization: org)
            let foreign = try await SecurityGroupService.ensureDefaultGroup(
                projectID: otherProject.id!, on: app.db)
            try await app.test(.POST, "/api/security-groups/\(foreign.id!)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(AttachSecurityGroupRequest(vmId: vm.id!))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            // Detach down to one group; detaching the last is refused.
            try await app.test(.POST, "/api/security-groups/\(web.id)/detach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(AttachSecurityGroupRequest(vmId: vm.id!, interfaceId: nic.id!))
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }
            try await app.test(.POST, "/api/security-groups/\(defaultGroup.id!)/detach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(AttachSecurityGroupRequest(vmId: vm.id!, interfaceId: nic.id!))
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
        }
    }

    @Test("Attach works on an unplaced VM")
    func attachUnplacedVM() async throws {
        try await withSecurityGroupTestApp { app, _, org, project, token in
            let web = try await self.createGroup(app: app, project: project, token: token, name: "web")

            // The default group must be attachable before scheduling, when the
            // VM has no host yet.
            let (unplacedVM, _) = try await self.createVMWithNIC(
                app: app, org: org, project: project, protocolVersion: nil)
            try await app.test(.POST, "/api/security-groups/\(web.id)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(AttachSecurityGroupRequest(vmId: unplacedVM.id!))
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }
        }
    }

    @Test("Attach is refused when the site's network controller cannot author the ACLs")
    func attachControllerAuthorityGate() async throws {
        try await withSecurityGroupTestApp { app, _, org, project, token in
            // The controller authors the ACLs; while it is long offline nothing
            // does, and this used to attach silently and realize nothing
            // (issue #833).
            let web = try await self.createGroup(app: app, project: project, token: token, name: "web")
            let (vm, _) = try await self.createVMWithNIC(
                app: app, org: org, project: project,
                protocolVersion: WireProtocol.currentVersion)

            let site = Site(name: "SG Offline Site", organizationScope: .organization(org.id!))
            try await site.save(on: app.db)
            let host = try #require(try await Agent.find(UUID(uuidString: vm.hypervisorId!), on: app.db))
            host.$site.id = try site.requireID()
            try await host.save(on: app.db)

            let controllerUUID = try await app.agentService.registerAgent(
                AgentRegisterMessage(
                    agentId: "sg-offline-ctl", hostname: "sg-offline-ctl-host", version: "1.0.0",
                    resources: AgentResources(
                        totalCPU: 8, availableCPU: 8, totalMemory: 1 << 33, availableMemory: 1 << 33,
                        totalDisk: 1 << 39, availableDisk: 1 << 39),
                    networkCapability: .overlay, protocolVersion: WireProtocol.currentVersion,
                    dependencyObservations: [Self.healthyOverlayObservation()]),
                agentName: "sg-offline-ctl", siteID: site.id,
                organizationScope: .organization(org.id!))
            let controller = try #require(try await Agent.find(controllerUUID, on: app.db))
            site.$networkControllerAgent.id = controllerUUID
            try await site.save(on: app.db)
            controller.lastHeartbeat = Date().addingTimeInterval(
                -(SiteNetworkAuthority.controllerOfflineGrace + 600))
            try await controller.save(on: app.db)

            try await app.test(.POST, "/api/security-groups/\(web.id)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(AttachSecurityGroupRequest(vmId: vm.id!))
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("sg-offline-ctl"))
            }

            // The same condition reads out of the API as unenforced (STR-34):
            // the gate and the indicator resolve through one code path, so a
            // group already attached before the controller went bad cannot be
            // reported as filtering.
            #expect(try await SecurityGroupService.enforcement(for: vm, on: app.db) == false)
            #expect(try await SecurityGroupService.enforcementByVM([vm], on: app.db)[vm.id!] == false)

            // A heartbeat from the controller unblocks the same attach.
            controller.lastHeartbeat = Date()
            try await controller.save(on: app.db)
            try await app.test(.POST, "/api/security-groups/\(web.id)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(AttachSecurityGroupRequest(vmId: vm.id!))
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }
            #expect(try await SecurityGroupService.enforcement(for: vm, on: app.db) == true)
        }
    }

    // MARK: - VM create

    @Test("POST /api/vms attaches the default group when none specified, explicit groups otherwise")
    func vmCreateAttachesGroups() async throws {
        try await withSecurityGroupTestApp { app, user, org, project, token in
            let builder = TestDataBuilder(db: app.db)
            let image = try await builder.createImage(project: project, uploadedBy: user)
            let web = try await self.createGroup(app: app, project: project, token: token, name: "web")

            struct CreateVMBody: Content {
                let name: String
                let imageId: UUID?
                let projectId: UUID?
                let cpu: Int?
                let memory: Int64?
                let disk: Int64?
                var networkId: UUID? = nil
                var securityGroupIds: [UUID]? = nil
            }
            let gb = Int64(1) << 30
            // VM create names its network explicitly (issue #765).
            let network = try await builder.createNetwork(name: "sg-net", project: project)
            let networkID = try network.requireID()

            // No groups specified → the project default group.
            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateVMBody(
                        name: "sg-default-vm", imageId: image.id, projectId: project.id,
                        cpu: 1, memory: gb, disk: 10 * gb, networkId: networkID))
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }
            let defaultGroup = try await SecurityGroup.query(on: app.db)
                .filter(\.$project.$id == project.id!)
                .filter(\.$isDefault == true)
                .first()
            let vm1 = try await VM.query(on: app.db).filter(\.$name == "sg-default-vm").first()
            let nic1 = try await VMNetworkInterface.query(on: app.db)
                .filter(\.$vm.$id == vm1!.id!)
                .first()
            let groups1 = try await VMInterfaceSecurityGroup.query(on: app.db)
                .filter(\.$interface.$id == nic1!.id!)
                .all()
            #expect(groups1.map { $0.$securityGroup.id } == [defaultGroup!.id!])

            // Explicit group → exactly that group.
            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateVMBody(
                        name: "sg-explicit-vm", imageId: image.id, projectId: project.id,
                        cpu: 1, memory: gb, disk: 10 * gb, networkId: networkID, securityGroupIds: [web.id]))
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }
            let vm2 = try await VM.query(on: app.db).filter(\.$name == "sg-explicit-vm").first()
            let nic2 = try await VMNetworkInterface.query(on: app.db)
                .filter(\.$vm.$id == vm2!.id!)
                .first()
            let groups2 = try await VMInterfaceSecurityGroup.query(on: app.db)
                .filter(\.$interface.$id == nic2!.id!)
                .all()
            #expect(groups2.map { $0.$securityGroup.id } == [web.id])

            // A group from another project is resolved out of existence rather
            // than refused as cross-project (issue #777): nothing authorizes
            // the caller against it, so it answers 404 like an unknown id, and
            // no VM row is left.
            let otherProject = try await builder.createProject(
                name: "Wrong Project", description: "p", organization: org)
            let foreign = try await SecurityGroupService.ensureDefaultGroup(
                projectID: otherProject.id!, on: app.db)
            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateVMBody(
                        name: "sg-foreign-vm", imageId: image.id, projectId: project.id,
                        cpu: 1, memory: gb, disk: 10 * gb, networkId: networkID, securityGroupIds: [foreign.id!]))
            } afterResponse: { res in
                #expect(res.status == .notFound)
            }
            let vm3 = try await VM.query(on: app.db).filter(\.$name == "sg-foreign-vm").first()
            #expect(vm3 == nil)
        }
    }

    // MARK: - Authorization (deny direction)

    @Test("A user from another organization is denied on every endpoint and sees no foreign groups")
    func crossOrgDenial() async throws {
        try await withSecurityGroupTestApp { app, _, org, project, token in
            let group = try await self.createGroup(app: app, project: project, token: token, name: "private")
            let (vm, _) = try await self.createVMWithNIC(
                app: app, org: org, project: project,
                protocolVersion: WireProtocol.currentVersion)

            // A real (non-system-admin) user in a different organization.
            let builder = TestDataBuilder(db: app.db)
            let outsider = try await builder.createUser(
                username: "outsider", email: "outsider@example.com")
            let otherOrg = try await builder.createOrganization(name: "Other Org")
            try await builder.addUserToOrganization(user: outsider, organization: otherOrg, role: "member")
            outsider.currentOrganizationId = otherOrg.id
            try await outsider.save(on: app.db)
            let outsiderToken = try await outsider.generateAPIKey(on: app.db)

            // Every per-resource endpoint denies.
            try await app.test(.GET, "/api/security-groups/\(group.id)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: outsiderToken)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
            try await app.test(.PUT, "/api/security-groups/\(group.id)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: outsiderToken)
                try req.content.encode(["name": "stolen"])
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
            try await app.test(.DELETE, "/api/security-groups/\(group.id)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: outsiderToken)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
            try await app.test(.POST, "/api/security-groups/\(group.id)/rules") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: outsiderToken)
                try req.content.encode(
                    CreateSecurityGroupRuleRequest(direction: .ingress, ethertype: .ipv4))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
            try await app.test(.POST, "/api/security-groups/\(group.id)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: outsiderToken)
                try req.content.encode(AttachSecurityGroupRequest(vmId: vm.id!))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
            // Creating into the foreign project denies too.
            try await app.test(.POST, "/api/security-groups") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: outsiderToken)
                try req.content.encode(
                    CreateSecurityGroupRequest(name: "intruder", projectId: project.id!))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
            // An explicit foreign project filter denies; the unfiltered list
            // scopes to accessible projects and shows none of org A's groups.
            try await app.test(.GET, "/api/security-groups?project_id=\(project.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: outsiderToken)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
            try await app.test(.GET, "/api/security-groups") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: outsiderToken)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let visible = try res.content.decode(PagedResponse<SecurityGroupResponse>.self).items
                #expect(!visible.contains { $0.id == group.id })
            }
        }
    }

    // MARK: - Resource caps

    @Test("Per-NIC, per-group, and per-project caps refuse at the boundary")
    func capBoundaries() async throws {
        try await withSecurityGroupTestApp { app, _, org, project, token in
            // Per-NIC cap: fill the NIC to maxGroupsPerNIC, then one more.
            let (vm, nic) = try await self.createVMWithNIC(
                app: app, org: org, project: project,
                protocolVersion: WireProtocol.currentVersion)
            var groups: [SecurityGroupResponse] = []
            for index in 0...SecurityGroup.maxGroupsPerNIC {
                groups.append(
                    try await self.createGroup(app: app, project: project, token: token, name: "cap-\(index)"))
            }
            for group in groups.prefix(SecurityGroup.maxGroupsPerNIC) {
                try await app.test(.POST, "/api/security-groups/\(group.id)/attach") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    try req.content.encode(AttachSecurityGroupRequest(vmId: vm.id!, interfaceId: nic.id!))
                } afterResponse: { res in
                    #expect(res.status == .noContent)
                }
            }
            try await app.test(.POST, "/api/security-groups/\(groups.last!.id)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(AttachSecurityGroupRequest(vmId: vm.id!, interfaceId: nic.id!))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }

            // Per-group rule cap: fill via direct inserts (fast), then the API.
            let target = groups[0]
            for _ in 0..<(SecurityGroup.maxRulesPerGroup) {
                try await SecurityGroupRule(
                    securityGroupID: target.id, direction: .egress, ethertype: .ipv4
                ).save(on: app.db)
            }
            try await app.test(.POST, "/api/security-groups/\(target.id)/rules") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateSecurityGroupRuleRequest(direction: .ingress, ethertype: .ipv4))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }

            // Per-project cap: fill via direct inserts, then the API.
            let existing = try await SecurityGroup.query(on: app.db)
                .filter(\.$project.$id == project.id!)
                .count()
            for index in 0..<(SecurityGroup.maxGroupsPerProject - existing) {
                try await SecurityGroup(projectID: project.id!, name: "filler-\(index)").save(on: app.db)
            }
            try await app.test(.POST, "/api/security-groups") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateSecurityGroupRequest(name: "one-too-many", projectId: project.id!))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    // MARK: - Desired-state assembly

    @Test("Assembly carries groups, the reference closure, and per-NIC ids")
    func assemblyScoping() async throws {
        try await withSecurityGroupTestApp { app, _, org, project, token in
            let web = try await self.createGroup(app: app, project: project, token: token, name: "web")
            let db_ = try await self.createGroup(app: app, project: project, token: token, name: "db")
            // web's rules reference db, so db must ride the sync even though
            // no in-scope NIC attaches it.
            try await app.test(.POST, "/api/security-groups/\(web.id)/rules") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateSecurityGroupRuleRequest(
                        direction: .egress, ethertype: .ipv4, protocolName: "tcp",
                        portRangeMin: 5432, portRangeMax: 5432, remoteGroupId: db_.id))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            let (vm, nic) = try await self.createVMWithNIC(
                app: app, org: org, project: project,
                protocolVersion: WireProtocol.currentVersion)
            try await attachBootVolume(to: vm, on: vm.hypervisorId!, using: app.db)
            try await VMInterfaceSecurityGroup(
                interfaceID: nic.id!, securityGroupID: web.id
            ).save(on: app.db)

            let message = try await app.desiredStateAssembler.assemble(agentId: vm.hypervisorId!)
            let groups = try #require(message.securityGroups)
            #expect(Set(groups.map(\.id)) == [web.id, db_.id])
            let webDesired = groups.first { $0.id == web.id }
            #expect(webDesired?.generation == 1)
            #expect(webDesired?.rules.count == 1)
            #expect(webDesired?.rules.first?.remoteGroupId == db_.id)
            let nicSpec = try #require(message.vms.first?.spec.networks.first)
            #expect(nicSpec.securityGroupIds == [web.id])
        }
    }

    // MARK: - Per-NIC membership and enforcement in the API (STR-34)

    @Test("VM detail lists each NIC's groups and whether its host enforces them")
    func vmDetailMembershipAndEnforcement() async throws {
        try await withSecurityGroupTestApp { app, _, org, project, token in
            let web = try await self.createGroup(app: app, project: project, token: token, name: "web")
            let defaultGroup = try await SecurityGroupService.ensureDefaultGroup(
                projectID: project.id!, on: app.db)

            // Unplaced: enforcement is unknown, not "no".
            let (unplaced, unplacedNIC) = try await self.createVMWithNIC(
                app: app, org: org, project: project, protocolVersion: nil)
            try await VMInterfaceSecurityGroup(
                interfaceID: unplacedNIC.id!, securityGroupID: try defaultGroup.requireID()
            ).save(on: app.db)
            try await VMInterfaceSecurityGroup(
                interfaceID: unplacedNIC.id!, securityGroupID: web.id
            ).save(on: app.db)

            try await app.test(.GET, "/api/vms/\(unplaced.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let detail = try res.content.decode(VMDetailResponse.self)
                #expect(detail.securityGroupsEnforced == nil)
                let ids = try #require(detail.networkInterfaces.first?.securityGroupIds)
                // Sorted by uuid string, matching the order agents receive.
                #expect(Set(ids) == [try defaultGroup.requireID(), web.id])
                #expect(ids == ids.sorted { $0.uuidString < $1.uuidString })
            }

            let (current, currentNIC) = try await self.createVMWithNIC(
                app: app, org: org, project: project,
                protocolVersion: WireProtocol.currentVersion)
            try await VMInterfaceSecurityGroup(
                interfaceID: currentNIC.id!, securityGroupID: web.id
            ).save(on: app.db)
            try await app.test(.GET, "/api/vms/\(current.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                let detail = try res.content.decode(VMDetailResponse.self)
                #expect(detail.securityGroupsEnforced == true)
            }

            // The list endpoint answers identically, batched.
            try await app.test(.GET, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                let page = try res.content.decode(PagedResponse<VMDetailResponse>.self).items
                let byID = Dictionary(uniqueKeysWithValues: page.compactMap { vm in vm.id.map { ($0, vm) } })
                #expect(byID[unplaced.id!]?.securityGroupsEnforced == nil)
                #expect(byID[current.id!]?.securityGroupsEnforced == true)
                #expect(byID[current.id!]?.networkInterfaces.first?.securityGroupIds == [web.id])
            }
        }
    }

    // MARK: - Per-rule ACL logging (STR-34)

    @Test("A rule's log flag survives create, the response, and desired-state assembly")
    func ruleLoggingRoundTrip() async throws {
        try await withSecurityGroupTestApp { app, _, org, project, token in
            let web = try await self.createGroup(app: app, project: project, token: token, name: "web")

            var logged: SecurityGroupRuleResponse?
            try await app.test(.POST, "/api/security-groups/\(web.id)/rules") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateSecurityGroupRuleRequest(
                        direction: .ingress, ethertype: .ipv4, protocolName: "tcp",
                        portRangeMin: 443, portRangeMax: 443, log: true))
            } afterResponse: { res in
                #expect(res.status == .ok)
                logged = try res.content.decode(SecurityGroupRuleResponse.self)
            }
            #expect(try #require(logged).log)

            // Omitting the field means off, not null: the column is required.
            var quiet: SecurityGroupRuleResponse?
            try await app.test(.POST, "/api/security-groups/\(web.id)/rules") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateSecurityGroupRuleRequest(direction: .egress, ethertype: .ipv4))
            } afterResponse: { res in
                quiet = try res.content.decode(SecurityGroupRuleResponse.self)
            }
            #expect(!(try #require(quiet).log))

            let (vm, nic) = try await self.createVMWithNIC(
                app: app, org: org, project: project,
                protocolVersion: WireProtocol.currentVersion)
            try await attachBootVolume(to: vm, on: vm.hypervisorId!, using: app.db)
            try await VMInterfaceSecurityGroup(
                interfaceID: nic.id!, securityGroupID: web.id
            ).save(on: app.db)

            let message = try await app.desiredStateAssembler.assemble(agentId: vm.hypervisorId!)
            let rules = try #require(message.securityGroups?.first { $0.id == web.id }?.rules)
            #expect(rules.first { $0.id == logged!.id }?.log == true)
            #expect(rules.first { $0.id == quiet!.id }?.log == false)
        }
    }

    // MARK: - Sandbox NIC membership (STR-34)

    @Test("Sandbox NICs attach and detach groups under the same caps and invariants")
    func sandboxAttachDetachLifecycle() async throws {
        try await withSecurityGroupTestApp { app, _, org, project, token in
            let (sandbox, nic) = try await self.createSandboxWithNIC(app: app, org: org, project: project)
            let first = try await self.createGroup(app: app, project: project, token: token, name: "sbx-a")
            let second = try await self.createGroup(app: app, project: project, token: token, name: "sbx-b")

            // An unplaced sandbox attaches regardless of any host gate: the
            // project's default group is attached before scheduling, so the
            // gate can only ask about a host that already exists (STR-103).
            try await app.test(.POST, "/api/security-groups/\(first.id)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    AttachSecurityGroupRequest(sandboxId: try sandbox.requireID()))
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }
            // Idempotent.
            try await app.test(.POST, "/api/security-groups/\(first.id)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    AttachSecurityGroupRequest(sandboxId: try sandbox.requireID()))
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            // The ≥1-group invariant holds for sandboxes too.
            try await app.test(.POST, "/api/security-groups/\(first.id)/detach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    AttachSecurityGroupRequest(sandboxId: try sandbox.requireID()))
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            try await app.test(.POST, "/api/security-groups/\(second.id)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    AttachSecurityGroupRequest(sandboxId: try sandbox.requireID(), interfaceId: nic.id))
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            // Attachment counts and the delete guard span both join tables:
            // counting only VM NICs would report this group as unattached and
            // then hand the caller a bare FK violation.
            try await app.test(.GET, "/api/security-groups/\(first.id)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                let group = try res.content.decode(SecurityGroupResponse.self)
                #expect(group.attachmentCount == 1)
            }
            try await app.test(.DELETE, "/api/security-groups/\(first.id)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            // With a second group present the first detaches.
            try await app.test(.POST, "/api/security-groups/\(first.id)/detach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    AttachSecurityGroupRequest(sandboxId: try sandbox.requireID()))
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }
            let remaining = try await SandboxInterfaceSecurityGroup.query(on: app.db)
                .filter(\.$interface.$id == nic.id!)
                .all()
            #expect(remaining.map { $0.$securityGroup.id } == [second.id])

            try await app.test(.GET, "/api/sandboxes/\(sandbox.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                let detail = try res.content.decode(SandboxDetailResponse.self)
                #expect(detail.securityGroupIds == [second.id])
                // The per-NIC copy agrees, and is nil-vs-empty honest.
                #expect(detail.networkInterfaces.first?.securityGroupIds == [second.id])
                // Unplaced reads as unknown, not unenforced — the same
                // distinction an unplaced VM gets. What the verdict turns on
                // once there *is* a host is that host's sandbox-networking
                // capability (STR-103).
                #expect(detail.securityGroupsEnforced == nil)
            }
        }
    }

    @Test("A sandbox NIC's groups reach the authority, and its membership reaches its host")
    func sandboxGroupsReachTheAuthority() async throws {
        try await withSecurityGroupTestApp { app, _, org, project, token in
            let web = try await self.createGroup(app: app, project: project, token: token, name: "sbx-web")
            let db_ = try await self.createGroup(app: app, project: project, token: token, name: "sbx-db")
            // web's only rule references db, so the transitive closure has to
            // pull db in from a seed that is a *sandbox* NIC.
            try await app.test(.POST, "/api/security-groups/\(web.id)/rules") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateSecurityGroupRuleRequest(
                        direction: .egress, ethertype: .ipv4, protocolName: "tcp",
                        portRangeMin: 5432, portRangeMax: 5432, remoteGroupId: db_.id))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            // Deliberately an agent with *no VMs at all*: the closure's guard
            // used to be "no VM NIC ids, return nothing", which would answer
            // this host with no groups and report nothing about the omission.
            let (sandbox, nic) = try await self.createSandboxWithNIC(
                app: app, org: org, project: project,
                protocolVersion: WireProtocol.currentVersion,
                sandboxNetworkingCapable: true)
            try await SandboxInterfaceSecurityGroup(
                interfaceID: nic.requireID(), securityGroupID: web.id
            ).save(on: app.db)

            let message = try await app.desiredStateAssembler.assemble(
                agentId: try #require(sandbox.hypervisorId))
            let groups = try #require(message.securityGroups)
            #expect(Set(groups.map(\.id)) == [web.id, db_.id])
            #expect(message.vms.isEmpty)
            // Both halves reach a host that can realize the NIC (STR-103): the
            // closure above, and the per-NIC membership inside the spec, so the
            // port joins its groups before the veth goes live.
            #expect(message.sandboxes.count == 1)
            #expect(message.sandboxes.first?.spec.network?.securityGroupIds == [web.id])
        }
    }

    @Test("A sandbox with no NIC reports enforcement as unknown, not unenforced")
    func sandboxWithoutNICHasNoEnforcementVerdict() async throws {
        try await withSecurityGroupTestApp { app, _, _, project, token in
            let builder = TestDataBuilder(db: app.db)
            let sandbox = try await builder.createSandbox(name: "sbx-no-nic", project: project)

            try await app.test(.GET, "/api/sandboxes/\(try sandbox.requireID())") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                let detail = try res.content.decode(SandboxDetailResponse.self)
                #expect(detail.securityGroupsEnforced == nil)
                #expect(detail.securityGroupIds == nil)
                #expect(detail.networkInterfaces.isEmpty)
            }
        }
    }

    /// The capability arm of the sandbox verdict (STR-103), which is asked
    /// before topology authority: on a host that cannot realize a sandbox NIC
    /// there is no port for a port group to contain, whatever its version or
    /// site says. `false`, not nil — the groups are attached and demonstrably
    /// enforce nothing.
    @Test("A sandbox's enforcement verdict follows its host's sandbox-networking capability")
    func sandboxEnforcementFollowsNetworkingCapability() async throws {
        try await withSecurityGroupTestApp { app, _, org, project, token in
            let group = try await self.createGroup(
                app: app, project: project, token: token, name: "sbx-enf")

            let (incapable, incapableNIC) = try await self.createSandboxWithNIC(
                app: app, org: org, project: project,
                protocolVersion: WireProtocol.currentVersion, sandboxNetworkingCapable: false)
            try await SandboxInterfaceSecurityGroup(
                interfaceID: incapableNIC.requireID(), securityGroupID: group.id
            ).save(on: app.db)

            let (capable, capableNIC) = try await self.createSandboxWithNIC(
                app: app, org: org, project: project,
                protocolVersion: WireProtocol.currentVersion, sandboxNetworkingCapable: true)
            try await SandboxInterfaceSecurityGroup(
                interfaceID: capableNIC.requireID(), securityGroupID: group.id
            ).save(on: app.db)

            for (sandbox, expected) in [(incapable, false), (capable, true)] {
                try await app.test(.GET, "/api/sandboxes/\(try sandbox.requireID())") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                } afterResponse: { res in
                    let detail = try res.content.decode(SandboxDetailResponse.self)
                    #expect(detail.securityGroupsEnforced == expected)
                }
            }

            // The list endpoint answers identically, batched — the verdict now
            // reads the host row, so a per-row call would be a query per
            // sandbox (STR-103).
            try await app.test(.GET, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                let page = try res.content.decode(PagedResponse<SandboxDetailResponse>.self).items
                let byID = Dictionary(uniqueKeysWithValues: page.map { ($0.id, $0) })
                #expect(byID[try incapable.requireID()]?.securityGroupsEnforced == false)
                #expect(byID[try capable.requireID()]?.securityGroupsEnforced == true)
            }
        }
    }

    @Test("Attaching a group to a sandbox on a host that cannot realize a NIC is refused")
    func sandboxAttachRefusedOnIncapableHost() async throws {
        try await withSecurityGroupTestApp { app, _, org, project, token in
            let group = try await self.createGroup(
                app: app, project: project, token: token, name: "sbx-attach")

            let (incapable, _) = try await self.createSandboxWithNIC(
                app: app, org: org, project: project,
                protocolVersion: WireProtocol.currentVersion, sandboxNetworkingCapable: false)
            try await app.test(.POST, "/api/security-groups/\(group.id)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["sandboxId": try incapable.requireID().uuidString])
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            let (capable, _) = try await self.createSandboxWithNIC(
                app: app, org: org, project: project,
                protocolVersion: WireProtocol.currentVersion, sandboxNetworkingCapable: true)
            try await app.test(.POST, "/api/security-groups/\(group.id)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["sandboxId": try capable.requireID().uuidString])
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            // An unplaced sandbox always passes: the project's default group is
            // attached in the create transaction, long before scheduling.
            let (unplaced, _) = try await self.createSandboxWithNIC(
                app: app, org: org, project: project, protocolVersion: nil)
            try await app.test(.POST, "/api/security-groups/\(group.id)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["sandboxId": try unplaced.requireID().uuidString])
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }
        }
    }

    /// The placement-keyed half of the enforcement verdict, exercised directly.
    @Test("Realization by hypervisor id distinguishes a placed host from an unplaced one")
    func realizationByHypervisorId() async throws {
        try await withSecurityGroupTestApp { app, _, org, project, _ in
            let (sandbox, _) = try await self.createSandboxWithNIC(
                app: app, org: org, project: project,
                protocolVersion: WireProtocol.currentVersion, sandboxNetworkingCapable: true)
            let placed = try await SecurityGroupService.realization(
                forHypervisorId: sandbox.hypervisorId, on: app.db)
            guard case .realizers(let agents) = placed else {
                Issue.record("expected a placed sandbox to have realizers")
                return
            }
            #expect(!agents.isEmpty)

            // An unplaced sandbox is "unknown", never "unenforced".
            let realization = try await SecurityGroupService.realization(
                forHypervisorId: nil, on: app.db)
            guard case .unplaced = realization else {
                Issue.record("expected an unplaced verdict for a sandbox with no host")
                return
            }
        }
    }

    /// The >=1-group invariant guards a *count*, which no unique index can
    /// hold: without serializing read-guard-delete, two detaches of a NIC's
    /// last two groups each read two, each pass, and the NIC lands on zero.
    /// That state never heals — the assembler omits an empty NIC from its map
    /// entirely, so the spec says `nil`, the agent reads "no opinion", and the
    /// port keeps filtering by groups the control plane no longer records.
    @Test("Concurrent detaches cannot empty a NIC's security groups")
    func concurrentDetachKeepsOneGroup() async throws {
        try await withSecurityGroupTestApp { app, _, org, project, token in
            let (vm, nic) = try await self.createVMWithNIC(
                app: app, org: org, project: project,
                protocolVersion: WireProtocol.currentVersion)

            // Two groups on one NIC: exactly one detach may win.
            let first = try await self.createGroup(app: app, project: project, token: token, name: "race-a")
            let second = try await self.createGroup(app: app, project: project, token: token, name: "race-b")
            for group in [first, second] {
                try await VMInterfaceSecurityGroup(
                    interfaceID: nic.requireID(), securityGroupID: group.id
                ).save(on: app.db)
            }

            let vmID = try vm.requireID()
            let interfaceID = try nic.requireID()
            let statuses = try await withThrowingTaskGroup(of: HTTPStatus.self) { group in
                for target in [first.id, second.id] {
                    group.addTask {
                        var status = HTTPStatus.internalServerError
                        try await app.test(.POST, "/api/security-groups/\(target)/detach") { req in
                            req.headers.bearerAuthorization = BearerAuthorization(token: token)
                            try req.content.encode(
                                AttachSecurityGroupRequest(vmId: vmID, interfaceId: interfaceID))
                        } afterResponse: { res in
                            status = res.status
                        }
                        return status
                    }
                }
                var collected: [HTTPStatus] = []
                for try await status in group { collected.append(status) }
                return collected
            }

            #expect(statuses.filter { $0 == .noContent }.count == 1)
            #expect(statuses.filter { $0 == .conflict }.count == 1)

            let remaining = try await VMInterfaceSecurityGroup.query(on: app.db)
                .filter(\.$interface.$id == interfaceID)
                .count()
            #expect(remaining == 1)
        }
    }

    /// The per-NIC cap has the same read-guard-write shape as detach, and the
    /// same lock covers it.
    @Test("Concurrent attaches cannot exceed the per-NIC group cap")
    func concurrentAttachRespectsCap() async throws {
        try await withSecurityGroupTestApp { app, _, org, project, token in
            let (vm, nic) = try await self.createVMWithNIC(
                app: app, org: org, project: project,
                protocolVersion: WireProtocol.currentVersion)
            let defaultGroup = try await SecurityGroupService.ensureDefaultGroup(
                projectID: project.id!, on: app.db)
            try await VMInterfaceSecurityGroup(
                interfaceID: nic.requireID(), securityGroupID: try defaultGroup.requireID()
            ).save(on: app.db)

            // One seat left under the cap, contested by three attaches.
            var contenders: [UUID] = []
            for index in 0..<(SecurityGroup.maxGroupsPerNIC - 1) {
                let filler = try await self.createGroup(
                    app: app, project: project, token: token, name: "cap-filler-\(index)")
                if index < SecurityGroup.maxGroupsPerNIC - 2 {
                    try await VMInterfaceSecurityGroup(
                        interfaceID: nic.requireID(), securityGroupID: filler.id
                    ).save(on: app.db)
                } else {
                    contenders.append(filler.id)
                }
            }
            for index in 0..<2 {
                let extra = try await self.createGroup(
                    app: app, project: project, token: token, name: "cap-racer-\(index)")
                contenders.append(extra.id)
            }

            let vmID = try vm.requireID()
            let interfaceID = try nic.requireID()
            _ = try await withThrowingTaskGroup(of: HTTPStatus.self) { group in
                for target in contenders {
                    group.addTask {
                        var status = HTTPStatus.internalServerError
                        try await app.test(.POST, "/api/security-groups/\(target)/attach") { req in
                            req.headers.bearerAuthorization = BearerAuthorization(token: token)
                            try req.content.encode(
                                AttachSecurityGroupRequest(vmId: vmID, interfaceId: interfaceID))
                        } afterResponse: { res in
                            status = res.status
                        }
                        return status
                    }
                }
                var collected: [HTTPStatus] = []
                for try await status in group { collected.append(status) }
                return collected
            }

            let total = try await VMInterfaceSecurityGroup.query(on: app.db)
                .filter(\.$interface.$id == interfaceID)
                .count()
            #expect(total == SecurityGroup.maxGroupsPerNIC)
        }
    }

    @Test("Attach/detach refuses a request naming neither workload or both")
    func attachTargetMustBeExactlyOne() async throws {
        try await withSecurityGroupTestApp { app, _, org, project, token in
            let group = try await self.createGroup(app: app, project: project, token: token, name: "either")
            let (vm, _) = try await self.createVMWithNIC(
                app: app, org: org, project: project, protocolVersion: nil)
            let (sandbox, _) = try await self.createSandboxWithNIC(app: app, org: org, project: project)

            try await app.test(.POST, "/api/security-groups/\(group.id)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(AttachSecurityGroupRequest())
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
            try await app.test(.POST, "/api/security-groups/\(group.id)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    AttachSecurityGroupRequest(vmId: vm.id!, sandboxId: try sandbox.requireID()))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("Sandbox create attaches the project default, or exactly the groups asked for")
    func sandboxCreateAttachesGroups() async throws {
        try await withSecurityGroupTestApp { app, _, _, project, token in
            let builder = TestDataBuilder(db: app.db)
            let network = try await builder.createNetwork(name: "sbx-create-net", project: project)
            let explicit = try await self.createGroup(
                app: app, project: project, token: token, name: "sbx-explicit")

            func groupIDs(ofSandbox id: UUID) async throws -> [UUID] {
                let nics = try await SandboxNetworkInterface.query(on: app.db)
                    .filter(\.$sandbox.$id == id)
                    .all()
                guard let nic = nics.first else { return [] }
                return try await SandboxInterfaceSecurityGroup.query(on: app.db)
                    .filter(\.$interface.$id == nic.requireID())
                    .all()
                    .map { $0.$securityGroup.id }
            }

            var defaulted: AcceptedMutation<SandboxDetailResponse>?
            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "name": "sbx-default-groups",
                    "image": "ghcr.io/acme/worker:v3",
                    "projectId": project.id!.uuidString,
                    "networkId": try network.requireID().uuidString,
                ])
            } afterResponse: { res in
                #expect(res.status == .accepted)
                defaulted = try res.content.decode(AcceptedMutation<SandboxDetailResponse>.self)
            }
            let defaultGroup = try await SecurityGroupService.ensureDefaultGroup(
                projectID: project.id!, on: app.db)
            #expect(
                try await groupIDs(ofSandbox: try #require(defaulted?.resource.id)) == [
                    try defaultGroup.requireID()
                ])

            var chosen: AcceptedMutation<SandboxDetailResponse>?
            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    SandboxCreateWithGroups(
                        name: "sbx-explicit-groups",
                        image: "ghcr.io/acme/worker:v3",
                        projectId: project.id!,
                        networkId: try network.requireID(),
                        securityGroupIds: [explicit.id]))
            } afterResponse: { res in
                #expect(res.status == .accepted)
                chosen = try res.content.decode(AcceptedMutation<SandboxDetailResponse>.self)
            }
            #expect(try await groupIDs(ofSandbox: try #require(chosen?.resource.id)) == [explicit.id])

            // Naming groups with no network has nothing to attach them to.
            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    SandboxCreateWithGroups(
                        name: "sbx-no-network",
                        image: "ghcr.io/acme/worker:v3",
                        projectId: project.id!,
                        networkId: nil,
                        securityGroupIds: [explicit.id]))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            // A sandbox with no network gets no NIC and so no memberships.
            var networkless: AcceptedMutation<SandboxDetailResponse>?
            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "name": "sbx-networkless",
                    "image": "ghcr.io/acme/worker:v3",
                    "projectId": project.id!.uuidString,
                ])
            } afterResponse: { res in
                #expect(res.status == .accepted)
                networkless = try res.content.decode(AcceptedMutation<SandboxDetailResponse>.self)
            }
            #expect(try await groupIDs(ofSandbox: try #require(networkless?.resource.id)).isEmpty)
        }
    }
}

/// The sandbox create body is declared inside the controller's handler, so the
/// tests carry their own encodable mirror of the fields they exercise.
private struct SandboxCreateWithGroups: Content {
    let name: String
    let image: String
    let projectId: UUID
    let networkId: UUID?
    let securityGroupIds: [UUID]
}
