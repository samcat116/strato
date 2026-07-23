import Foundation

// IAM phase 3 (issue #480): assembly of the Cedar policy set.
//
// The compiled set holds exactly what changes only on a policy-set version
// bump: the platform (tier-1) policies, the role policies, and the guardrail
// (tier-2) forbids. Role *bindings* are deliberately absent — they are data,
// read per-request from Postgres and delivered by the entity-slice loader as
// `context.grants`, which is why grant/revoke needs no cache invalidation
// (docs/architecture/iam.md).
//
// This assembler covers the permit tiers (platform, roles, authored
// policies). The tier-2 guardrail forbids render in `GuardrailRendering`,
// which owns every rendering of a guardrail row so they cannot drift.

/// One policy of the compiled set, with the id the engine registers it under.
///
/// The id travels *next to* the text, not only as the `@id` annotation inside
/// it: Cedar's set parser assigns positional `policy0`-style ids and treats
/// `@id` as an ordinary annotation, so a set parsed as one blob could never
/// name `role-editor` or `guardrail-<id>` in a decision. The engine parses
/// each policy individually with this id instead (the annotation stays in the
/// text for human readers of the assembled set).
struct CedarPolicySource: Equatable, Sendable {
    let id: String
    let text: String
}

enum CedarPolicyAssembler {

    // MARK: - Static policies (tier 1 + tier 3 role policies)

    /// The joined static policy text, for display and for tests asserting on
    /// the assembled set. The engine compiles from `staticPolicies(roles:)`.
    static func staticPolicyText(roles: [RoleDescriptor]) -> String {
        staticPolicies(roles: roles).map(\.text).joined(separator: "\n\n") + "\n"
    }

    /// The platform (tier-1) policies plus one permit per role-definition
    /// row. Every policy carries an `@id` so decision logs (#481) can name
    /// what decided.
    static func staticPolicies(roles: [RoleDescriptor]) -> [CedarPolicySource] {
        var policies: [CedarPolicySource] = []

        // The system-admin bypass as a tier-1 platform policy — the design's
        // replacement for today's middleware short-circuit, so it flows
        // through the evaluator and shows up in decision logs. Scoped to
        // `principal is User` (as is org-membership below): system-admin and
        // org membership are user concepts, and the workload principal types
        // (issue #491) carry neither attribute — an unscoped `principal.…`
        // access would fail strict validation in their request environments.
        policies.append(
            CedarPolicySource(
                id: "platform-system-admin",
                text: """
                    @id("platform-system-admin")
                    permit (principal is User, action, resource)
                    when { principal.systemAdmin };
                    """))

        // A global network — one with no project — is readable by every
        // authenticated user, because it is the fallback every VM create can
        // land on. Today a special case in `NetworkController` and `who-can`;
        // here it is an ordinary tier-1 permit.
        policies.append(
            CedarPolicySource(
                id: "platform-open-network-read",
                text: """
                    @id("platform-open-network-read")
                    permit (principal, action == Action::"network:read", resource is Network)
                    when { resource.openToAllUsers };
                    """))

        // Bare org membership grants `org:read` + `project:create` — nothing
        // else. `resource in principal.memberOfOrgs` covers both the org
        // itself and a folder beneath it (the entity slice carries the parent
        // chain), matching "anywhere in the org" for project creation.
        let membershipActions = IAMRoleRegistry.membershipDerivedActions.sorted()
            .map { "Action::\(CedarText.stringLiteral($0))" }
            .joined(separator: ", ")
        policies.append(
            CedarPolicySource(
                id: "org-membership",
                text: """
                    @id("org-membership")
                    permit (principal is User, action in [\(membershipActions)], resource)
                    when { resource in principal.memberOfOrgs };
                    """))

        // One permit per role-definition row, compiled from the row's Cedar
        // text verbatim (the text's action side is an explicit action list;
        // its principal side is the flattened per-request grants the loader
        // computed from `role_bindings` — `principal in <Set<Group>>`
        // resolves through the principal's group parent edges, so a group
        // grant covers its members). Empty text means the role grants
        // nothing yet — the state a freshly migrated seeded row is in until
        // `RoleRegistrySync` writes it, never worth failing a compile over.
        // Ordered by id for a deterministic set.
        for role in roles.sorted(by: { $0.id.uuidString < $1.id.uuidString })
        where !role.cedarText.isEmpty {
            policies.append(CedarPolicySource(id: role.policyID, text: role.cedarText))
        }

        return policies
    }

    // MARK: - Authored policies (issue #606)

    /// One `CedarPolicySource` per authored-policy row, compiled from the row's
    /// Cedar text verbatim under the id `policy-<row id>`. Empty text is
    /// dropped — an authored policy has no schema fields to keep declared, so a
    /// row that compiles to nothing simply is not in the set. Ordered by id for
    /// a deterministic set.
    static func authoredPolicySources(_ policies: [PolicyDescriptor]) -> [CedarPolicySource] {
        policies.sorted { $0.id.uuidString < $1.id.uuidString }
            .filter { !$0.cedarText.isEmpty }
            .map { CedarPolicySource(id: $0.policyID, text: $0.cedarText) }
    }

    /// The joined authored-policy text, for display and tests.
    static func authoredPolicyText(_ policies: [PolicyDescriptor]) -> String {
        let sources = authoredPolicySources(policies)
        return sources.isEmpty ? "" : sources.map(\.text).joined(separator: "\n\n") + "\n"
    }
}
