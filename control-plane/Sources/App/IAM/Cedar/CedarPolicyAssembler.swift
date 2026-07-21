import Foundation

// IAM phase 3 (issue #480): assembly of the Cedar policy set.
//
// The compiled set holds exactly what changes only on a policy-set version
// bump: the platform (tier-1) policies, the role policies, and the guardrail
// (tier-2) forbids. Role *bindings* are deliberately absent — they are data,
// read per-request from Postgres and delivered by the entity-slice loader as
// `context.grants`, which is why grant/revoke needs no cache invalidation
// (docs/architecture/iam.md).

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
    /// the assembled set. The engine compiles from `staticPolicies()`.
    static func staticPolicyText() -> String {
        staticPolicies().map(\.text).joined(separator: "\n\n") + "\n"
    }

    /// The policies that depend on nothing but the registry. Every policy
    /// carries an `@id` so decision logs (#481) can name what decided.
    static func staticPolicies() -> [CedarPolicySource] {
        var policies: [CedarPolicySource] = []

        // The system-admin bypass as a tier-1 platform policy — the design's
        // replacement for today's middleware short-circuit, so it flows
        // through the evaluator and shows up in decision logs.
        policies.append(
            CedarPolicySource(
                id: "platform-system-admin",
                text: """
                    @id("platform-system-admin")
                    permit (principal, action, resource)
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
                    permit (principal, action in [\(membershipActions)], resource)
                    when { resource in principal.memberOfOrgs };
                    """))

        // One policy per role. The action side is the role's action group
        // (nested, so `role:admin` reaches everything); the principal side is
        // the flattened per-request grants the loader computed from
        // `role_bindings`. `principal in <Set<Group>>` resolves through the
        // principal's group parent edges, so a group grant covers its members.
        for role in IAMRole.allCases {
            policies.append(
                CedarPolicySource(
                    id: "role-\(role.rawValue)",
                    text: """
                        @id("role-\(role.rawValue)")
                        permit (principal, action in Action::\(CedarText.stringLiteral(CedarSchemaBuilder.roleGroupName(role))), resource)
                        when {
                            principal in context.grants[\(CedarText.stringLiteral(role.grantsUsersField))] ||
                            principal in context.grants[\(CedarText.stringLiteral(role.grantsGroupsField))]
                        };
                        """))
        }

        return policies
    }

    // MARK: - Guardrail forbids (tier 2)

    /// A guardrail the compiler had to leave out of the policy set, with the
    /// reason. Skipping is the same semantics `GuardrailStore` gives an
    /// unresolvable row (it matches nobody), but it is still a ceiling not
    /// being enforced, so the cache logs every one loudly.
    struct SkippedGuardrail: Equatable, Sendable {
        let id: UUID?
        let name: String
        let reason: String
    }

    struct GuardrailPolicySet: Sendable {
        let policies: [CedarPolicySource]
        let compiledGuardrailIDs: [UUID]
        let skipped: [SkippedGuardrail]

        /// The joined guardrail policy text, for display and tests.
        var policyText: String {
            policies.isEmpty ? "" : policies.map(\.text).joined(separator: "\n\n") + "\n"
        }
    }

    /// Compile guardrail rows into `forbid` policies.
    ///
    /// Structurally forbid-only: this function can emit nothing else, which is
    /// the compiler-side leg of the tier-2 invariant. Each policy's id is
    /// `guardrail-<row id>`, so a denial can name the exact ceiling in the
    /// way.
    ///
    /// `organizationIDsByGuardrail` carries the resolved organization of each
    /// `external_to_organization` guardrail's attach node (the caller walks
    /// the tree; this stays pure for testability). Embedding the org id in the
    /// compiled text is sound because attach nodes cannot move to another org
    /// without a delete/recreate, which bumps the policy-set version.
    static func guardrailPolicyText(
        _ guardrails: [Guardrail],
        organizationIDsByGuardrail: [UUID: UUID]
    ) -> GuardrailPolicySet {
        var policies: [CedarPolicySource] = []
        var compiled: [UUID] = []
        var skipped: [SkippedGuardrail] = []

        // Sorted for a deterministic policy set — rebuilds on two replicas
        // must produce identical text for the same version.
        let ordered = guardrails.sorted {
            ($0.id?.uuidString ?? "") < ($1.id?.uuidString ?? "")
        }

        for guardrail in ordered {
            guard let id = guardrail.id else {
                skipped.append(SkippedGuardrail(id: nil, name: guardrail.name, reason: "row has no id"))
                continue
            }
            guard let node = guardrail.node else {
                skipped.append(
                    SkippedGuardrail(id: id, name: guardrail.name, reason: "unknown node type '\(guardrail.nodeType)'"))
                continue
            }
            let principalMatch: GuardrailPrincipalMatch
            let resourceMatch: GuardrailResourceMatch
            do {
                principalMatch = try guardrail.principalMatch()
                resourceMatch = try guardrail.resourceMatch()
            } catch {
                skipped.append(SkippedGuardrail(id: id, name: guardrail.name, reason: "unreadable match: \(error)"))
                continue
            }

            var conditions: [String] = []

            let principalClause: String
            switch principalMatch {
            case .any:
                principalClause = "principal"
            case .user(let userID):
                principalClause = "principal == \(CedarEntityUID(type: .user, id: userID).cedarLiteral)"
            case .group(let groupID):
                // `in`, not `==`: the group is how a grant reaches a user, so
                // it must be how the ceiling does too. The principal's group
                // parent edges make this cover the members.
                principalClause = "principal in \(CedarEntityUID(type: .group, id: groupID).cedarLiteral)"
            case .externalToOrganization:
                // "External" is defined against the attach node's org. With no
                // resolvable org there is no outside to be on — the store
                // matches nobody, and so must the compiled set.
                guard let organizationID = organizationIDsByGuardrail[id] else {
                    skipped.append(
                        SkippedGuardrail(
                            id: id, name: guardrail.name,
                            reason:
                                "attach node resolves to no organization; an external-principal ceiling has nothing to be external to"
                        ))
                    continue
                }
                principalClause = "principal"
                let orgLiteral = CedarEntityUID(type: .organization, id: organizationID).cedarLiteral
                conditions.append("!(principal.memberOfOrgs.contains(\(orgLiteral)))")
            }

            let actionClause = self.actionClause(for: guardrail.actions)
            if let environmentCondition = self.environmentCondition(for: resourceMatch) {
                conditions.append(environmentCondition)
            }

            let policyID = "guardrail-\(id.uuidString.lowercased())"
            var policy = """
                @id("\(policyID)")
                forbid (\(principalClause), \(actionClause), resource in \(node.cedarUID.cedarLiteral))
                """
            if !conditions.isEmpty {
                policy += "\nwhen { \(conditions.joined(separator: " && ")) }"
            }
            policy += ";"
            policies.append(CedarPolicySource(id: policyID, text: policy))
            compiled.append(id)
        }

        return GuardrailPolicySet(
            policies: policies,
            compiledGuardrailIDs: compiled,
            skipped: skipped
        )
    }

    // MARK: - Clause builders
    //
    // Shared with the write-time check (#484), which re-expresses a guardrail
    // as a `permit` to ask whether a proposed grant can reach anything it
    // forbids. Two renderings of one row is exactly how the write-time answer
    // and the eval-time answer would come to disagree, so both go through
    // these.

    /// The `action` scope for a guardrail's patterns.
    ///
    /// A `service:*` pattern compiles to the schema's per-service action group
    /// rather than to today's members, which is what keeps a ceiling covering
    /// actions shipped after it was written.
    static func actionClause(for actions: [String]) -> String {
        if actions.contains(GuardrailActions.wildcard) { return "action" }
        let refs = actions.map { pattern -> String in
            if pattern.hasSuffix(":*") {
                let service = String(pattern.dropLast(2))
                return "Action::\(CedarText.stringLiteral(CedarSchemaBuilder.serviceGroupName(service)))"
            }
            return "Action::\(CedarText.stringLiteral(pattern))"
        }
        return "action in [\(refs.joined(separator: ", "))]"
    }

    /// The `when` condition for a resource-side match, if it constrains
    /// anything.
    ///
    /// Matches the resource being acted on, never its ancestry: environment is
    /// an attribute, not a container. A resource with no environment is in no
    /// environment, so `has` guards the ceiling off it.
    static func environmentCondition(for match: GuardrailResourceMatch) -> String? {
        switch match {
        case .any:
            return nil
        case .environment(let environment):
            return "resource has environment && resource.environment == \(CedarText.stringLiteral(environment))"
        }
    }
}
