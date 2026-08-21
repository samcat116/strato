import Foundation

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
