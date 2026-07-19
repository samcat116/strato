import Foundation
import Testing

@testable import App

/// IAM phase 3 (issue #480): the generated Cedar schema.
///
/// The nesting-direction tests are the load-bearing ones. The design warns the
/// role-implication direction is easy to get backwards; with a finite action
/// inventory, comparing every action's group closure against
/// `IAMRoleRegistry.roles(granting:)` *is* the subsumption check — `action in
/// Action::"role:R"` matches exactly the closure computed here.
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

    // MARK: - Role-group nesting direction

    @Test("Every action's role-group closure matches the registry's granting roles")
    func roleGroupClosureMatchesRegistry() {
        let decls = CedarSchemaBuilder.actionDecls()
        for action in IAMRoleRegistry.allActions.sorted() {
            let expected = Set(
                IAMRoleRegistry.roles(granting: action).map { CedarSchemaBuilder.roleGroupName($0) })
            let actual = closure(of: action, in: decls).filter { $0.hasPrefix("role:") }
            #expect(
                actual == expected,
                "\(action): `action in role group` would match \(actual.sorted()), registry says \(expected.sorted())")
        }
    }

    @Test("Role groups nest lower-into-higher (viewer ∈ operator ∈ editor ∈ admin)")
    func roleGroupNestingDirection() {
        let decls = CedarSchemaBuilder.actionDecls()
        let byName = Dictionary(uniqueKeysWithValues: decls.map { ($0.name, $0) })

        // The lower role's group is a *member of* the higher one — that is
        // what makes `action in Action::"role:admin"` reach a viewer action.
        // The reversed declaration would make the viewer policy grant admin
        // actions, which is the failure mode the design warns about.
        #expect(byName["role:viewer"]?.memberOf == ["role:operator"])
        #expect(byName["role:operator"]?.memberOf == ["role:editor"])
        #expect(byName["role:editor"]?.memberOf == ["role:admin"])
        #expect(byName["role:admin"]?.memberOf == [])
    }

    @Test("Role subset chain holds under the closure: each role matches a superset of the one below")
    func roleClosuresAreNested() {
        let decls = CedarSchemaBuilder.actionDecls()
        func matched(by role: IAMRole) -> Set<String> {
            let group = CedarSchemaBuilder.roleGroupName(role)
            return Set(
                IAMRoleRegistry.allActions.filter { closure(of: $0, in: decls).contains(group) })
        }
        let viewer = matched(by: .viewer)
        let op = matched(by: .operator)
        let editor = matched(by: .editor)
        let admin = matched(by: .admin)

        #expect(viewer.isSubset(of: op))
        #expect(op.isSubset(of: editor))
        #expect(editor.isSubset(of: admin))
        // Strict subsets: each role must add something, or the chain is
        // degenerate and a declaration got lost.
        #expect(viewer != op)
        #expect(op != editor)
        #expect(editor != admin)
        #expect(admin == IAMRoleRegistry.allActions.subtracting(["project:create"]))
    }

    @Test("Membership-derived project:create belongs to no role group")
    func membershipActionOutsideRoles() {
        let decls = CedarSchemaBuilder.actionDecls()
        let roleGroups = closure(of: "project:create", in: decls).filter { $0.hasPrefix("role:") }
        #expect(roleGroups.isEmpty)
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

    @Test("Pure groups (roles and services) carry no appliesTo — they cannot be requested")
    func groupsAreNotRequestable() {
        let decls = CedarSchemaBuilder.actionDecls()
        for decl in decls where decl.name.hasPrefix("role:") || decl.name.hasPrefix("svc:") {
            #expect(decl.resourceTypes == nil, "\(decl.name) should be a pure group")
        }
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
        let text = CedarSchemaBuilder.schemaText()

        // Entity tree, with the OU → Folder rename in the Cedar vocabulary.
        #expect(text.contains("entity Folder in [Organization, Folder]"))
        #expect(text.contains("entity Project in [Organization, Folder]"))
        #expect(text.contains("entity VM in [Project]"))
        #expect(text.contains("entity User in [Group]"))
        #expect(!text.contains("OrganizationalUnit"))

        // Grants and context vocabulary.
        for role in IAMRole.allCases {
            #expect(text.contains("\"\(role.grantsUsersField)\": Set<User>"))
            #expect(text.contains("\"\(role.grantsGroupsField)\": Set<Group>"))
        }
        #expect(text.contains("\"mfa\"?: Bool"))
        #expect(text.contains("\"sourceIP\"?: ipaddr"))

        // Nesting direction as it will reach the engine.
        #expect(text.contains("action \"role:viewer\" in [\"role:operator\"];"))
        #expect(text.contains("action \"role:admin\";"))
        #expect(text.contains("action \"vm:start\" in [\"role:operator\", \"svc:vm\"]"))

        // Every node type declares an optional environment, so compiled
        // environment ceilings validate under strict mode on every type an
        // action can apply to.
        for entity in CedarEntityType.nodeTypes {
            #expect(text.contains("entity \(entity.rawValue) "), "missing entity declaration for \(entity.rawValue)")
        }
        #expect(text.contains("\"openToAllUsers\": Bool"))
    }

    @Test("Schema text is deterministic")
    func schemaTextDeterministic() {
        #expect(CedarSchemaBuilder.schemaText() == CedarSchemaBuilder.schemaText())
    }

    @Test("Every IAM node type maps to a distinct Cedar entity type")
    func nodeTypeMappingInjective() {
        let mapped = IAMNodeType.allCases.map(\.cedarEntityType)
        #expect(Set(mapped).count == IAMNodeType.allCases.count)
        #expect(IAMNodeType.organizationalUnit.cedarEntityType == .folder)
    }
}
