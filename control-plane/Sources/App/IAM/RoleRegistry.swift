import Foundation

// IAM phase 1 (issue #477): the engine-independent role model — the bindings
// vocabulary the Cedar-based evaluator consumes (see
// docs/architecture/iam.md).

/// The kinds of principal a role binding can name. Workloads and service
/// accounts arrive in later phases.
enum IAMPrincipalType: String, Codable, Sendable, CaseIterable {
    case user
    case group
}

/// The tree nodes a role binding can attach to: the org hierarchy plus any
/// individual resource. Raw values are the wire resource-type names (also the
/// legacy check vocabulary's resource types).
enum IAMNodeType: String, Codable, Sendable, CaseIterable {
    case organization
    case organizationalUnit = "organizational_unit"
    case project
    case virtualMachine = "virtual_machine"
    case sandbox
    case image
    case network
    case floatingIP = "floating_ip"
    case volume
    case volumeSnapshot = "volume_snapshot"
    case sandboxSnapshot = "sandbox_snapshot"
    /// Org/folder-scoped infrastructure. Nothing binds directly to these yet —
    /// their access derives entirely from the container above — but they are
    /// real resources with `site:*` / `agent:*` actions in the registry, so
    /// reverse lookups must be able to name them.
    case site
    case agent
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
            "floatingip:read", "floatingip:list",
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
            "sandbox:snapshot", "sandbox:restore", "sandbox:export",
            "volume:create", "volume:update", "volume:delete",
            "volume:attach", "volume:detach",
            "volume:snapshot", "volume:clone", "volume:restore",
            "image:create", "image:update", "image:delete",
            "network:create", "network:update", "network:delete",
            "floatingip:create", "floatingip:release",
            "floatingip:attach", "floatingip:detach",
            "project:update",
        ],
        .admin: [
            // `iam:grantExternal` gates writing a binding whose principal is
            // outside the resource's organization (issue #485). It is a
            // *distinct* action rather than part of `iam:setPolicy` so custom
            // roles can withhold it and guardrails can ceiling it on its own.
            "iam:setPolicy", "iam:readPolicy", "iam:grantExternal",
            "project:transfer", "project:delete",
            "quota:manage",
            "group:manage",
            "folder:create", "folder:update", "folder:delete",
            "org:update", "org:delete",
            "agent:manage",
            "site:manage",
        ],
    ]

    /// Actions that bare org membership grants on its own, with no role
    /// binding behind them (docs/architecture/iam.md: "bare org membership
    /// grants `org:read` and `project:create` — nothing else"). Reverse
    /// lookups must add these, or they under-report every org member.
    static let membershipDerivedActions: Set<String> = ["org:read", "project:create"]

    /// Every action the registry knows, including the membership-derived ones
    /// that no role carries. This is the action *vocabulary*: guardrails
    /// validate exact action names against it so a typo can't create a ceiling
    /// that silently protects nothing.
    static let allActions: Set<String> =
        IAMRole.allCases.reduce(into: membershipDerivedActions) { $0.formUnion(actions(for: $1)) }

    /// The service prefixes appearing in `allActions` (`vm`, `volume`, `iam`,
    /// …) — the valid left-hand sides of a `service:*` guardrail pattern.
    static let actionServices: Set<String> = Set(
        allActions.compactMap { action in
            action.split(separator: ":", maxSplits: 1).first.map(String.init)
        })

    /// The roles whose expanded action group contains `action` — the set a
    /// binding must name to grant it. Empty for an action no role carries
    /// (e.g. `project:create`, which comes from membership instead).
    static func roles(granting action: String) -> Set<IAMRole> {
        Set(IAMRole.allCases.filter { actions(for: $0).contains(action) })
    }

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

    /// The binding role for a legacy resource-level relation
    /// (`owner`/`editor`/`viewer` on individual resources); `owner` maps to an
    /// explicit, revocable `admin` binding on the resource.
    static func fromResourceRelation(_ relation: String) -> IAMRole? {
        switch relation {
        case "owner": return .admin
        case "editor": return .editor
        case "viewer": return .viewer
        default: return nil
        }
    }
}
