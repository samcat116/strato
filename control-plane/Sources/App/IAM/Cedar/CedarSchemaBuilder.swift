import Foundation

// IAM phase 3 (issue #480): the Cedar schema, generated from the role
// registry.
//
// The registry (`IAMRoleRegistry`) stays the curated source of truth for the
// action inventory and the role action-groups; the schema is derived from it
// rather than hand-maintained in parallel, so an action added to a role can
// never exist in one and not the other.

/// Generates the Cedar schema: entity types, the per-operation action
/// inventory, the nested role action-groups, per-service action groups (the
/// compilation target for `service:*` guardrail patterns), and the fixed
/// condition vocabulary as the request `Context`.
enum CedarSchemaBuilder {

    // MARK: - Action groups

    /// The action group holding a role's actions. A binding for role R becomes
    /// `action in Action::"role:R"` in the role policies.
    static func roleGroupName(_ role: IAMRole) -> String { "role:\(role.rawValue)" }

    /// The action group holding every action of one service (`vm`, `volume`,
    /// …). This is what a `vm:*` guardrail pattern compiles to, so a service
    /// ceiling keeps covering actions shipped after it was written — the
    /// wildcard resolves at evaluation time, not when the guardrail was saved.
    static func serviceGroupName(_ service: String) -> String { "svc:\(service)" }

    /// One action declaration. `resourceTypes` is nil for pure groups (the
    /// role and service groups), which can never be the action of a request.
    struct ActionDecl: Equatable, Sendable {
        let name: String
        /// The groups this action (or group) is a *member of*. Direction is
        /// the part that is easy to get backwards: the nesting
        /// `viewer ⊂ operator ⊂ editor ⊂ admin` means the **lower** group is a
        /// member of the **higher** one, so `action in Action::"role:admin"`
        /// transitively matches every action, while `role:viewer` matches only
        /// the viewer set. `CedarSchemaTests` verifies the closure of every
        /// concrete action against `IAMRoleRegistry.roles(granting:)`.
        let memberOf: [String]
        let resourceTypes: [CedarEntityType]?
    }

    /// The full action inventory: role groups, service groups, then every
    /// registry action, sorted for a deterministic schema.
    static func actionDecls() -> [ActionDecl] {
        var decls: [ActionDecl] = []

        // Role groups, highest first so each `memberOf` target is already
        // declared when read top-to-bottom. `containedBy(role)` is the role
        // whose action set is the next superset — admin for editor, and so on.
        for role in IAMRole.allCases.reversed() {
            let container = IAMRole.allCases.first { $0.implies == role }
            decls.append(
                ActionDecl(
                    name: roleGroupName(role),
                    memberOf: container.map { [roleGroupName($0)] } ?? [],
                    resourceTypes: nil
                ))
        }

        for service in IAMRoleRegistry.actionServices.sorted() {
            decls.append(ActionDecl(name: serviceGroupName(service), memberOf: [], resourceTypes: nil))
        }

        for action in IAMRoleRegistry.allActions.sorted() {
            var memberOf: [String] = []
            // The *lowest* role carrying the action — its direct home. Higher
            // roles reach it through the group nesting, and the membership
            // -derived actions (`project:create`) belong to no role at all.
            if let lowest = IAMRole.allCases.first(where: { IAMRoleRegistry.actions(for: $0).contains(action) }) {
                memberOf.append(roleGroupName(lowest))
            }
            if let service = action.split(separator: ":", maxSplits: 1).first {
                memberOf.append(serviceGroupName(String(service)))
            }
            decls.append(ActionDecl(name: action, memberOf: memberOf, resourceTypes: resourceTypes(for: action)))
        }
        return decls
    }

    // MARK: - appliesTo

    /// The container chain every project-scoped resource sits beneath.
    private static let projectContainers: [CedarEntityType] = [.project, .folder, .organization]

    /// The resource types an action can be requested against.
    ///
    /// Deliberately coarse in v1: each service's actions apply to the
    /// service's own entity types plus the containers above them, because
    /// `create`/`list` checks target a container (the resource does not exist
    /// yet) while everything else targets the resource. The one sharpened case
    /// is `project:create`, which excludes `Project` — "Projects do not nest"
    /// is a tier-0 invariant worth encoding where the validator can see it.
    static func resourceTypes(for action: String) -> [CedarEntityType] {
        if action == "project:create" { return [.folder, .organization] }
        let service = action.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
        switch service {
        case "vm": return [.vm] + projectContainers
        case "sandbox": return [.sandbox, .sandboxSnapshot] + projectContainers
        case "volume": return [.volume, .volumeSnapshot] + projectContainers
        case "image": return [.image] + projectContainers
        case "network": return [.network] + projectContainers
        case "operation": return [.vm, .sandbox] + projectContainers
        case "project": return projectContainers
        case "folder": return [.folder, .organization]
        case "org": return [.organization]
        case "group": return [.organization]
        case "quota": return projectContainers
        case "site": return [.site, .folder, .organization]
        case "agent": return [.agent, .folder, .organization]
        case "iam": return CedarEntityType.nodeTypes
        default:
            // A new service nobody mapped yet: the broadest valid answer, so
            // its actions validate everywhere rather than nowhere.
            return CedarEntityType.nodeTypes
        }
    }

