import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import App

/// Grants are keyed by role-definition id since the unified role store
/// (issue #604); these seeded-role conveniences keep the assertions readable.
extension CedarRoleGrants {
    fileprivate func users(for role: IAMRole) -> Set<UUID> { users(for: role.seededID) }
    fileprivate func groups(for role: IAMRole) -> Set<UUID> { groups(for: role.seededID) }
}

/// IAM phase 3 (issue #480): the entity-slice loader — the security-critical
/// component of the Cedar integration, so this is where the test investment
/// goes. Beyond the per-edge cases, `sliceCrossCheck*` compares the real
/// evaluator's answers (`WhoCanService.can`, which decides through
/// `IAMDecisionEngine`) against an independent hand-simulation of the static
/// policies over the raw slice, for a whole grid of principals × actions ×
/// nodes: a slice edge the loader dropped would surface as the two
/// disagreeing.
@Suite("Entity Slice Loader Tests", .serialized)
final class EntitySliceLoaderTests {

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

    private struct Tree {
        let org: Organization
        let ou: OrganizationalUnit
        let childOU: OrganizationalUnit
        let project: Project
        let vm: VM
        var vmNode: IAMNode { IAMNode(type: .virtualMachine, id: vm.id!) }
        var projectNode: IAMNode { IAMNode(type: .project, id: project.id!) }
        var orgNode: IAMNode { IAMNode(type: .organization, id: org.id!) }
    }

    private func buildTree(_ builder: TestDataBuilder, prefix: String) async throws -> Tree {
        let org = try await builder.createOrganization(name: "\(prefix) Org")
        let ou = try await builder.createOU(name: "\(prefix) OU", description: "d", organization: org)
        let childOU = try await builder.createOU(
            name: "\(prefix) Child OU", description: "d", organization: org, parentOU: ou)
        let project = try await builder.createProject(name: "\(prefix) Project", description: "d", ou: childOU)
        let vm = try await builder.createVM(name: "\(prefix)-vm", project: project, environment: "production")
        return Tree(org: org, ou: ou, childOU: childOU, project: project, vm: vm)
    }

    private func entity(_ slice: CedarEntitySlice, _ uid: CedarEntityUID) -> CedarEntity? {
        slice.entities.first { $0.uid == uid }
    }

    // MARK: - Chain shape

