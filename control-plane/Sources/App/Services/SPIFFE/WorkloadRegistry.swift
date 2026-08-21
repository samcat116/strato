import ControlPlanePostgres
import Foundation
import Vapor

// The workload registry (issue #491): SPIFFE IDs become principals by
// *registration*, never by parsing. A SPIFFE URI is the lookup key into
// `workload_registrations`; the row says what the identity names — an agent,
// a service account, or a directly registered workload — and role bindings
// against that principal say what it may do.

/// The principal a registered SPIFFE ID resolves to.
enum ResolvedWorkload: Equatable, Sendable {
    /// A hypervisor-node agent, named as `agents.name`. Agents authenticate
    /// the transport (WebSocket / artifact mTLS); they are not Cedar request
    /// principals today.
    case agent(name: String)
    /// A workload authenticating as a service-account principal.
    case serviceAccount(id: UUID)
    /// A directly registered workload principal (the registration row id).
    case workload(id: UUID)

    /// The IAM principal for machine principals; nil for agents.
    var principal: IAMPrincipal? {
        switch self {
        case .agent: return nil
        case .serviceAccount(let id): return .serviceAccount(id)
        case .workload(let id): return .workload(id)
        }
    }
}

enum WorkloadRegistry {

    /// Platform-owned namespaces that registration APIs must never allow a
    /// caller to claim. Each message suffix describes the lifecycle that owns
    /// the identity so API errors explain how the namespace is populated.
    private static let reservedNamespaces: [(prefix: String, owner: String)] = [
        ("/agent/", "hypervisor agents, which register automatically when they first connect"),
        ("/vm/", "guest virtual machines, which register automatically when they are created"),
        ("/sandbox/", "guest sandboxes, which register automatically when they are created"),
    ]

    /// Validate a SPIFFE URI supplied to a registration API, returning it
    /// normalized.
    ///
    /// Beyond the syntax check, platform-minted namespaces are refused
    /// outright. Allowing an API caller to pre-register one would let them
    /// squat on an identity before its agent, VM, or sandbox lifecycle claims
    /// it, denying the genuine workload its identity.
    static func validateRegistrable(spiffeID: String) throws -> String {
        guard let identity = SPIFFEIdentity(uri: spiffeID) else {
            throw Abort(.badRequest, reason: "Not a valid SPIFFE URI (spiffe://<trust-domain>/<path>)")
        }
        if let namespace = reservedNamespaces.first(where: { identity.path.hasPrefix($0.prefix) }) {
            throw Abort(
                .badRequest,
                reason: "The \(namespace.prefix) SPIFFE namespace is reserved for \(namespace.owner)"
            )
        }
        return identity.uri
    }

    /// Resolve a SPIFFE URI to the principal it registers, or nil for an
    /// unregistered identity.
    static func resolve(
        spiffeID: String, using workloads: WorkloadsPersistence
    ) async throws -> ResolvedWorkload? {
        guard let row = try await workloads.registration(spiffeID: spiffeID)
        else { return nil }
        return resolved(row)
    }

    /// The resolution of one registry row; nil when the row is internally
    /// inconsistent (a kind without its reference), which resolves to no
    /// principal rather than to a guess.
    static func resolved(_ row: WorkloadRegistrationSnapshot) -> ResolvedWorkload? {
        switch WorkloadRegistrationKind(rawValue: row.kind) {
        case .agent:
            guard let name = row.agentName else { return nil }
            return .agent(name: name)
        case .serviceAccount:
            guard let id = row.serviceAccountID else { return nil }
            return .serviceAccount(id: id)
        case .workload:
            return .workload(id: row.id)
        case nil:
            return nil
        }
    }

    /// Idempotently register an agent's SPIFFE identity. The registration is
    /// keyed by `identity.key` — the full SPIFFE URI, so two same-named
    /// agents in different trust domains stay distinct rows.
    ///
    /// Called from the mTLS edge after the certificate chain verified and the
    /// trust-domain/path validation passed — the registry row then makes the
    /// mapping first-class for every later connection, which is rejected if
    /// the same URI ever resolves to a different principal.
    static func registerAgent(
        identity: AgentIdentity, using workloads: WorkloadsPersistence
    ) async throws {
        do {
            try await workloads.requireAgentRegistration(
                spiffeID: identity.key, agentName: identity.name)
        } catch WorkloadsPersistenceError.spiffeIDOwnedByDifferentPrincipal {
            throw Abort(.forbidden, reason: "SPIFFE identity is registered to a different principal")
        }
    }

    /// Remove an agent's registration row when the agent is deprovisioned.
    /// Exact-URI deletion, for the same reason registration is URI-keyed.
    static func deregisterAgent(
        identity: AgentIdentity, using workloads: WorkloadsPersistence
    ) async throws {
        _ = try await workloads.deleteAgentRegistration(spiffeID: identity.key)
    }

    /// Enforce the registry mapping for a verified agent identity: a URI
    /// registered to a different principal is rejected even with a valid
    /// agent path, and a first-seen identity is registered so every later
    /// connection resolves through the registry (issue #491).
    static func requireAgentRegistration(
        identity: AgentIdentity, using workloads: WorkloadsPersistence
    ) async throws {
        try await registerAgent(identity: identity, using: workloads)
    }

#if DEBUG
    package static func resolve(
        spiffeID: String, on database: PostgresStoreContext
    ) async throws -> ResolvedWorkload? {
        try await resolve(spiffeID: spiffeID, using: database.testWorkloadsPersistence)
    }

    package static func registerAgent(
        identity: AgentIdentity, on database: PostgresStoreContext
    ) async throws {
        try await registerAgent(identity: identity, using: database.testWorkloadsPersistence)
    }

    package static func deregisterAgent(
        identity: AgentIdentity, on database: PostgresStoreContext
    ) async throws {
        try await deregisterAgent(identity: identity, using: database.testWorkloadsPersistence)
    }

    package static func requireAgentRegistration(
        identity: AgentIdentity, on database: PostgresStoreContext
    ) async throws {
        try await requireAgentRegistration(
            identity: identity, using: database.testWorkloadsPersistence)
    }
#endif
}
