import Fluent
import Foundation
import Vapor

/// What a registered SPIFFE ID names (issue #491).
enum WorkloadRegistrationKind: String, Codable, CaseIterable, Sendable {
    /// A hypervisor-node agent. The registry row records the agent *name*
    /// (the SPIFFE path's identity, and `agents.name`): the agent row itself
    /// is created on first WebSocket connect, which can postdate enrollment.
    case agent
    /// A workload that authenticates as a `ServiceAccount` principal.
    case serviceAccount = "service_account"
    /// A directly registered customer workload with no service account behind
    /// it: the registration row itself is the principal
    /// (`IAMPrincipalType.workload`, principal id = row id).
    case workload
}

/// The workload registry (issue #491): one row per registered SPIFFE ID,
/// mapping it to the principal it names.
///
/// The SPIFFE ID is a **lookup key** and nothing more — no roles or claims
/// are ever parsed out of an SVID (docs/architecture/iam.md: "identity names
/// the principal; it never carries authorization"). What a registered
/// identity may do is answered by `role_bindings` against the principal this
/// row resolves to.
final class WorkloadRegistration: Model, Content, @unchecked Sendable {
    static let schema = "workload_registrations"

    @ID(key: .id)
    var id: UUID?

    /// The full SPIFFE URI (`spiffe://<trust-domain>/<path>`), unique across
    /// the registry: one identity, one principal.
    @Field(key: "spiffe_id")
    var spiffeID: String

    @Enum(key: "kind")
    var kind: WorkloadRegistrationKind

    /// For `kind == .agent`: the agent name the identity belongs to.
    @OptionalField(key: "agent_name")
    var agentName: String?

    /// For `kind == .serviceAccount`: the account this identity
    /// authenticates as. Cascade-deleted with the account.
    @OptionalParent(key: "service_account_id")
    var serviceAccount: ServiceAccount?

    /// For `kind == .workload`: the organization the registration is scoped
    /// to. Purely administrative scoping — it grants no access; the principal
    /// is *not* an org member (machine principals hold nothing by
    /// membership).
    @OptionalParent(key: "organization_id")
    var organization: Organization?

    /// Operator-facing label for `kind == .workload` registrations.
    @OptionalField(key: "display_name")
    var displayName: String?

    @OptionalField(key: "created_by")
    var createdBy: UUID?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        spiffeID: String,
        kind: WorkloadRegistrationKind,
        agentName: String? = nil,
        serviceAccountID: UUID? = nil,
        organizationID: UUID? = nil,
        displayName: String? = nil,
        createdBy: UUID? = nil
    ) {
        self.id = id
        self.spiffeID = spiffeID
        self.kind = kind
        self.agentName = agentName
        self.$serviceAccount.id = serviceAccountID
        self.$organization.id = organizationID
        self.displayName = displayName
        self.createdBy = createdBy
    }
}