    @Test("Chain entities carry the parent edges Cedar's `in` walks")
    func chainParentEdges() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "Chain")
            let user = try await builder.createUser(username: "chain-user", email: "chain@example.com")

            let slice = try await EntitySliceLoader.load(userID: user.id!, node: tree.vmNode, on: app.db)

            let vmUID = CedarEntityUID(type: .vm, id: tree.vm.id!)
            let projectUID = CedarEntityUID(type: .project, id: tree.project.id!)
            let childOUUID = CedarEntityUID(type: .folder, id: tree.childOU.id!)
            let ouUID = CedarEntityUID(type: .folder, id: tree.ou.id!)
            let orgUID = CedarEntityUID(type: .organization, id: tree.org.id!)

            #expect(slice.resource == vmUID)
            #expect(entity(slice, vmUID)?.parents == [projectUID])
            #expect(entity(slice, projectUID)?.parents == [childOUUID])
            #expect(entity(slice, childOUUID)?.parents == [ouUID])
            #expect(entity(slice, ouUID)?.parents == [orgUID])
            #expect(entity(slice, orgUID)?.parents == [])
        }
    }

    @Test("A dangling node yields a one-entity chain and no grants — under-report, never invent")
    func danglingNode() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(username: "dangle-user", email: "dangle@example.com")
            let orphan = IAMNode(type: .virtualMachine, id: UUID())

            let slice = try await EntitySliceLoader.load(userID: user.id!, node: orphan, on: app.db)

            #expect(entity(slice, orphan.cedarUID)?.parents == [])
            #expect(slice.grants == CedarRoleGrants())
        }
    }

    // MARK: - Target attributes

    @Test("The target resource carries its environment attribute")
    func environmentAttribute() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "Env")
            let user = try await builder.createUser(username: "env-user", email: "env@example.com")

            let slice = try await EntitySliceLoader.load(userID: user.id!, node: tree.vmNode, on: app.db)

            let vm = entity(slice, CedarEntityUID(type: .vm, id: tree.vm.id!))
            #expect(vm?.attrs["environment"] == .string("production"))
            // Containers genuinely have no environment.
            let project = entity(slice, CedarEntityUID(type: .project, id: tree.project.id!))
            #expect(project?.attrs["environment"] == nil)
        }
    }

    @Test("A global network is marked open to all users; a project network is not")
    func openNetworkAttribute() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "Net")
            let user = try await builder.createUser(username: "net-user", email: "net@example.com")

            let globalNetwork = LogicalNetwork(name: "global-net", subnet: "10.90.0.0/24", gateway: "10.90.0.1")
            try await globalNetwork.save(on: app.db)
            let projectNetwork = LogicalNetwork(
                name: "proj-net", subnet: "10.91.0.0/24", gateway: "10.91.0.1", projectID: tree.project.id!)
            try await projectNetwork.save(on: app.db)

            let globalSlice = try await EntitySliceLoader.load(
                userID: user.id!, node: IAMNode(type: .network, id: globalNetwork.id!), on: app.db)
            let projectSlice = try await EntitySliceLoader.load(
                userID: user.id!, node: IAMNode(type: .network, id: projectNetwork.id!), on: app.db)

            let globalEntity = entity(globalSlice, CedarEntityUID(type: .network, id: globalNetwork.id!))
            let projectEntity = entity(projectSlice, CedarEntityUID(type: .network, id: projectNetwork.id!))
            #expect(globalEntity?.attrs["openToAllUsers"] == .bool(true))
            #expect(projectEntity?.attrs["openToAllUsers"] == .bool(false))
        }
    }

    // MARK: - Chain resolution and the request cache (issue #686)

    @Test("A stale materialized folder path does not change the chain")
    func staleFolderPathIsOnlyAHint() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "Stale")
            let expected = try await IAMResourceTree.ancestors(of: tree.vmNode, on: app.db)

            // The batched folder walk uses `path` to prefetch the rows it is
            // about to need; the parent pointers stay authoritative. Corrupt
            // the hint in both directions — a path naming nothing, and a path
            // naming an unrelated folder — and the chain must not move.
            let unrelated = try await builder.createOU(
                name: "Stale Unrelated", description: "d", organization: tree.org)
            tree.childOU.path = "/nonsense"
            try await tree.childOU.save(on: app.db)
            tree.ou.path = "/\(tree.org.id!.uuidString)/\(unrelated.id!.uuidString)/\(tree.ou.id!.uuidString)"
            try await tree.ou.save(on: app.db)

            let actual = try await IAMResourceTree.ancestors(of: tree.vmNode, on: app.db)
            #expect(actual == expected)
            #expect(
                actual == [
                    tree.vmNode,
                    tree.projectNode,
                    IAMNode(type: .organizationalUnit, id: tree.childOU.id!),
                    IAMNode(type: .organizationalUnit, id: tree.ou.id!),
                    tree.orgNode,
                ])
        }
    }

    @Test("Loading through a request cache yields the same slices as loading without one")
    func requestCachedSlicesAreUnchanged() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "Cache")
            let user = try await builder.createUser(username: "cache-user", email: "cache@example.com")
            try await builder.addUserToOrganization(user: user, organization: tree.org)
            let group = try await builder.createGroup(name: "cache-team", description: "d", organization: tree.org)
            try await UserGroup(userID: user.id!, groupID: group.id!).save(on: app.db)
            try await RoleBindingService.grant(
                principalType: .group, principalID: group.id!, role: .viewer,
                nodeType: .project, nodeID: tree.project.id!, createdBy: nil, on: app.db)

            let cache = IAMRequestCache()
            for node in [tree.vmNode, tree.projectNode, tree.orgNode] {
                let uncached = try await EntitySliceLoader.load(userID: user.id!, node: node, on: app.db)
                let first = try await EntitySliceLoader.load(
                    userID: user.id!, node: node, cache: cache, on: app.db)
                let second = try await EntitySliceLoader.load(
                    userID: user.id!, node: node, cache: cache, on: app.db)
                #expect(first == uncached)
                #expect(second == uncached)
            }
        }
    }

    // MARK: - Principal

    @Test("The principal carries group parent edges, org memberships, and the systemAdmin attribute")
    func principalShape() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "Principal")
            let user = try await builder.createUser(username: "prin-user", email: "prin@example.com")
            try await builder.addUserToOrganization(user: user, organization: tree.org)
            let group = try await builder.createGroup(name: "team", description: "d", organization: tree.org)
            try await UserGroup(userID: user.id!, groupID: group.id!).save(on: app.db)

            let slice = try await EntitySliceLoader.load(userID: user.id!, node: tree.vmNode, on: app.db)

            let principal = entity(slice, slice.principal)
            let groupUID = CedarEntityUID(type: .group, id: group.id!)
            let orgUID = CedarEntityUID(type: .organization, id: tree.org.id!)
            #expect(principal?.parents == [groupUID])
            #expect(principal?.attrs["memberOfOrgs"] == .set([.entity(orgUID)]))
            #expect(principal?.attrs["systemAdmin"] == .bool(false))
            // The group exists in the store so hierarchy checks resolve.
            #expect(entity(slice, groupUID) != nil)
        }
    }

    @Test("A system admin's attribute is set; a missing user gets the powerless defaults")
    func systemAdminAndMissingUser() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "Admin")
            let admin = try await builder.createUser(
                username: "root", email: "root@example.com", isSystemAdmin: true)

            let adminSlice = try await EntitySliceLoader.load(userID: admin.id!, node: tree.vmNode, on: app.db)
            let ghostSlice = try await EntitySliceLoader.load(userID: UUID(), node: tree.vmNode, on: app.db)

            #expect(entity(adminSlice, adminSlice.principal)?.attrs["systemAdmin"] == .bool(true))
            let ghost = entity(ghostSlice, ghostSlice.principal)
            #expect(ghost?.attrs["systemAdmin"] == .bool(false))
            #expect(ghost?.attrs["memberOfOrgs"] == .set([]))
            #expect(ghostSlice.grants == CedarRoleGrants())
        }
    }

    // MARK: - Grants flattening

    @Test("Bindings anywhere along the chain flatten into the role grants")
    func bindingsAlongChain() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "Grants")
            let user = try await builder.createUser(username: "grant-user", email: "grant@example.com")

            try await RoleBindingService.grant(
                principalType: .user, principalID: user.id!, role: .viewer,
                nodeType: .virtualMachine, nodeID: tree.vm.id!, createdBy: nil, on: app.db)
            try await RoleBindingService.grant(
                principalType: .user, principalID: user.id!, role: .editor,
                nodeType: .organizationalUnit, nodeID: tree.ou.id!, createdBy: nil, on: app.db)

            let slice = try await EntitySliceLoader.load(userID: user.id!, node: tree.vmNode, on: app.db)

            #expect(slice.grants.users(for: .viewer) == [user.id!])
            #expect(slice.grants.users(for: .editor) == [user.id!])
            #expect(slice.grants.users(for: .admin).isEmpty)
        }
    }

    @Test("A binding outside the chain does not leak in")
    func bindingOutsideChain() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "Leak")
            let other = try await buildTree(builder, prefix: "LeakOther")
            let user = try await builder.createUser(username: "leak-user", email: "leak@example.com")

            try await RoleBindingService.grant(
                principalType: .user, principalID: user.id!, role: .admin,
                nodeType: .organization, nodeID: other.org.id!, createdBy: nil, on: app.db)

            let slice = try await EntitySliceLoader.load(userID: user.id!, node: tree.vmNode, on: app.db)
            #expect(slice.grants == CedarRoleGrants())
        }
    }

    @Test("Group bindings flatten as group grants, reachable through the principal's parent edge")
    func groupBindings() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "Group")
            let user = try await builder.createUser(username: "group-user", email: "group@example.com")
            let group = try await builder.createGroup(name: "ops", description: "d", organization: tree.org)
            try await UserGroup(userID: user.id!, groupID: group.id!).save(on: app.db)

            try await RoleBindingService.grant(
                principalType: .group, principalID: group.id!, role: .operator,
                nodeType: .project, nodeID: tree.project.id!, createdBy: nil, on: app.db)

            let slice = try await EntitySliceLoader.load(userID: user.id!, node: tree.vmNode, on: app.db)

            #expect(slice.grants.groups(for: .operator) == [group.id!])
            #expect(slice.grants.users(for: .operator).isEmpty)
            #expect(entity(slice, slice.principal)?.parents == [CedarEntityUID(type: .group, id: group.id!)])
        }
    }

    @Test("Another group's binding is not loaded for a non-member")
    func otherGroupsBindingExcluded() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "NonMember")
            let user = try await builder.createUser(username: "nonmember", email: "nonmember@example.com")
            let group = try await builder.createGroup(name: "others", description: "d", organization: tree.org)

            try await RoleBindingService.grant(
                principalType: .group, principalID: group.id!, role: .admin,
                nodeType: .organization, nodeID: tree.org.id!, createdBy: nil, on: app.db)

            let slice = try await EntitySliceLoader.load(userID: user.id!, node: tree.vmNode, on: app.db)
            #expect(slice.grants == CedarRoleGrants())
        }
    }

    @Test("Expired bindings are excluded; conditioned bindings are skipped and counted, never flattened")
    func expiredAndConditionedBindings() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "Expiry")
            let user = try await builder.createUser(username: "exp-user", email: "exp@example.com")

            try await RoleBindingService.grant(
                principalType: .user, principalID: user.id!, role: .admin,
                nodeType: .project, nodeID: tree.project.id!, createdBy: nil,
                expiresAt: Date(timeIntervalSinceNow: -60), on: app.db)
            // Flattening a conditioned binding as unconditional would turn a
            // restricted grant into an open one — it must be skipped.
            try await RoleBinding(
                principalType: .user, principalID: user.id!, role: .editor,
                nodeType: .project, nodeID: tree.project.id!,
                condition: #"{"mfa": true}"#
            ).save(on: app.db)

            let slice = try await EntitySliceLoader.load(userID: user.id!, node: tree.vmNode, on: app.db)

            #expect(slice.grants == CedarRoleGrants())
            #expect(slice.skippedConditionedBindings == 1)
        }
    }

    @Test("A cross-org principal's bindings load; its memberOfOrgs names its own org, not the resource's")
    func crossOrgPrincipal() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "Home")
            let otherOrg = try await builder.createOrganization(name: "Other Org")
            let outsider = try await builder.createUser(username: "outsider", email: "outsider@example.com")
            try await builder.addUserToOrganization(user: outsider, organization: otherOrg)

            try await RoleBindingService.grant(
                principalType: .user, principalID: outsider.id!, role: .editor,
                nodeType: .project, nodeID: tree.project.id!, createdBy: nil, on: app.db)

            let slice = try await EntitySliceLoader.load(userID: outsider.id!, node: tree.vmNode, on: app.db)

            // The grant is real — cross-org access is allowed via explicit
            // bindings — and the membership attribute is what lets an
            // external-to-organization guardrail catch it.
            #expect(slice.grants.users(for: .editor) == [outsider.id!])
            let principal = entity(slice, slice.principal)
            let expectedOrgs = CedarValue.set([.entity(CedarEntityUID(type: .organization, id: otherOrg.id!))])
            #expect(principal?.attrs["memberOfOrgs"] == expectedOrgs)
        }
    }

    // MARK: - Determinism and rendering

    @Test("Two loads of the same slice are identical, including the JSON rendering")
    func deterministicSlices() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "Det")
            let user = try await builder.createUser(username: "det-user", email: "det@example.com")
            try await builder.addUserToOrganization(user: user, organization: tree.org)
            for name in ["g1", "g2", "g3"] {
                let group = try await builder.createGroup(name: name, description: "d", organization: tree.org)
                try await UserGroup(userID: user.id!, groupID: group.id!).save(on: app.db)
                try await RoleBindingService.grant(
                    principalType: .group, principalID: group.id!, role: .viewer,
                    nodeType: .project, nodeID: tree.project.id!, createdBy: nil, on: app.db)
            }

            let first = try await EntitySliceLoader.load(userID: user.id!, node: tree.vmNode, on: app.db)
            let second = try await EntitySliceLoader.load(userID: user.id!, node: tree.vmNode, on: app.db)

            #expect(first == second)
            let firstJSON = try first.entitiesJSON()
            let secondJSON = try second.entitiesJSON()
            #expect(firstJSON == secondJSON)
        }
    }

    @Test("Entities JSON uses Cedar's uid/attrs/parents shape with the __entity escape")
    func entitiesJSONShape() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "JSON")
            let user = try await builder.createUser(username: "json-user", email: "json@example.com")
            try await builder.addUserToOrganization(user: user, organization: tree.org)

            let slice = try await EntitySliceLoader.load(userID: user.id!, node: tree.vmNode, on: app.db)
            let json = try slice.entitiesJSON()

            #expect(json.contains("\"uid\":{\"id\":\"\(tree.vm.id!.uuidString.lowercased())\",\"type\":\"VM\"}"))
            #expect(
                json.contains(
                    "\"__entity\":{\"id\":\"\(tree.org.id!.uuidString.lowercased())\",\"type\":\"Organization\"}"))
            #expect(json.contains("\"environment\":\"production\""))
        }
    }

    @Test("The base context carries every grants bucket, empty ones included")
    func baseContextShape() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "Ctx")
            let user = try await builder.createUser(username: "ctx-user", email: "ctx@example.com")
            try await RoleBindingService.grant(
                principalType: .user, principalID: user.id!, role: .admin,
                nodeType: .organization, nodeID: tree.org.id!, createdBy: nil, on: app.db)

            let slice = try await EntitySliceLoader.load(userID: user.id!, node: tree.vmNode, on: app.db)

            let roleIDs = Set(IAMRole.allCases.map(\.seededID))
            guard case .record(let context) = slice.baseContextValue(roleIDs: roleIDs),
                case .record(let grants)? = context["grants"]
            else {
                Issue.record("base context is not a record with grants")
                return
            }
            // The schema declares every field required, so every bucket must
            // be present even when empty.
            for role in IAMRole.allCases {
                #expect(grants[RoleDescriptor.grantsUsersField(role.seededID)] != nil)
                #expect(grants[RoleDescriptor.grantsGroupsField(role.seededID)] != nil)
            }
            let adminUsers = grants[RoleDescriptor.grantsUsersField(IAMRole.admin.seededID)]
            #expect(adminUsers == .set([.entity(CedarEntityUID(type: .user, id: user.id!))]))
        }
    }

    @Test("Grants for roles outside the compiled set are dropped from the context, not emitted")
    func staleSchemaGrantsDropped() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "Stale")
            let user = try await builder.createUser(username: "stale-user", email: "stale@example.com")

            // A binding for a role the compiled set does not know — a role
            // created after this replica's last rebuild, or deleted since.
            let unknownRoleID = UUID()
            try await RoleBindingService.grant(
                principalType: .user, principalID: user.id!, roleID: unknownRoleID,
                nodeType: .organization, nodeID: tree.org.id!, createdBy: nil, on: app.db)
            try await RoleBindingService.grant(
                principalType: .user, principalID: user.id!, role: .viewer,
                nodeType: .organization, nodeID: tree.org.id!, createdBy: nil, on: app.db)

            let slice = try await EntitySliceLoader.load(userID: user.id!, node: tree.vmNode, on: app.db)
            // The loader collected both grants…
            #expect(slice.grants.roleIDs == [unknownRoleID, IAMRole.viewer.seededID])

            // …but the context is shaped to the compiled schema: the unknown
            // role's fields are absent (they would fail strict validation),
            // the seeded ones all present.
            let roleIDs = Set(IAMRole.allCases.map(\.seededID))
            guard case .record(let context) = slice.baseContextValue(roleIDs: roleIDs),
                case .record(let grants)? = context["grants"]
            else {
                Issue.record("base context is not a record with grants")
                return
            }
            // Four fields per role: users, groups, service accounts, and
            // workloads (issue #491).
            #expect(grants.count == IAMRole.allCases.count * 4)
            #expect(grants[RoleDescriptor.grantsUsersField(unknownRoleID)] == nil)
            #expect(
                grants[RoleDescriptor.grantsUsersField(IAMRole.viewer.seededID)]
                    == .set([.entity(CedarEntityUID(type: .user, id: user.id!))]))
        }
    }

    @Test("A binding whose role value is not a UUID is dropped (under-grant, never crash)")
    func nonUUIDRoleValueDropped() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "Legacy")
            let user = try await builder.createUser(username: "legacy-user", email: "legacy@example.com")

            // A pre-backfill row shape: the role column holding a name. The
            // migration rewrites these; any straggler must under-grant.
            let row = RoleBinding(
                principalType: .user, principalID: user.id!, role: .viewer,
                nodeType: .organization, nodeID: tree.org.id!)
            row.role = "viewer"
            try await row.save(on: app.db)

            let slice = try await EntitySliceLoader.load(userID: user.id!, node: tree.vmNode, on: app.db)
            #expect(slice.grants.roleIDs.isEmpty)
        }
    }

    // MARK: - Cross-check against the real evaluator

    /// What the engine would decide from this slice for an unconditioned check
    /// — the static policies from `CedarPolicyAssembler.staticPolicyText()`
    /// simulated over the slice's data. Kept deliberately dumb: any cleverness
    /// here would be testing itself.
    private func sliceAllows(action: String, slice: CedarEntitySlice, user: User, chainOrgID: UUID?) -> Bool {
        // The engine's applicability gate: an action the schema does not apply
        // to the resource's type is denied without evaluation.
        guard CedarSchemaBuilder.resourceTypes(for: action).map(\.rawValue).contains(slice.resource.type)
        else { return false }
        // @id("platform-system-admin")
        if user.isSystemAdmin { return true }
        // @id("org-membership"): resource in principal.memberOfOrgs, via the
        // chain's parent edges.
        if IAMRoleRegistry.membershipDerivedActions.contains(action), let chainOrgID {
            let orgUID = CedarEntityUID(type: .organization, id: chainOrgID)
            if case .set(let orgs)? = entity(slice, slice.principal)?.attrs["memberOfOrgs"],
                orgs.contains(.entity(orgUID))
            {
                return true
            }
        }
        // @id("role-*"): principal in context.grants[...]
        let principalGroups = Set(entity(slice, slice.principal)?.parents.map(\.id) ?? [])
        for role in IAMRoleRegistry.roles(granting: action) {
            if slice.grants.users(for: role).contains(user.id!) { return true }
            let groupIDs = slice.grants.groups(for: role).map {
                CedarEntityUID(type: .group, id: $0).id
            }
            if !principalGroups.isDisjoint(with: groupIDs) { return true }
        }
        return false
    }

    @Test("Evaluator decisions agree with a hand-simulation of the static policies across a grid")
    func sliceCrossCheckAgainstWhoCan() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "Cross")
            let otherOrg = try await builder.createOrganization(name: "Cross Other Org")

            let member = try await builder.createUser(username: "cross-member", email: "cm@example.com")
            try await builder.addUserToOrganization(user: member, organization: tree.org)
            let viaGroup = try await builder.createUser(username: "cross-group", email: "cg@example.com")
            let group = try await builder.createGroup(name: "cross-ops", description: "d", organization: tree.org)
            try await UserGroup(userID: viaGroup.id!, groupID: group.id!).save(on: app.db)
            let outsider = try await builder.createUser(username: "cross-out", email: "co@example.com")
            try await builder.addUserToOrganization(user: outsider, organization: otherOrg)
            let admin = try await builder.createUser(
                username: "cross-root", email: "cr@example.com", isSystemAdmin: true)
            let nobody = try await builder.createUser(username: "cross-nobody", email: "cn@example.com")

            try await RoleBindingService.grant(
                principalType: .group, principalID: group.id!, role: .operator,
                nodeType: .organizationalUnit, nodeID: tree.ou.id!, createdBy: nil, on: app.db)
            try await RoleBindingService.grant(
                principalType: .user, principalID: outsider.id!, role: .viewer,
                nodeType: .project, nodeID: tree.project.id!, createdBy: nil, on: app.db)
            try await RoleBindingService.grant(
                principalType: .user, principalID: member.id!, role: .editor,
                nodeType: .virtualMachine, nodeID: tree.vm.id!, createdBy: nil, on: app.db)

            let users = [member, viaGroup, outsider, admin, nobody]
            let actions = [
                "vm:read", "vm:start", "vm:delete", "iam:setPolicy",
                "org:read", "project:create", "project:read",
            ]
            let nodes = [tree.vmNode, tree.projectNode, tree.orgNode]

            for user in users {
                for node in nodes {
                    let slice = try await EntitySliceLoader.load(userID: user.id!, node: node, on: app.db)
                    let chain = try await IAMResourceTree.ancestors(of: node, on: app.db)
                    let chainOrgID = chain.first(where: { $0.type == .organization })?.id
                    for action in actions {
                        let expected = try await WhoCanService.can(
                            principalType: .user, principalID: user.id!, action: action, node: node, app: app,
                            on: app.db)
                        let actual = sliceAllows(action: action, slice: slice, user: user, chainOrgID: chainOrgID)
                        #expect(
                            actual == expected,
                            "\(user.username) / \(action) on \(node.type.rawValue): hand-simulation says \(actual), evaluator says \(expected)"
                        )
                    }
                }
            }
        }
    }
}
