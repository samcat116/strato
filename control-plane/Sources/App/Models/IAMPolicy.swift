/// The effect of an authored policy, derived from its Cedar text (issue #606).
///
/// Unlike a guardrail (forbid-only) or a role (permit-only), an authored policy
/// may be either: an org/project admin can hand out a grant its subtree does
/// not otherwise carry, or set a ceiling of its own. The effect is never sent
/// by the client — it is read off the parsed policy and stored so the catalog,
/// who-can, and the UI can label a policy without re-parsing.
enum IAMPolicyEffect: String, Codable, Sendable, CaseIterable {
    case permit
    case forbid
}
