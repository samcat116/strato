import Fluent
import StratoShared
import Testing
import Vapor
import VaporTesting

@testable import App

/// Tests for the security-group API: default-group invariants, rule
/// validation, the attach/detach lifecycle with its guards (≥1 group per NIC,
/// project match, agent-version gate), delete protection, the VM-create
/// default attachment, and desired-state assembly (scoping, reference
/// closure, old-agent omission).
@Suite("Security Group Controller Tests", .serialized)
final class SecurityGroupControllerTests {

    private func withSecurityGroupTestApp(
        _ test: (Application, User, Organization, Project, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)
            try await app.autoMigrate()

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
        let nic = VMNetworkInterface(
            vmID: vm.id!, network: "default", macAddress: VMNetworkInterface.generateMACAddress())
        try await nic.save(on: app.db)
        if let protocolVersion {
            let message = AgentRegisterMessage(
                agentId: "sg-agent-\(UUID().uuidString.prefix(8))",
                hostname: "sg-host",
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
                message, agentName: message.agentId, organizationScope: .organization(org.id!))
            vm.hypervisorId = agentUUID.uuidString
            try await vm.save(on: app.db)
        }
        return (vm, nic)
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
                let groups = try res.content.decode([SecurityGroupResponse].self)
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
                protocolVersion: WireProtocol.securityGroupsMinimumVersion)
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
                protocolVersion: WireProtocol.securityGroupsMinimumVersion)
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

            // Cross-project attach → 409.
            let builder = TestDataBuilder(db: app.db)
            let otherProject = try await builder.createProject(
                name: "Elsewhere", description: "p", organization: org)
            let foreign = try await SecurityGroupService.ensureDefaultGroup(
                projectID: otherProject.id!, on: app.db)
            try await app.test(.POST, "/api/security-groups/\(foreign.id!)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(AttachSecurityGroupRequest(vmId: vm.id!))
            } afterResponse: { res in
                #expect(res.status == .conflict)
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

    @Test("Attach is refused when the VM's agent predates security groups; unplaced VMs pass")
    func attachVersionGate() async throws {
        try await withSecurityGroupTestApp { app, _, org, project, token in
            let web = try await self.createGroup(app: app, project: project, token: token, name: "web")

            // Placed on a v19 agent → 409.
            let (oldVM, _) = try await self.createVMWithNIC(
                app: app, org: org, project: project,
                protocolVersion: WireProtocol.securityGroupsMinimumVersion - 1)
            try await app.test(.POST, "/api/security-groups/\(web.id)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(AttachSecurityGroupRequest(vmId: oldVM.id!))
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            // Unplaced VM → allowed (the default group must be attachable
            // before scheduling; assembly omits the fields for old agents).
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
                var securityGroupIds: [UUID]? = nil
            }
            let gb = Int64(1) << 30

            // No groups specified → the project default group.
            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateVMBody(
                        name: "sg-default-vm", imageId: image.id, projectId: project.id,
                        cpu: 1, memory: gb, disk: 10 * gb))
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
                        cpu: 1, memory: gb, disk: 10 * gb, securityGroupIds: [web.id]))
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

            // A group from another project → 400, and no VM row is left.
            let otherProject = try await builder.createProject(
                name: "Wrong Project", description: "p", organization: org)
            let foreign = try await SecurityGroupService.ensureDefaultGroup(
                projectID: otherProject.id!, on: app.db)
            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateVMBody(
                        name: "sg-foreign-vm", imageId: image.id, projectId: project.id,
                        cpu: 1, memory: gb, disk: 10 * gb, securityGroupIds: [foreign.id!]))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
            let vm3 = try await VM.query(on: app.db).filter(\.$name == "sg-foreign-vm").first()
            #expect(vm3 == nil)
        }
    }

    // MARK: - Seed migration

    @Test("SeedDefaultSecurityGroups backfills groups, the migration rule, and NIC memberships")
    func seedMigration() async throws {
        try await withSecurityGroupTestApp { app, _, org, project, _ in
            let builder = TestDataBuilder(db: app.db)
            // A pre-security-group world: a project with a workload NIC and a
            // project with none. (Builder-created projects bypass the API, so
            // neither has a default group yet.)
            let emptyProject = try await builder.createProject(
                name: "Empty Project", description: "p", organization: org)
            let (_, nic) = try await self.createVMWithNIC(
                app: app, org: org, project: project, protocolVersion: nil)

            try await SeedDefaultSecurityGroups().prepare(on: app.db)

            // The workload project: AWS rules + the deletable allow-all
            // migration rule (both families), and the NIC joined.
            let seeded = try await SecurityGroup.query(on: app.db)
                .filter(\.$project.$id == project.id!)
                .filter(\.$isDefault == true)
                .with(\.$rules)
                .first()
            #expect(seeded != nil)
            #expect(seeded!.rules.count == 6)
            let migrationRules = seeded!.rules.filter {
                $0.ruleDescription == SeedDefaultSecurityGroups.migrationRuleDescription
            }
            #expect(migrationRules.count == 2)
            #expect(migrationRules.allSatisfy { $0.direction == .ingress && $0.remoteCIDR == nil })
            let joined = try await VMInterfaceSecurityGroup.query(on: app.db)
                .filter(\.$interface.$id == nic.id!)
                .all()
            #expect(joined.map { $0.$securityGroup.id } == [seeded!.id!])

            // The workload-less project: pure AWS posture, no migration rule.
            let emptySeeded = try await SecurityGroup.query(on: app.db)
                .filter(\.$project.$id == emptyProject.id!)
                .filter(\.$isDefault == true)
                .with(\.$rules)
                .first()
            #expect(emptySeeded != nil)
            #expect(emptySeeded!.rules.count == 4)

            // Idempotent: a re-run adds nothing.
            try await SeedDefaultSecurityGroups().prepare(on: app.db)
            let total = try await SecurityGroup.query(on: app.db)
                .filter(\.$project.$id == project.id!)
                .count()
            #expect(total == 1)
        }
    }

    // MARK: - Authorization (deny direction)

    @Test("A user from another organization is denied on every endpoint and sees no foreign groups")
    func crossOrgDenial() async throws {
        try await withSecurityGroupTestApp { app, _, org, project, token in
            let group = try await self.createGroup(app: app, project: project, token: token, name: "private")
            let (vm, _) = try await self.createVMWithNIC(
                app: app, org: org, project: project,
                protocolVersion: WireProtocol.securityGroupsMinimumVersion)

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
                let visible = try res.content.decode([SecurityGroupResponse].self)
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
                protocolVersion: WireProtocol.securityGroupsMinimumVersion)
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

    @Test("Assembly carries groups, the reference closure, and per-NIC ids for v20 agents only")
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
                protocolVersion: WireProtocol.securityGroupsMinimumVersion)
            try await VMInterfaceSecurityGroup(
                interfaceID: nic.id!, securityGroupID: web.id
            ).save(on: app.db)

            let message = try await app.agentService.assembleDesiredState(agentId: vm.hypervisorId!)
            let groups = try #require(message.securityGroups)
            #expect(Set(groups.map(\.id)) == [web.id, db_.id])
            let webDesired = groups.first { $0.id == web.id }
            #expect(webDesired?.generation == 1)
            #expect(webDesired?.rules.count == 1)
            #expect(webDesired?.rules.first?.remoteGroupId == db_.id)
            let nicSpec = try #require(message.vms.first?.spec.networks.first)
            #expect(nicSpec.securityGroupIds == [web.id])

            // A v19 agent gets neither field.
            let (oldVM, oldNIC) = try await self.createVMWithNIC(
                app: app, org: org, project: project,
                protocolVersion: WireProtocol.securityGroupsMinimumVersion - 1)
            try await VMInterfaceSecurityGroup(
                interfaceID: oldNIC.id!, securityGroupID: web.id
            ).save(on: app.db)
            let oldMessage = try await app.agentService.assembleDesiredState(
                agentId: oldVM.hypervisorId!)
            #expect(oldMessage.securityGroups == nil)
            #expect(oldMessage.vms.first?.spec.networks.first?.securityGroupIds == nil)
        }
    }
}
