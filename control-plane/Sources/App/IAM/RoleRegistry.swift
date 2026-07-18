import Foundation

// IAM phase 1 (issue #477): the engine-independent role model. SpiceDB remains
// the authorization source of truth for now; these types define the bindings
// vocabulary that the Cedar-based evaluator will consume after cutover (see
// docs/architecture/iam.md).

/// The kinds of principal a role binding can name. Workloads and service
/// accounts arrive in later phases.
enum IAMPrincipalType: String, Codable, Sendable, CaseIterable {
    case user
    case group
}

/// The tree nodes a role binding can attach to: the org hierarchy plus any
/// individual resource. Raw values match the SpiceDB object-type names so the
/// backfill from a SpiceDB relationship export maps 1:1.
enum IAMNodeType: String, Codable, Sendable, CaseIterable {
    case organization
    case organizationalUnit = "organizational_unit"
    case project
    case virtualMachine = "virtual_machine"
    case sandbox
    case image
    case network
    case volume
    case volumeSnapshot = "volume_snapshot"
    case sandboxSnapshot = "sandbox_snapshot"
}

/// The global roles. Each role is a curated action group that implies the one
/// below it: `viewer ⊂ operator ⊂ editor ⊂ admin`. Roles are deliberately
/// global (one set across all resource types), not per-service.
enum IAMRole: String, Codable, Sendable, CaseIterable {
    case viewer
    case `operator`
    case editor
    case admin

    /// The next role down in the nesting chain (`admin` implies `editor`, …).
    var implies: IAMRole? {
        switch self {
        case .viewer: return nil
        case .operator: return .viewer
        case .editor: return .operator
        case .admin: return .editor
        }
    }
}

/// The curated action-group registry. Membership is a reviewable schema change:
/// a new API action joins a role here by explicit decision, never by default
/// (the deliberate inverse of GCP's auto-absorbing basic roles).
enum IAMRoleRegistry {
    /// Actions granted *directly* by each role, excluding what it inherits via
    /// `implies`. Use `actions(for:)` for the full expanded group.
    static let directActions: [IAMRole: Set<String>] = [
        .viewer: [
            "vm:read", "vm:list",
            "sandbox:read", "sandbox:list",
            "volume:read", "volume:list",
            "image:read", "image:list", "image:download",
            "network:read", "network:list",
            "project:read",
            "folder:read",
            "org:read",
            "group:read",
            "quota:read",
            "agent:read",
            "site:read",
            "operation:read",
        ],
        .operator: [
            "vm:start", "vm:stop", "vm:restart", "vm:pause", "vm:resume",
            "sandbox:start", "sandbox:stop", "sandbox:restart", "sandbox:exec",
        ],
        .editor: [
            "vm:create", "vm:update", "vm:delete", "vm:viewConsole",
            "sandbox:create", "sandbox:update", "sandbox:delete",
            "sandbox:snapshot", "sandbox:restore",
            "volume:create", "volume:update", "volume:delete",
            "volume:attach", "volume:detach",
            "volume:snapshot", "volume:clone", "volume:restore",
            "image:create", "image:update", "image:delete",
            "network:create", "network:update", "network:delete",
            "project:update",
        ],
        .admin: [
            "iam:setPolicy", "iam:readPolicy",
            "project:transfer", "project:delete",
            "quota:manage",
            "group:manage",
            "folder:create", "folder:update", "folder:delete",
            "org:update", "org:delete",
            "agent:manage",
            "site:manage",
        ],
    ]

    /// The full expanded action group for a role: its direct actions plus
    /// everything from the roles it implies.
    static func actions(for role: IAMRole) -> Set<String> {
        var result: Set<String> = []
        var current: IAMRole? = role
        while let role = current {
            result.formUnion(directActions[role] ?? [])
            current = role.implies
        }
        return result
    }
}

// MARK: - Mapping today's roles onto the global roles

extension IAMRole {
    /// The binding role for a `UserOrganization.role` value. Bare org
    /// membership ("member") maps to *no* binding: under the new model it
    /// grants only `org:read` + `project:create`, derived from membership
    /// itself rather than a role binding.
    static func fromOrganizationRole(_ role: String) -> IAMRole? {
        role == "admin" ? .admin : nil
    }

    /// The binding role for a project role (user or group grants).
    static func fromProjectRole(_ role: ProjectRole) -> IAMRole {
        switch role {
        case .admin: return .admin
        case .member: return .editor
        case .viewer: return .viewer
        }
    }

    /// The binding role for a resource-level SpiceDB relation
    /// (`owner`/`editor`/`viewer` tuples on individual resources). Used by the
    /// one-time SpiceDB export backfill; `owner` becomes an explicit,
    /// revocable `admin` binding on the resource.
    static func fromResourceRelation(_ relation: String) -> IAMRole? {
        switch relation {
        case "owner": return .admin
        case "editor": return .editor
        case "viewer": return .viewer
        default: return nil
        }
    }
}
