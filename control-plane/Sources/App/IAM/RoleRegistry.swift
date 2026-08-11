import Foundation

// IAM phase 1 (issue #477): the engine-independent role model — the bindings
// vocabulary the Cedar-based evaluator consumes (see
// docs/architecture/iam.md).

/// The kinds of principal a role binding can name.
///
/// `serviceAccount` and `workload` are the machine principals of the workload
/// registry (issue #491): a service account is a durable, project-scoped
/// principal that SPIFFE identities authenticate *as*; a `workload` is a
/// directly registered SPIFFE identity (`workload_registrations` row) with no
/// service account behind it. Machine principals hold nothing by membership —
/// no groups, no org membership — so every grant they have is an explicit,
/// listable binding.
enum IAMPrincipalType: String, Codable, Sendable, CaseIterable {
    case user
    case group
    case serviceAccount = "service_account"
    case workload

    /// The table whose rows this principal type names — the model's own
    /// `schema`, the same contract `IAMNodeType.table` carries and for the
    /// same reason: `ResourceBindingCleanup`'s tests hold the declared
    /// cascading principals against the real foreign keys, and a principal
    /// table that cascades away with a container strands its bindings exactly
    /// as a node table does.
    var table: String {
        switch self {
        case .user: return User.schema
        case .group: return Group.schema
        case .serviceAccount: return ServiceAccount.schema
        case .workload: return WorkloadRegistration.schema
        }
    }
}

/// A typed principal reference — the subject of an authorization check.
///
/// Groups are deliberately representable (they are binding subjects) but are
/// never *request* principals: a group does not act, its members do.
struct IAMPrincipal: Hashable, Sendable {
    let type: IAMPrincipalType
    let id: UUID

    static func user(_ id: UUID) -> IAMPrincipal { IAMPrincipal(type: .user, id: id) }
    static func serviceAccount(_ id: UUID) -> IAMPrincipal { IAMPrincipal(type: .serviceAccount, id: id) }
    static func workload(_ id: UUID) -> IAMPrincipal { IAMPrincipal(type: .workload, id: id) }

    /// The request principal for a binding subject, or nil for a group — the
    /// gate that keeps groups out of the evaluator. A group does not act (its
    /// members do, through their group parent edges), and the compiled schema
    /// declares no request environment for it.
    static func requestPrincipal(type: IAMPrincipalType, id: UUID) -> IAMPrincipal? {
        guard type != .group else { return nil }
        return IAMPrincipal(type: type, id: id)
    }

    /// The decision-log subject string. Users keep the bare UUID the log has
    /// always recorded; other principal types are disambiguated with their
    /// type (`service_account:<uuid>`), which cannot collide with a UUID.
    var subject: String {
        type == .user ? id.uuidString : "\(type.rawValue):\(id.uuidString)"
    }
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
    case loadBalancer = "load_balancer"
    case securityGroup = "security_group"
    /// A DNS zone (issue #770) — a project-scoped resource, like a network.
    case dnsZone = "dns_zone"
    /// An authored DNS record. Unlike the snapshot types, whose container is
    /// the project because they only *reference* their parent resource, a
    /// record's container really is its zone: it cannot exist without one, and
    /// delegating a zone must carry its records with it.
    case dnsRecord = "dns_record"
    case volume
    case volumeSnapshot = "volume_snapshot"
    case sandboxSnapshot = "sandbox_snapshot"
    /// A full-VM checkpoint (issue #564) — RAM + device state, distinct from
    /// the disk-only `volumeSnapshot`.
    case vmSnapshot = "vm_snapshot"
    /// Org/folder-scoped infrastructure. Nothing binds directly to these yet —
    /// their access derives entirely from the container above — but they are
    /// real resources with `site:*` / `agent:*` actions in the registry, so
    /// reverse lookups must be able to name them.
    case site
    case agent
    /// A service account is both a resource (it can be read, deleted, and
    /// impersonated — bindings and guardrails attach to it under its project)
    /// and a principal (`IAMPrincipalType.serviceAccount`).
    case serviceAccount = "service_account"
    /// A user record, as the *target* of a `user:*` action. Like
    /// `serviceAccount` this type is both principal and resource, but unlike
    /// every other node it is parentless: a user belongs to organizations
    /// (a set, via `memberOfOrgs`), not to one place in the tree. Nothing
    /// inherits down to it and no binding meaningfully attaches to it — access
    /// comes from the two tier-1 policies, `platform-user-self` and
    /// `platform-system-admin`. It is a node type so that identity-plane
    /// checks go through the one evaluator path rather than a controller-local
    /// `isSystemAdmin` read.
    case user

