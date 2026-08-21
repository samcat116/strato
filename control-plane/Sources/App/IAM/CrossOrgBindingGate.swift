import ControlPlanePostgres
import Foundation
import Vapor

// IAM issue #485: cross-org bindings — the write-time gate and the loud audit.
//
// Cross-org access is allowed via explicit bindings only, and because `forbid`
// always wins in Cedar there is deliberately NO blanket platform forbid on it
// (docs/architecture/iam.md, "Cross-org access"). The controls live here
// instead: writing a binding whose principal is outside the resource's
// organization requires `iam:grantExternal` on the resource side — evaluated
// like every other action, guardrails included, so an org can ceiling it away
// — and the write is loud: a distinct audit event type, plus the `external`
// markers the members and who-can APIs carry.

enum CrossOrgBindingGate {

    static func rootOrganizationID(
        of node: IAMNode,
        using iam: IAMPersistence
    ) async throws -> UUID? {
        let chain = try await IAMResourceTree.ancestors(of: node, using: iam)
        guard let root = chain.last, root.type == .organization else { return nil }
        return root.id
    }

    /// The root organization of a tree node, from the same ancestor walk the
    /// evaluator's entity slice uses. Nil when the chain does not reach an org
    /// (a global network, or a dangling parent edge) — with no org there is
    /// nothing for a principal to be external *to*, so the gate does not
    /// apply.
    static func rootOrganizationID(of node: IAMNode, on db: PostgresStoreContext) async throws -> UUID? {
        let chain = try await IAMResourceTree.ancestors(of: node, on: db)
        guard let root = chain.last, root.type == .organization else { return nil }
        return root.id
    }

    /// Whether the principal lives outside `organizationID`: a user with no
    /// membership row there, or a group owned by another org. An unresolvable
    /// principal id counts as external — granting to a principal we cannot
    /// place must not slip past the gate.
    static func isExternal(
        principalType: IAMPrincipalType, principalID: UUID, organizationID: UUID, on db: PostgresStoreContext
    ) async throws -> Bool {
        switch principalType {
        case .user:
            return try await OrganizationMembershipStore.membership(
                userID: principalID, organizationID: organizationID, on: db) == nil
        case .group:
            guard let group = try await LegacyGroupSQLBridge.group(id: principalID, on: db) else {
                return true
            }
            return group.organizationID != organizationID
        case .serviceAccount:
            // A service account lives where its project lives (issue #491) —
            // unlike users, it has a home org derived from the tree rather
            // than memberships.
            guard let account = try await LegacyServiceAccountStore.account(
                id: principalID, on: db)
            else { return true }
            let root = try await rootOrganizationID(
                of: IAMNode(type: .project, id: account.projectID), on: db)
            return root != organizationID
        case .workload:
            // A registered workload is scoped to the org named on its
            // registration row; anything unresolvable is external.
            guard let registration = try await LegacyWorkloadRegistrationStore.registration(
                id: principalID, on: db),
                registration.kind == .workload,
                let registrationOrgID = registration.organizationID
            else { return true }
            return registrationOrgID != organizationID
        }
    }

    /// Whether a binding for this principal on this node crosses an org
    /// boundary — the question both the write-time gate and the loud-revoke
    /// paths start from.
    static func isCrossOrg(
        principalType: IAMPrincipalType, principalID: UUID, node: IAMNode, on db: PostgresStoreContext
    ) async throws -> Bool {
        guard let organizationID = try await rootOrganizationID(of: node, on: db) else { return false }
        return try await isExternal(
            principalType: principalType, principalID: principalID,
            organizationID: organizationID, on: db)
    }

    static func isCrossOrg(
        principalType: IAMPrincipalType,
        principalID: UUID,
        node: IAMNode,
        using iam: IAMPersistence
    ) async throws -> Bool {
        guard let organizationID = try await rootOrganizationID(of: node, using: iam) else {
            return false
        }
        return try await iam.principalIsExternal(
            type: principalType.rawValue,
            id: principalID,
            organizationID: organizationID
        )
    }

    /// Gate a proposed grant. When the principal is external to the node's
    /// root org, the actor needs `iam:grantExternal` on the node — through the
    /// evaluator like everything else, so guardrails and custom roles apply.
    ///
    /// Returns whether the grant crosses an org boundary, so the caller can
    /// make the successful write loud with `recordCrossOrgEvent` after its
    /// transaction commits. Call before opening that transaction.
    static func requireGrantPermitted(
        principalType: IAMPrincipalType,
        principalID: UUID,
        node: IAMNode,
        using iam: IAMPersistence,
        req: Request
    ) async throws -> Bool {
        guard
            try await isCrossOrg(
                principalType: principalType,
                principalID: principalID,
                node: node,
                using: iam
            )
        else { return false }
        guard try await req.can("iam:grantExternal", on: node) else {
            throw Abort(
                .forbidden,
                reason:
                    "The principal is outside this resource's organization; granting it a role requires the iam:grantExternal permission on the resource"
            )
        }
        return true
    }

    /// Record the distinct audit event that makes a cross-org grant (or the
    /// revoke that ends one) visible in the trail. Call after the binding
    /// write commits; audit backends never fail the request.
    static func recordCrossOrgEvent(
        _ type: AuditEventType,
        principalType: IAMPrincipalType,
        principalID: UUID,
        role: String?,
        node: IAMNode,
        using iam: IAMPersistence,
        req: Request
    ) async {
        let actor = req.auth.get(User.self)
        var metadata: [String: String] = [
            "principalType": principalType.rawValue,
            "principalId": principalID.uuidString,
        ]
        if let role { metadata["role"] = role }
        await req.audit.record(
            AuditRecord(
                eventType: type.rawValue,
                userID: actor?.id,
                username: actor?.username,
                apiKeyID: req.apiKey?.id,
                organizationID: try? await rootOrganizationID(of: node, using: iam),
                method: req.method.rawValue,
                path: req.url.path,
                resourceType: node.type.rawValue,
                resourceID: node.id.uuidString,
                action: type == .crossOrgGrant ? "iam:grantExternal" : nil,
                sourceIP: req.auditClientIP,
                metadata: metadata
            )
        )
    }
}
