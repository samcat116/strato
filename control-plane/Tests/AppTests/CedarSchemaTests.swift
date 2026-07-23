import Foundation
import Testing

@testable import App

/// IAM phase 3 (issue #480), rebuilt for the unified role store (issue #604):
/// the generated Cedar schema.
///
/// Role permits now carry explicit action lists (no role action-groups in the
/// schema), so the load-bearing checks are: the seeded roles' expanded action
/// sets keep the `viewer ⊂ operator ⊂ editor ⊂ admin` chain, the canonical
/// permit text enumerates exactly those sets, and the `Grants` record
/// declares one field pair per role row.
@Suite("Cedar Schema Tests")
struct CedarSchemaTests {

    /// All groups `name` is transitively a member of, per the declarations.
    private func closure(of name: String, in decls: [CedarSchemaBuilder.ActionDecl]) -> Set<String> {
        let byName = Dictionary(uniqueKeysWithValues: decls.map { ($0.name, $0) })
        var result: Set<String> = []
        var frontier = byName[name]?.memberOf ?? []
        while let group = frontier.popLast() {
            if result.insert(group).inserted {
                frontier += byName[group]?.memberOf ?? []
            }
        }
        return result
    }

    private func descriptor(for role: IAMRole) -> RoleDescriptor {
        let actions = IAMRoleRegistry.actions(for: role).sorted()
        return RoleDescriptor(
            id: role.seededID,
            name: role.rawValue,
            cedarText: RoleDescriptor.canonicalPermitText(id: role.seededID, actions: actions),
            actions: actions
        )
    }

    private var seededDescriptors: [RoleDescriptor] { IAMRole.allCases.map(descriptor(for:)) }

    // MARK: - Seeded role action sets

    @Test("Seeded role expansion keeps the subset chain (viewer ⊂ operator ⊂ editor ⊂ admin)")
    func seededRoleChainNested() {
        let viewer = IAMRoleRegistry.actions(for: .viewer)
        let op = IAMRoleRegistry.actions(for: .operator)
        let editor = IAMRoleRegistry.actions(for: .editor)
        let admin = IAMRoleRegistry.actions(for: .admin)

        #expect(viewer.isSubset(of: op))
        #expect(op.isSubset(of: editor))
        #expect(editor.isSubset(of: admin))
        // Strict subsets: each role must add something, or the chain is
        // degenerate and a registry entry got lost.
        #expect(viewer != op)
        #expect(op != editor)
        #expect(editor != admin)
        // `admin` carries the whole vocabulary except the actions no role
        // carries by design: `project:create` (bare org membership grants it),
        // the identity-plane `user:*` set, and the system-admin-only actions —
        // the last two reach principals through the tier-1 policies, never
        // through a binding.
        let roleless = IAMRoleRegistry.identityActions
            .union(IAMRoleRegistry.systemAdminOnlyActions)
            .union(["project:create"])
        #expect(admin == IAMRoleRegistry.allActions.subtracting(roleless))
    }

    @Test("Canonical permit text enumerates exactly the role's expanded actions")
    func canonicalPermitEnumeratesActions() {
        for role in IAMRole.allCases {
            let text = descriptor(for: role).cedarText
            for action in IAMRoleRegistry.actions(for: role) {
                #expect(text.contains("Action::\"\(action)\""), "\(role.rawValue) permit misses \(action)")
            }
            // Nothing beyond the role's own set — the editor permit granting
            // an admin action is the failure mode explicit lists must avoid.
            for action in IAMRoleRegistry.allActions.subtracting(IAMRoleRegistry.actions(for: role)) {
                #expect(!text.contains("Action::\"\(action)\""), "\(role.rawValue) permit leaks \(action)")
            }
        }
    }

