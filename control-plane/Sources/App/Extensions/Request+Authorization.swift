import Fluent
import Vapor

// IAM phase 5 (issue #482): `req.can` is Cedar. The legacy SpiceDB-vocabulary
// form survives so the ~55 handler sites need not churn before #483 deletes
// SpiceDB outright: it translates the (permission, resourceType) pair to the
// IAM action naming the act being gated — the same mapping shadow evaluation
// validated — and evaluates it through `IAMAuthorizer`. The Cedar-native form
// lives in IAMAuthorizer.swift; new code should prefer it.

extension Request {
    /// Whether the current user holds `permission` on the given resource, in
    /// the legacy SpiceDB vocabulary.
    ///
    /// There is no system-admin short-circuit anymore: admins are allowed by
    /// the `platform-system-admin` tier-1 policy, which lands their decisions
    /// in the decision log and lets guardrail forbids bind them.
    ///
    /// A pair the translator cannot map fails closed — denied, logged, and
    /// recorded as `untranslated` in the decision log — because an
    /// untranslatable check is a check site nobody mapped, not an allowance.
    ///
    /// - Throws: `.unauthorized` if the request is unauthenticated.
    func can(_ permission: String, on resourceType: String, id: String) async throws -> Bool {
        guard let user = auth.get(User.self), let userID = user.id else {
            throw Abort(.unauthorized)
        }
        return try await IAMAuthorizer.checkLegacyVocabulary(
            userID: userID,
            permission: permission,
            resourceType: resourceType,
            resourceID: id,
            context: IAMCheckContext(path: url.path, method: method.rawValue, requestID: self.id),
            state: iamAuthState,
            app: application,
            db: db
        )
    }

    /// Enforce `permission` on the given resource, throwing `.forbidden` when
    /// the current user lacks it.
    ///
    /// - Throws: `.unauthorized` if unauthenticated, `.forbidden` if the check fails.
    func authorize(_ permission: String, on resourceType: String, id: String) async throws {
        guard try await can(permission, on: resourceType, id: id) else {
            throw Abort(.forbidden, reason: "Insufficient permissions for this operation")
        }
    }

    /// Convenience overload taking a `UUID` resource id.
    func authorize(_ permission: String, on resourceType: String, id: UUID) async throws {
        try await authorize(permission, on: resourceType, id: id.uuidString)
    }
}
