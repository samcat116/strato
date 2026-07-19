import Fluent
import Testing
import Vapor
import VaporTesting

@testable import App

/// IAM phase 1 (issue #478): the who-can reverse lookup and the
/// arbitrary-principal form of `can-i`, both served from `role_bindings` plus
/// the resource tree rather than from the policy engine.
@Suite("IAM Who-Can Tests", .serialized)
final class IAMWhoCanTests {

    private func withApp(_ test: (Application) async throws -> Void) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()
            try await test(app)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    /// Org → OU → child OU → project → VM, the deepest legal chain.
    private struct Tree {
        let org: Organization
        let ou: OrganizationalUnit
        let childOU: OrganizationalUnit
        let project: Project
        let vm: VM
        var vmNode: IAMNode { IAMNode(type: .virtualMachine, id: vm.id!) }
    }

    private func buildTree(_ builder: TestDataBuilder, prefix: String) async throws -> Tree {
        let org = try await builder.createOrganization(name: "\(prefix) Org")
        let ou = try await builder.createOU(name: "\(prefix) OU", description: "d", organization: org)
        let childOU = try await builder.createOU(
            name: "\(prefix) Child OU", description: "d", organization: org, parentOU: ou)
        let project = try await builder.createProject(name: "\(prefix) Project", description: "d", ou: childOU)
        let vm = try await builder.createVM(name: "\(prefix)-vm", project: project)
        return Tree(org: org, ou: ou, childOU: childOU, project: project, vm: vm)
    }

    // MARK: - Ancestor walk

    @Test("Ancestor walk climbs resource → project → nested OUs → org")
    func ancestorWalk() async throws {
        try await withApp { app in
            let tree = try await buildTree(TestDataBuilder(db: app.db), prefix: "Walk")

            let chain = try await IAMResourceTree.ancestors(of: tree.vmNode, on: app.db)

            let expected = [
                IAMNode(type: .virtualMachine, id: tree.vm.id!),
                IAMNode(type: .project, id: tree.project.id!),
                IAMNode(type: .organizationalUnit, id: tree.childOU.id!),
                IAMNode(type: .organizationalUnit, id: tree.ou.id!),
                IAMNode(type: .organization, id: tree.org.id!),
            ]
            #expect(chain == expected)
        }
    }

    @Test("A dangling node ends the chain instead of throwing")
    func ancestorWalkDanglingNode() async throws {
        try await withApp { app in
            let orphan = IAMNode(type: .virtualMachine, id: UUID())
            let chain = try await IAMResourceTree.ancestors(of: orphan, on: app.db)
            // Truncation can only under-report access, never invent it.
            #expect(chain == [orphan])
        }
    }

    // MARK: - Reverse lookup