    // MARK: - Schema text

    /// The Cedar schema in the human-readable schema format.
    static func schemaText() -> String {
        var lines: [String] = [
            "// Generated by CedarSchemaBuilder from IAMRoleRegistry (issue #480).",
            "// The registry is the curated source of truth; regenerate rather than edit.",
            "",
        ]

        // The flattened per-request grants the entity-slice loader computes
        // from `role_bindings`: bindings stay data read per-request from
        // Postgres (docs/architecture/iam.md), so they arrive in the request
        // context rather than in the compiled policy set. Users and groups are
        // separate sets because Cedar sets are homogeneous.
        lines.append("type Grants = {")
        for role in IAMRole.allCases {
            lines.append("    \(CedarText.stringLiteral(role.grantsUsersField)): Set<User>,")
            lines.append("    \(CedarText.stringLiteral(role.grantsGroupsField)): Set<Group>,")
        }
        lines.append("};")
        lines.append("")

        // The fixed condition vocabulary (`mfa`, `ip_range`) rides here;
        // `expires_at` is enforced when bindings are read and
        // `tags`/`environment` match the resource, so neither needs context.
        lines.append("type Context = {")
        lines.append("    \(CedarText.stringLiteral("grants")): Grants,")
        lines.append("    \(CedarText.stringLiteral("mfa"))?: Bool,")
        lines.append("    \(CedarText.stringLiteral("sourceIP"))?: ipaddr,")
        lines.append("};")
        lines.append("")

        lines.append("entity Group;")
        lines.append("entity User in [Group] {")
        lines.append("    \(CedarText.stringLiteral("memberOfOrgs")): Set<Organization>,")
        lines.append("    \(CedarText.stringLiteral("systemAdmin")): Bool,")
        lines.append("};")

        // `environment` is declared (optionally) on every node type, not just
        // the three that store one: an environment-conditioned guardrail
        // compiles to `resource has environment && …`, and the strict
        // validator rejects a `has` that can never be true. Container types
        // simply never carry the attribute at evaluation time.
        for entity in CedarEntityType.nodeTypes {
            let parents = parentTypes(for: entity)
            let head =
                parents.isEmpty
                ? "entity \(entity.rawValue)"
                : "entity \(entity.rawValue) in [\(parents.map(\.rawValue).joined(separator: ", "))]"
            var attrs = ["\(CedarText.stringLiteral("environment"))?: String"]
            if entity == .network {
                // A global network (no project) is readable by every
                // authenticated user — the tier-1 open-network policy keys on
                // this attribute.
                attrs.append("\(CedarText.stringLiteral("openToAllUsers")): Bool")
            }
            lines.append("\(head) {")
            for attr in attrs {
                lines.append("    \(attr),")
            }
            lines.append("};")
        }
        lines.append("")

        for decl in actionDecls() {
            var head = "action \(CedarText.stringLiteral(decl.name))"
            if !decl.memberOf.isEmpty {
                head += " in [\(decl.memberOf.map { CedarText.stringLiteral($0) }.joined(separator: ", "))]"
            }
            guard let resourceTypes = decl.resourceTypes else {
                lines.append("\(head);")
                continue
            }
            lines.append("\(head) appliesTo {")
            lines.append("    principal: [User],")
            lines.append("    resource: [\(resourceTypes.map(\.rawValue).joined(separator: ", "))],")
            lines.append("    context: Context,")
            lines.append("};")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// The legal Cedar parents of an entity type — the same one-parent tree
    /// `IAMResourceTree` walks, as membership declarations.
    private static func parentTypes(for entity: CedarEntityType) -> [CedarEntityType] {
        switch entity {
        case .organization: return []
        case .folder: return [.organization, .folder]
        case .project: return [.organization, .folder]
        case .vm, .sandbox, .image, .volume, .volumeSnapshot, .sandboxSnapshot:
            return [.project]
        case .network:
            // Project-scoped normally; a site-scoped network climbs to the
            // org or folder owning the site's capacity (`IAMResourceTree`).
            return [.project, .organization, .folder]
        case .site, .agent: return [.organization, .folder]
        case .user, .group: return []
        }
    }
}
