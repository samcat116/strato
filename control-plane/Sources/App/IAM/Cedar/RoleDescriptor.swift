import Foundation

// IAM roles/policies authoring, phase 1 (issue #604): the role definition as
// the Cedar builders consume it, and the one place Cedar-side role naming
// lives. The schema (`CedarSchemaBuilder`), the assembler
// (`CedarPolicyAssembler`), and the loader (`EntitySliceLoader`) all derive
// grants-field and policy-id names through here, so they can never disagree —
// a mismatch would be a permit that silently never matches.

/// A role definition row, engine- and database-free for testability.
struct RoleDescriptor: Equatable, Sendable {
    let id: UUID
    let name: String
    /// The role's permit in Cedar policy language — compiled verbatim. Empty
    /// text compiles to no permit (the role grants nothing), which is the
    /// state a freshly migrated seeded row is in until `RoleRegistrySync`
    /// writes the canonical text moments later.
    let cedarText: String
    /// The action list derived from `cedarText`'s action scope.
    let actions: [String]

    /// The compiled policy id — what decision logs name. The `role-` prefix
    /// is what `CedarCheckDecision.tier` keys "grant" on.
    var policyID: String { Self.policyID(id) }
    var grantsUsersField: String { Self.grantsUsersField(id) }
    var grantsGroupsField: String { Self.grantsGroupsField(id) }

    /// Cedar-side names use lowercased UUIDs, matching `CedarEntityUID`'s
    /// convention. (The `role_bindings.role` column stores `UUID.uuidString`
    /// uppercase — a database concern, normalized the moment a row is parsed.)
    static func policyID(_ id: UUID) -> String { "role-\(id.uuidString.lowercased())" }
    static func grantsUsersField(_ id: UUID) -> String { "\(id.uuidString.lowercased())Users" }
    static func grantsGroupsField(_ id: UUID) -> String { "\(id.uuidString.lowercased())Groups" }

    /// The canonical permit for an enumerable action list — what the server
    /// generates when a role is defined by picking actions. Advanced
    /// (user-authored) role text must keep the same shape apart from extra
    /// `when` conditions; `RoleStore` enforces that on write (issue #605).
    ///
    /// The action side is an explicit list rather than a schema action group:
    /// roles are flat (no implies chain), so a group would buy nothing and
    /// would churn the shared action inventory on every role write.
    static func canonicalPermitText(id: UUID, actions: some Sequence<String>) -> String {
        let actionList = actions.sorted()
            .map { "Action::\(CedarText.stringLiteral($0))" }
            .joined(separator: ", ")
        let policyID = policyID(id)
        return """
            @id(\(CedarText.stringLiteral(policyID)))
            permit (principal, action in [\(actionList)], resource)
            when {
                principal in context.grants[\(CedarText.stringLiteral(grantsUsersField(id)))] ||
                principal in context.grants[\(CedarText.stringLiteral(grantsGroupsField(id)))]
            };
            """
    }
}

extension RoleDescriptor {
    /// Descriptor for a role-definition row. Nil when the row has no id
    /// (unsaved model), which cannot reach the compile path.
    init?(row: IAMRoleDefinition) {
        guard let id = row.id else { return nil }
        self.init(id: id, name: row.name, cedarText: row.cedarText, actions: row.actions)
    }

    /// The seeded defaults as descriptors — the content `RoleRegistrySync`
    /// reconciles the managed rows to, and what tests compile against
    /// without a database.
    static func seededDefaults() -> [RoleDescriptor] {
        IAMRole.allCases.map { role in
            let actions = IAMRoleRegistry.actions(for: role).sorted()
            return RoleDescriptor(
                id: role.seededID,
                name: role.rawValue,
                cedarText: canonicalPermitText(id: role.seededID, actions: actions),
                actions: actions
            )
        }
    }
}