    @Test("A binding above the resource grants through the whole chain")
    func inheritedBindingReachesResource() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "Inherit")
            let user = try await builder.createUser(username: "inh", email: "inh@example.com")

            // Granted at the outer OU, two levels above the project.
            try await RoleBindingService.grant(
                principalType: .user, principalID: user.id!, role: .operator,
                nodeType: .organizationalUnit, nodeID: tree.ou.id!, createdBy: nil, on: app.db)

            let entries = try await WhoCanService.whoCan(action: "vm:start", node: tree.vmNode, on: app.db).principals

            let match = entries.first { $0.principal.id == user.id! }
            #expect(match?.source == .binding)
            #expect(match?.role == IAMRole.operator.rawValue)
            #expect(match?.grantedOn == IAMNode(type: .organizationalUnit, id: tree.ou.id!))
            #expect(match?.via == nil)
        }
    }

    @Test("Role nesting: an admin binding answers a viewer-level action")
    func roleNestingGrantsLowerActions() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "Nest")
            let user = try await builder.createUser(username: "nest", email: "nest@example.com")

            try await RoleBindingService.grant(
                principalType: .user, principalID: user.id!, role: .admin,
                nodeType: .project, nodeID: tree.project.id!, createdBy: nil, on: app.db)

            // vm:read is a viewer action; admin ⊃ editor ⊃ operator ⊃ viewer.
            let entries = try await WhoCanService.whoCan(action: "vm:read", node: tree.vmNode, on: app.db).principals
            #expect(entries.contains { $0.principal.id == user.id! && $0.role == IAMRole.admin.rawValue })
        }
    }

    @Test("An action no role carries yields no binding-sourced principals")
    func unrelatedActionYieldsNoBindings() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "Unrel")
            let user = try await builder.createUser(username: "unrel", email: "unrel@example.com")

            try await RoleBindingService.grant(
                principalType: .user, principalID: user.id!, role: .admin,
                nodeType: .project, nodeID: tree.project.id!, createdBy: nil, on: app.db)

            let entries = try await WhoCanService.whoCan(action: "vm:teleport", node: tree.vmNode, on: app.db)
                .principals
            #expect(!entries.contains { $0.source == .binding })
        }
    }

    @Test("Expired bindings are excluded")
    func expiredBindingExcluded() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "Exp")
            let expired = try await builder.createUser(username: "exp", email: "exp@example.com")
            let live = try await builder.createUser(username: "live", email: "live@example.com")

            try await RoleBindingService.grant(
                principalType: .user, principalID: expired.id!, role: .editor,
                nodeType: .project, nodeID: tree.project.id!, createdBy: nil,
                expiresAt: Date().addingTimeInterval(-60), on: app.db)
            try await RoleBindingService.grant(
                principalType: .user, principalID: live.id!, role: .editor,
                nodeType: .project, nodeID: tree.project.id!, createdBy: nil,
                expiresAt: Date().addingTimeInterval(3600), on: app.db)

            let entries = try await WhoCanService.whoCan(action: "vm:create", node: tree.vmNode, on: app.db).principals
            #expect(!entries.contains { $0.principal.id == expired.id! })
            #expect(entries.contains { $0.principal.id == live.id! })
        }
    }

    @Test("A group binding lists the group and expands to its members with via")
    func groupBindingExpands() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "Grp")
            let group = try await builder.createGroup(name: "Grp Team", description: "d", organization: tree.org)
            let member = try await builder.createUser(username: "gmem", email: "gmem@example.com")
            try await UserGroup(userID: member.id!, groupID: group.id!).save(on: app.db)

            try await RoleBindingService.grant(
                principalType: .group, principalID: group.id!, role: .editor,
                nodeType: .project, nodeID: tree.project.id!, createdBy: nil, on: app.db)

            let entries = try await WhoCanService.whoCan(action: "vm:create", node: tree.vmNode, on: app.db).principals

            // The grant itself...
            let groupEntry = entries.first { $0.principal == WhoCanPrincipalRef(type: .group, id: group.id!) }
            #expect(groupEntry?.source == .binding)
            #expect(groupEntry?.via == nil)

            // ...and the human it reaches, attributed to the group.
            let userEntry = entries.first { $0.principal == WhoCanPrincipalRef(type: .user, id: member.id!) }
            #expect(userEntry?.via == WhoCanPrincipalRef(type: .group, id: group.id!))
            #expect(userEntry?.role == IAMRole.editor.rawValue)
        }
    }

    @Test("Cross-org principals are reported, not filtered out")
    func crossOrgPrincipalIncluded() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "Home")
            let otherOrg = try await builder.createOrganization(name: "Outside Org")
            let outsider = try await builder.createUser(username: "outsider", email: "outsider@example.com")
            try await builder.addUserToOrganization(user: outsider, organization: otherOrg, role: "member")

            try await RoleBindingService.grant(
                principalType: .user, principalID: outsider.id!, role: .editor,
                nodeType: .virtualMachine, nodeID: tree.vm.id!, createdBy: nil, on: app.db)

            let entries = try await WhoCanService.whoCan(action: "vm:create", node: tree.vmNode, on: app.db).principals
            // External access is exactly what this endpoint must surface.
            #expect(entries.contains { $0.principal.id == outsider.id! && $0.source == .binding })
        }
    }

    @Test("Org members appear for membership-derived actions only")
    func orgMembershipSource() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "Mem")
            let member = try await builder.createUser(username: "mem", email: "mem@example.com")
            try await builder.addUserToOrganization(user: member, organization: tree.org, role: "member")

            let orgRead = try await WhoCanService.whoCan(action: "org:read", node: tree.vmNode, on: app.db).principals
            #expect(orgRead.contains { $0.principal.id == member.id! && $0.source == .orgMembership })

            // Bare membership grants nothing else — no binding, no access.
            let vmStart = try await WhoCanService.whoCan(action: "vm:start", node: tree.vmNode, on: app.db).principals
            #expect(!vmStart.contains { $0.principal.id == member.id! })
        }
    }

    @Test("System admins are reported as a distinct source")
    func systemAdminSource() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "Sys")
            let admin = try await builder.createUser(
                username: "sysadm", email: "sysadm@example.com", isSystemAdmin: true)

            let entries = try await WhoCanService.whoCan(action: "vm:start", node: tree.vmNode, on: app.db).principals
            let match = entries.first { $0.principal.id == admin.id! }
            #expect(match?.source == .systemAdmin)
            #expect(match?.role == nil)
        }
    }

    @Test("Two groups granting the same role produce one entry each, not a merge")
    func multiplePathsEachExplained() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "Multi")
            let user = try await builder.createUser(username: "multi", email: "multi@example.com")
            let groupA = try await builder.createGroup(name: "A", description: "d", organization: tree.org)
            let groupB = try await builder.createGroup(name: "B", description: "d", organization: tree.org)
            try await UserGroup(userID: user.id!, groupID: groupA.id!).save(on: app.db)
            try await UserGroup(userID: user.id!, groupID: groupB.id!).save(on: app.db)

            for group in [groupA, groupB] {
                try await RoleBindingService.grant(
                    principalType: .group, principalID: group.id!, role: .editor,
                    nodeType: .project, nodeID: tree.project.id!, createdBy: nil, on: app.db)
            }

            let entries = try await WhoCanService.whoCan(action: "vm:create", node: tree.vmNode, on: app.db).principals
            let userEntries = entries.filter { $0.principal == WhoCanPrincipalRef(type: .user, id: user.id!) }
            // Revoking access means revoking both, so both must be visible.
            #expect(userEntries.count == 2)
            #expect(Set(userEntries.compactMap(\.via?.id)) == Set([groupA.id!, groupB.id!]))
        }
    }

    // MARK: - Grants that are not bindings

    /// A global network — one with no project — is readable by every
    /// authenticated user (`NetworkController.fetchNetworkWithPermission`),
    /// so neither answer may be assembled from bindings alone.
    @Test("A global network reports network:read as open to all, and can() agrees")
    func globalNetworkReadIsOpen() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let stranger = try await builder.createUser(username: "stranger", email: "stranger@example.com")
            let network = LogicalNetwork(name: "global-net", subnet: "10.90.0.0/24", gateway: "10.90.0.1")
            try await network.save(on: app.db)
            let node = IAMNode(type: .network, id: network.id!)

            let result = try await WhoCanService.whoCan(action: "network:read", node: node, on: app.db)
            #expect(result.openToAllAuthenticatedUsers)

            // The stranger holds no binding anywhere, but the API would still
            // serve them this network.
            let allowed = try await WhoCanService.can(
                principalType: .user, principalID: stranger.id!, action: "network:read",
                node: node, on: app.db)
            #expect(allowed)

            // The exemption is read-only and network-specific.
            let update = try await WhoCanService.whoCan(action: "network:update", node: node, on: app.db)
            #expect(!update.openToAllAuthenticatedUsers)
            let canUpdate = try await WhoCanService.can(
                principalType: .user, principalID: stranger.id!, action: "network:update",
                node: node, on: app.db)
            #expect(!canUpdate)
        }
    }

    @Test("A project-scoped network is not open to all")
    func projectNetworkIsNotOpen() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "NetScoped")
            let stranger = try await builder.createUser(username: "netstranger", email: "netstranger@example.com")
            let network = LogicalNetwork(
                name: "project-net", subnet: "10.91.0.0/24", gateway: "10.91.0.1",
                projectID: tree.project.id!)
            try await network.save(on: app.db)
            let node = IAMNode(type: .network, id: network.id!)

            let result = try await WhoCanService.whoCan(action: "network:read", node: node, on: app.db)
            #expect(!result.openToAllAuthenticatedUsers)
            let allowed = try await WhoCanService.can(
                principalType: .user, principalID: stranger.id!, action: "network:read",
                node: node, on: app.db)
            #expect(!allowed)
        }
    }

    @Test("Global-network openness applies only to real, enabled user accounts")
    func globalNetworkOpennessRequiresRealUser() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let disabled = try await builder.createUser(username: "disabled", email: "disabled@example.com")
            disabled.disabledAt = Date()
            try await disabled.save(on: app.db)
            let org = try await builder.createOrganization(name: "Open Org")
            let group = try await builder.createGroup(name: "Open Team", description: "d", organization: org)
            let network = LogicalNetwork(name: "open-net", subnet: "10.92.0.0/24", gateway: "10.92.0.1")
            try await network.save(on: app.db)
            let node = IAMNode(type: .network, id: network.id!)

            func can(_ type: IAMPrincipalType, _ id: UUID) async throws -> Bool {
                try await WhoCanService.can(
                    principalType: type, principalID: id, action: "network:read", node: node, on: app.db)
            }

            // A group never logs in; an unknown id is nobody; a disabled account
            // is rejected before authorization runs.
            let groupAllowed = try await can(.group, group.id!)
            let unknownAllowed = try await can(.user, UUID())
            let disabledAllowed = try await can(.user, disabled.id!)
            #expect(!groupAllowed)
            #expect(!unknownAllowed)
            #expect(!disabledAllowed)
        }
    }

    @Test("A disabled account cannot act on any grant it still holds")
    func disabledPrincipalCannotAct() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "Disabled")
            let disabled = try await builder.createUser(username: "gone", email: "gone@example.com")
            try await builder.addUserToOrganization(user: disabled, organization: tree.org, role: "member")
            let group = try await builder.createGroup(name: "Gone Team", description: "d", organization: tree.org)
            try await UserGroup(userID: disabled.id!, groupID: group.id!).save(on: app.db)

            // Every grant shape at once: direct binding, group binding, org
            // membership, and system admin.
            try await RoleBindingService.grant(
                principalType: .user, principalID: disabled.id!, role: .editor,
                nodeType: .project, nodeID: tree.project.id!, createdBy: nil, on: app.db)
            try await RoleBindingService.grant(
                principalType: .group, principalID: group.id!, role: .admin,
                nodeType: .organization, nodeID: tree.org.id!, createdBy: nil, on: app.db)
            disabled.isSystemAdmin = true
            disabled.disabledAt = Date()
            try await disabled.save(on: app.db)

            for action in ["vm:create", "vm:read", "org:read"] {
                let allowed = try await WhoCanService.can(
                    principalType: .user, principalID: disabled.id!, action: action,
                    node: tree.vmNode, on: app.db)
                #expect(!allowed, "disabled account should not hold \(action)")
            }
        }
    }

    @Test("who-can still lists a disabled holder's grants, marked as unusable")
    func disabledPrincipalStillListed() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "DisabledList")
            let disabled = try await builder.createUser(username: "gone2", email: "gone2@example.com")
            let active = try await builder.createUser(username: "here", email: "here@example.com")
            for user in [disabled, active] {
                try await RoleBindingService.grant(
                    principalType: .user, principalID: user.id!, role: .editor,
                    nodeType: .project, nodeID: tree.project.id!, createdBy: nil, on: app.db)
            }
            disabled.disabledAt = Date()
            try await disabled.save(on: app.db)

            let entries = try await WhoCanService.whoCan(action: "vm:create", node: tree.vmNode, on: app.db).principals

            // The un-revoked grant stays visible — that is the point of the
            // audit — but is marked so it isn't read as live access.
            let goneEntry = entries.first { $0.principal.id == disabled.id! }
            #expect(goneEntry?.principalDisabled == true)
            #expect(goneEntry?.role == IAMRole.editor.rawValue)
            let hereEntry = entries.first { $0.principal.id == active.id! }
            #expect(hereEntry?.principalDisabled == false)
        }
    }

    @Test("Sandbox snapshot owners can read policy on their own snapshot")
    func sandboxSnapshotIsAnAdminNode() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "SnapAdmin")
            let sandbox = try await builder.createSandbox(name: "snap-sb", project: tree.project)
            let owner = try await builder.createUser(username: "snapowner", email: "snapowner@example.com")
            try await builder.addUserToOrganization(user: owner, organization: tree.org, role: "member")
            let snapshot = SandboxSnapshot(
                name: "snap-1", sandboxID: sandbox.id!, projectID: tree.project.id!,
                environment: "development", agentId: nil, createdByID: owner.id!)
            try await snapshot.save(on: app.db)
            let token = try await owner.generateAPIKey(on: app.db)

            // Admin on the snapshot itself, nothing above it.
            app.spicedbMockAllows = true
            app.spicedbMockDeniedResources = ["project", "organizational_unit", "organization"]
            defer { app.spicedbMockDeniedResources = [] }

            try await app.test(.POST, "/api/authorization/who-can") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    AuthorizationController.WhoCanRequest(
                        resourceType: "sandbox_snapshot",
                        resourceId: snapshot.id!.uuidString,
                        action: "sandbox:restore"
                    ))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }
        }
    }

    // MARK: - Org/folder-scoped infrastructure

    @Test("Sites and agents resolve to their org or folder scope")
    func siteAndAgentWalk() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "Infra Org")
            let ou = try await builder.createOU(name: "Infra OU", description: "d", organization: org)
            let site = Site(name: "site-a", organizationScope: .organizationalUnit(ou.id!))
            try await site.save(on: app.db)

            let chain = try await IAMResourceTree.ancestors(
                of: IAMNode(type: .site, id: site.id!), on: app.db)
            #expect(
                chain == [
                    IAMNode(type: .site, id: site.id!),
                    IAMNode(type: .organizationalUnit, id: ou.id!),
                    IAMNode(type: .organization, id: org.id!),
                ])
        }
    }

    @Test("An admin above a site can be found by who-can on the site")
    func whoCanOnSite() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "Site Org")
            let admin = try await builder.createUser(username: "siteadm", email: "siteadm@example.com")
            let site = Site(name: "site-b", organizationScope: .organization(org.id!))
            try await site.save(on: app.db)

            try await RoleBindingService.grant(
                principalType: .user, principalID: admin.id!, role: .admin,
                nodeType: .organization, nodeID: org.id!, createdBy: nil, on: app.db)

            let entries = try await WhoCanService.whoCan(
                action: "site:manage", node: IAMNode(type: .site, id: site.id!), on: app.db
            ).principals
            #expect(entries.contains { $0.principal.id == admin.id! && $0.source == .binding })
        }
    }

    // MARK: - Forward check for an arbitrary principal

    @Test("can() agrees with whoCan across binding, group, and expiry")
    func canMatchesWhoCan() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "Can")
            let direct = try await builder.createUser(username: "direct", email: "direct@example.com")
            let viaGroup = try await builder.createUser(username: "viagrp", email: "viagrp@example.com")
            let expired = try await builder.createUser(username: "canexp", email: "canexp@example.com")
            let nobody = try await builder.createUser(username: "nobody", email: "nobody@example.com")
            let group = try await builder.createGroup(name: "Can Team", description: "d", organization: tree.org)
            try await UserGroup(userID: viaGroup.id!, groupID: group.id!).save(on: app.db)

            try await RoleBindingService.grant(
                principalType: .user, principalID: direct.id!, role: .editor,
                nodeType: .project, nodeID: tree.project.id!, createdBy: nil, on: app.db)
            try await RoleBindingService.grant(
                principalType: .group, principalID: group.id!, role: .editor,
                nodeType: .organizationalUnit, nodeID: tree.ou.id!, createdBy: nil, on: app.db)
            try await RoleBindingService.grant(
                principalType: .user, principalID: expired.id!, role: .editor,
                nodeType: .project, nodeID: tree.project.id!, createdBy: nil,
                expiresAt: Date().addingTimeInterval(-60), on: app.db)

            func can(_ user: User) async throws -> Bool {
                try await WhoCanService.can(
                    principalType: .user, principalID: user.id!, action: "vm:create",
                    node: tree.vmNode, on: app.db)
            }

            let directAllowed = try await can(direct)
            let groupAllowed = try await can(viaGroup)
            let expiredAllowed = try await can(expired)
            let nobodyAllowed = try await can(nobody)
            #expect(directAllowed)
            #expect(groupAllowed)
            #expect(!expiredAllowed)
            #expect(!nobodyAllowed)
        }
    }

    @Test("can() is true for a system admin with no bindings at all")
    func canSystemAdmin() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "CanSys")
            let admin = try await builder.createUser(
                username: "cansys", email: "cansys@example.com", isSystemAdmin: true)

            let allowed = try await WhoCanService.can(
                principalType: .user, principalID: admin.id!, action: "vm:create",
                node: tree.vmNode, on: app.db)
            #expect(allowed)
        }
    }

    // MARK: - Endpoint

    @Test("who-can endpoint returns the chain and the principals")
    func whoCanEndpoint() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "Endpoint")
            let caller = try await builder.createUser(
                username: "epadmin", email: "epadmin@example.com", isSystemAdmin: true)
            let grantee = try await builder.createUser(username: "epgrant", email: "epgrant@example.com")
            try await RoleBindingService.grant(
                principalType: .user, principalID: grantee.id!, role: .editor,
                nodeType: .project, nodeID: tree.project.id!, createdBy: nil, on: app.db)
            let token = try await caller.generateAPIKey(on: app.db)

            try await app.test(.POST, "/api/authorization/who-can") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    AuthorizationController.WhoCanRequest(
                        resourceType: "virtual_machine",
                        resourceId: tree.vm.id!.uuidString,
                        action: "vm:create"
                    ))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let decoded = try res.content.decode(AuthorizationController.WhoCanResponse.self)
                #expect(decoded.ancestors.count == 5)
                #expect(decoded.principals.contains { $0.principal.id == grantee.id! && $0.source == .binding })
            }
        }
    }

    @Test("who-can rejects an unknown resource type as a bad request, not a denial")
    func whoCanUnknownType() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let caller = try await builder.createUser(
                username: "eptype", email: "eptype@example.com", isSystemAdmin: true)
            let token = try await caller.generateAPIKey(on: app.db)

            try await app.test(.POST, "/api/authorization/who-can") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    AuthorizationController.WhoCanRequest(
                        resourceType: "toaster", resourceId: UUID().uuidString, action: "vm:read"))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("A resource-level admin may read policy without holding project admin")
    func whoCanAllowsResourceLevelAdmin() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "ResAdmin")
            let owner = try await builder.createUser(username: "vmowner", email: "vmowner@example.com")
            try await builder.addUserToOrganization(user: owner, organization: tree.org, role: "member")
            let token = try await owner.generateAPIKey(on: app.db)

            // Admin on the VM itself, nothing above it — a VM creator's position.
            app.spicedbMockAllows = true
            app.spicedbMockDeniedResources = ["project", "organizational_unit", "organization"]
            defer { app.spicedbMockDeniedResources = [] }

            try await app.test(.POST, "/api/authorization/who-can") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    AuthorizationController.WhoCanRequest(
                        resourceType: "virtual_machine",
                        resourceId: tree.vm.id!.uuidString,
                        action: "vm:create"
                    ))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }
        }
    }

    @Test("who-can is refused to a caller without admin over the resource")
    func whoCanRequiresAdmin() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "Gate")
            let caller = try await builder.createUser(username: "epuser", email: "epuser@example.com")
            try await builder.addUserToOrganization(user: caller, organization: tree.org, role: "member")
            let token = try await caller.generateAPIKey(on: app.db)
            app.spicedbMockAllows = false

            try await app.test(.POST, "/api/authorization/who-can") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    AuthorizationController.WhoCanRequest(
                        resourceType: "virtual_machine",
                        resourceId: tree.vm.id!.uuidString,
                        action: "vm:create"
                    ))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test("check with an explicit principal answers from the bindings table")
    func checkForArbitraryPrincipal() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "CheckP")
            let caller = try await builder.createUser(
                username: "cpadmin", email: "cpadmin@example.com", isSystemAdmin: true)
            let subject = try await builder.createUser(username: "cpsubj", email: "cpsubj@example.com")
            try await RoleBindingService.grant(
                principalType: .user, principalID: subject.id!, role: .viewer,
                nodeType: .project, nodeID: tree.project.id!, createdBy: nil, on: app.db)
            let token = try await caller.generateAPIKey(on: app.db)

            // The caller is a system admin, so an unguarded implementation would
            // answer `true` for everything — the subject's own grants must decide.
            try await app.test(.POST, "/api/authorization/check") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    AuthorizationController.CheckRequest(
                        checks: [
                            .init(
                                key: "read", resourceType: "virtual_machine",
                                resourceId: tree.vm.id!.uuidString, permission: "vm:read"),
                            .init(
                                key: "create", resourceType: "virtual_machine",
                                resourceId: tree.vm.id!.uuidString, permission: "vm:create"),
                        ],
                        principal: .init(type: .user, id: subject.id!)
                    ))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let decoded = try res.content.decode(AuthorizationController.CheckResponse.self)
                #expect(decoded.results["read"] == true)
                // viewer does not carry vm:create.
                #expect(decoded.results["create"] == false)
            }
        }
    }
}