    @Test("Canonical permit matches only the role's own grants fields")
    func canonicalPermitUsesOwnGrantsFields() {
        for role in IAMRole.allCases {
            let text = descriptor(for: role).cedarText
            #expect(text.contains("context.grants[\"\(RoleDescriptor.grantsUsersField(role.seededID))\"]"))
            #expect(text.contains("context.grants[\"\(RoleDescriptor.grantsGroupsField(role.seededID))\"]"))
            for other in IAMRole.allCases where other != role {
                #expect(
                    !text.contains(RoleDescriptor.grantsUsersField(other.seededID)),
                    "\(role.rawValue) permit reads \(other.rawValue)'s grants")
            }
        }
    }

    @Test("Membership-derived project:create belongs to no seeded role")
    func membershipActionOutsideRoles() {
        for role in IAMRole.allCases {
            #expect(!IAMRoleRegistry.actions(for: role).contains("project:create"))
        }
    }

    // MARK: - Service groups

    @Test("Every action is a member of its service group")
    func serviceGroupMembership() {
        let decls = CedarSchemaBuilder.actionDecls()
        for action in IAMRoleRegistry.allActions.sorted() {
            let service = String(action.split(separator: ":", maxSplits: 1).first!)
            let groups = closure(of: action, in: decls)
            #expect(
                groups.contains(CedarSchemaBuilder.serviceGroupName(service)),
                "\(action) is not in \(CedarSchemaBuilder.serviceGroupName(service)) — a '\(service):*' ceiling would not cover it"
            )
        }
    }

    // MARK: - Inventory completeness

    @Test("Every registry action is declared exactly once, with appliesTo")
    func inventoryComplete() {
        let decls = CedarSchemaBuilder.actionDecls()
        let concrete = decls.filter { $0.resourceTypes != nil }
        #expect(Set(concrete.map(\.name)) == IAMRoleRegistry.allActions)
        #expect(concrete.count == IAMRoleRegistry.allActions.count)
        for decl in concrete {
            let types = decl.resourceTypes ?? []
            #expect(!types.isEmpty, "\(decl.name) applies to no resource type")
        }
    }

    @Test("Service groups carry no appliesTo — they cannot be requested")
    func groupsAreNotRequestable() {
        let decls = CedarSchemaBuilder.actionDecls()
        for decl in decls where decl.name.hasPrefix("svc:") {
            #expect(decl.resourceTypes == nil, "\(decl.name) should be a pure group")
        }
    }

    @Test("No role action-groups remain in the inventory")
    func noRoleGroups() {
        let decls = CedarSchemaBuilder.actionDecls()
        #expect(!decls.contains { $0.name.hasPrefix("role:") })
    }

    @Test("project:create excludes Project — projects do not nest")
    func projectCreateExcludesProject() {
        let types = CedarSchemaBuilder.resourceTypes(for: "project:create")
        #expect(!types.contains(.project))
        #expect(types.contains(.organization))
        #expect(types.contains(.folder))
    }

    // MARK: - Schema text

    @Test("Schema text declares the tree, the grants vocabulary, and the context")
    func schemaTextStructure() {
        let text = CedarSchemaBuilder.schemaText(roles: seededDescriptors)

        // Entity tree, with the OU → Folder rename in the Cedar vocabulary.
        #expect(text.contains("entity Folder in [Organization, Folder]"))
        #expect(text.contains("entity Project in [Organization, Folder]"))
        #expect(text.contains("entity VM in [Project]"))
        #expect(text.contains("entity User in [Group]"))
        #expect(!text.contains("OrganizationalUnit"))

        // Grants and context vocabulary: one field pair per role row.
        for role in seededDescriptors {
            #expect(text.contains("\"\(role.grantsUsersField)\": Set<User>"))
            #expect(text.contains("\"\(role.grantsGroupsField)\": Set<Group>"))
        }
        #expect(text.contains("\"mfa\"?: Bool"))
        #expect(text.contains("\"sourceIP\"?: ipaddr"))

        #expect(text.contains("action \"vm:start\" in [\"svc:vm\"]"))

        // Every node type declares an optional environment, so compiled
        // environment ceilings validate under strict mode on every type an
        // action can apply to.
        for entity in CedarEntityType.nodeTypes {
            #expect(text.contains("entity \(entity.rawValue) "), "missing entity declaration for \(entity.rawValue)")
        }
        #expect(text.contains("\"openToAllUsers\": Bool"))
    }

    @Test("Grants fields for user-created roles ride alongside the seeded ones")
    func grantsFieldsForUserRoles() {
        let custom = RoleDescriptor(
            id: UUID(),
            name: "auditor",
            cedarText: RoleDescriptor.canonicalPermitText(id: UUID(), actions: ["vm:read"]),
            actions: ["vm:read"]
        )
        let text = CedarSchemaBuilder.schemaText(roles: seededDescriptors + [custom])
        #expect(text.contains("\"\(custom.grantsUsersField)\": Set<User>"))
        #expect(text.contains("\"\(custom.grantsGroupsField)\": Set<Group>"))
    }

    @Test("Schema text is deterministic and order-independent")
    func schemaTextDeterministic() {
        let forward = CedarSchemaBuilder.schemaText(roles: seededDescriptors)
        let reversed = CedarSchemaBuilder.schemaText(roles: seededDescriptors.reversed())
        #expect(forward == reversed)
    }

    @Test("Every IAM node type maps to a distinct Cedar entity type")
    func nodeTypeMappingInjective() {
        let mapped = IAMNodeType.allCases.map(\.cedarEntityType)
        #expect(Set(mapped).count == IAMNodeType.allCases.count)
        #expect(IAMNodeType.organizationalUnit.cedarEntityType == .folder)
    }
}