    /// The canonical action that reads this node. Snapshot and DNS record
    /// nodes intentionally share their parent service's action vocabulary.
    var readAction: String {
        switch self {
        case .organization: return "org:read"
        case .organizationalUnit: return "folder:read"
        case .project: return "project:read"
        case .virtualMachine, .vmSnapshot: return "vm:read"
        case .sandbox, .sandboxSnapshot: return "sandbox:read"
        case .image: return "image:read"
        case .network: return "network:read"
        case .floatingIP: return "floatingip:read"
        case .loadBalancer: return "loadbalancer:read"
        case .securityGroup: return "securitygroup:read"
        case .dnsZone, .dnsRecord: return "dns:read"
        case .volume, .volumeSnapshot: return "volume:read"
        case .site: return "site:read"
        case .agent: return "agent:read"
        case .serviceAccount: return "serviceaccount:read"
        case .user: return "user:read"
        }
    }

    /// The table whose rows this node type names — the model's own `schema`,
    /// never a guess from the case name (`virtual_machine` → `vms`).
    ///
    /// Every node type is backed by exactly one UUID-keyed table, so this is
    /// total rather than optional, and the exhaustive switch makes a new node
    /// type a compile error here: anything that reasons about whether a node
    /// still exists (the orphaned-binding sweep, the cascade-coverage guard in
    /// `ResourceBindingCleanup`'s tests) has to be told where to look.
    var table: String {
        switch self {
        case .organization: return Organization.schema
        case .organizationalUnit: return OrganizationalUnit.schema
        case .project: return Project.schema
        case .virtualMachine: return VM.schema
        case .sandbox: return Sandbox.schema
        case .image: return Image.schema
        case .network: return LogicalNetwork.schema
        case .floatingIP: return FloatingIP.schema
        case .loadBalancer: return LoadBalancer.schema
        case .securityGroup: return SecurityGroup.schema
        case .dnsZone: return DNSZone.schema
        case .dnsRecord: return DNSRecord.schema
        case .volume: return Volume.schema
        case .volumeSnapshot: return VolumeSnapshot.schema
        case .sandboxSnapshot: return SandboxSnapshot.schema
        case .vmSnapshot: return VMSnapshot.schema
        case .site: return Site.schema
        case .agent: return Agent.schema
        case .serviceAccount: return ServiceAccount.schema
        case .user: return User.schema
        }
    }
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
            "loadbalancer:read", "loadbalancer:list",
            "securitygroup:read", "securitygroup:list",
            "dns:read", "dns:list",
            "serviceaccount:read", "serviceaccount:list",
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
            // Full-VM checkpoints (issue #564). Editor, matching
            // `sandbox:snapshot`/`sandbox:restore`: taking one is cheap and
            // non-destructive, but restoring rewinds the machine, so both sit
            // above the operator's start/stop verbs.
            "vm:snapshot", "vm:restore",
            "sandbox:create", "sandbox:update", "sandbox:delete",
            "sandbox:snapshot", "sandbox:restore", "sandbox:export",
            "volume:create", "volume:update", "volume:delete",
            "volume:attach", "volume:detach",
            "volume:snapshot", "volume:clone", "volume:restore",
            "image:create", "image:update", "image:delete",
            "network:create", "network:update", "network:delete",
            "floatingip:create", "floatingip:release",
            "floatingip:attach", "floatingip:detach",
            "loadbalancer:create", "loadbalancer:update", "loadbalancer:delete",
            "securitygroup:create", "securitygroup:update", "securitygroup:delete",
            "securitygroup:attach", "securitygroup:detach",
            // Zones and records share one service: they are one authoring
            // surface, and a role that can write records but not the zone
            // holding them isn't a distinction anyone has asked for.
            // `attach`/`detach` gate binding a zone to a logical network.
            "dns:create", "dns:update", "dns:delete",
            "dns:attach", "dns:detach",
            "serviceaccount:create", "serviceaccount:update", "serviceaccount:delete",
            "project:update",
        ],
        .admin: [
            // `iam:grantExternal` gates writing a binding whose principal is
            // outside the resource's organization (issue #485). It is a
            // *distinct* action rather than part of `iam:setPolicy` so custom
            // roles can withhold it and guardrails can ceiling it on its own.
            "iam:setPolicy", "iam:readPolicy", "iam:grantExternal",
            // Impersonation lets a caller act as the service account — a
            // grant-shaped power, so it sits with the other admin actions
            // rather than in editor (issue #491).
            "serviceaccount:impersonate",
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

    /// Identity-plane actions on a `User` record. No role carries them, by
    /// design: a caller reaches their *own* record through the tier-1
    /// `platform-user-self` policy, and reaching anyone else's is the
    /// `platform-system-admin` policy's business. They are in the vocabulary
    /// so the schema declares them and the decision log can name them. Note
    /// that a guardrail cannot currently ceiling them: guardrails compile to
    /// `resource in <node>` and a user record is parentless, so nothing is
    /// ever `in` one (docs/architecture/iam.md).
    ///
    /// There is deliberately no `user:list` or `user:create`. Listing filters
    /// per row on `user:read` like every other list endpoint, and creating an
    /// invite has no existing record to name as its resource — it stays a
    /// `requireSystemAdmin()` surface, with the other node-less platform
    /// plumbing.
    static let identityActions: Set<String> = ["user:read", "user:update", "user:delete"]

    /// The read half of `identityActions`.
    ///
    /// A user record is parentless, so it sits in no subtree and a node-scoped
    /// credential could never reach one — which would break `strato whoami` and
    /// the frontend's identity bootstrap for every scoped token. That argument
    /// is entirely about *reading* a record, so only the read half is exempt
    /// from a restriction's node scope (STR-115): a token issued for one
    /// project must not be able to delete users anywhere, which is exactly the
    /// reach `requireSystemAdmin` refuses it on every other platform surface.
    static let identityReadActions: Set<String> = identityActions.intersection(readActions)

    /// In-guest command execution on a VM (the guest-agent stack, issue #804):
    /// `vm:exec` is an interactive session, `vm:runCommand` a non-interactive
    /// run with its output captured.
    ///
    /// **No seeded role carries either**, deliberately — not `editor`, not
    /// `admin`. Both are root-on-VM, and a seeded role is inherited down the
    /// whole subtree it is bound on, so a default role carrying them would
    /// confer a shell on every VM beneath every binding written for any other
    /// reason. They are reachable through a custom role somebody authored on
    /// purpose (the binding row being the audit trail), or through the tier-1
    /// `platform-system-admin` policy, which reaches everything.
    ///
    /// The two are equal in privilege — a one-shot `sh -c` is a shell — and
    /// differ only in what the platform can attest to afterwards, which is why
    /// they are separable at all. docs/architecture/iam.md ("In-guest execution
    /// is never in a default role") carries the full argument for both halves
    /// of the decision; keep it there rather than growing a second copy here.
    static let guestExecutionActions: Set<String> = ["vm:exec", "vm:runCommand"]

    /// Actions no seeded role carries and only the tier-1
    /// `platform-system-admin` policy reaches. `agent:updateArtifact` overrides
    /// the agent's update artifact with an arbitrary URL — that binary is
    /// installed and run as the agent on the hypervisor host, so it is a
    /// strictly larger power than `agent:manage` and gets a name of its own
    /// rather than riding along inside it. A custom role can grant it
    /// deliberately; nothing grants it by accident.
    static let systemAdminOnlyActions: Set<String> = ["agent:updateArtifact"]

    /// Every action whose name says it reads — the symbolic `read` credential
    /// restriction (STR-115).
    ///
    /// Derived from the names rather than curated, so an action shipped later
    /// lands on the right side by default: a new `:read`/`:list` is readable, a
    /// new verb is not. `image:download` and `iam:readPolicy` are named
    /// explicitly because they read without saying so in their suffix, and a
    /// read-only credential reaches both today.
    ///
    /// Three actions a `read` credential can reach on a safe method today are
    /// deliberately *not* here, and lose that reach when their credential's
    /// restriction is enforced against the act instead of the HTTP verb:
    /// `sandbox:exec` (the exec-attach WebSocket is a GET), `vm:viewConsole`
    /// (an editor action the console upgrade also reaches by GET), and
    /// `vm:exec`/`vm:runCommand` (no routes yet). All three are the defect
    /// STR-115 exists to close, not collateral.
    static let readActions: Set<String> =
        allActions.filter { $0.hasSuffix(":read") || $0.hasSuffix(":list") }
        .union(["image:download", "iam:readPolicy"])

    /// The actions the tier-1 `platform-agent-foreign-workloads` forbid
    /// covers. Read by the policy text *and* by the entity-slice loader, which
    /// only pays for the workload-inventory attribute on these actions — one
    /// constant, so the two can never drift into a silently detached ceiling.
    static let agentForeignWorkloadGuardedActions: Set<String> = ["agent:manage"]

    /// Every action the registry knows, including the membership-derived ones
    /// that no role carries. This is the action *vocabulary*: guardrails
    /// validate exact action names against it so a typo can't create a ceiling
    /// that silently protects nothing.
    static let allActions: Set<String> =
        IAMRole.allCases.reduce(
            into: membershipDerivedActions.union(identityActions).union(systemAdminOnlyActions)
                .union(guestExecutionActions)
        ) {
            $0.formUnion(actions(for: $1))
        }

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
