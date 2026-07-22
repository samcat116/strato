import Fluent
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

    /// Validate a SPIFFE URI supplied to a registration API, returning it
    /// normalized.
    ///
    /// Beyond the syntax check, the reserved `/agent/<name>` namespace is
    /// refused outright: agent identities are claimable only by
    /// trust-on-first-use at the mTLS edge, after SPIRE has verified the
    /// certificate. Allowing an API caller to pre-register one would let a
    /// low-privilege principal squat on an enrolled-but-not-yet-connected
    /// node's identity — `requireAgentRegistration` would then refuse the
    /// genuine agent (a cross-tenant onboarding denial of service), and
    /// nothing short of manual registry surgery would clear the row.
    static func validateRegistrable(spiffeID: String) throws -> String {
        guard let identity = SPIFFEIdentity(uri: spiffeID) else {
            throw Abort(.badRequest, reason: "Not a valid SPIFFE URI (spiffe://<trust-domain>/<path>)")
        }
        guard !identity.isAgent else {
            throw Abort(
                .badRequest,
                reason:
                    "The /agent/ SPIFFE namespace is reserved for hypervisor agents, which register automatically when they first connect"
            )
        }
        return identity.uri
    }

    /// Resolve a SPIFFE URI to the principal it registers, or nil for an
    /// unregistered identity.
    static func resolve(spiffeID: String, on db: any Database) async throws -> ResolvedWorkload? {
        guard
            let row = try await WorkloadRegistration.query(on: db)
                .filter(\.$spiffeID == spiffeID)
                .first()
        else { return nil }
        return resolved(row)
    }

    /// The resolution of one registry row; nil when the row is internally
    /// inconsistent (a kind without its reference), which resolves to no
    /// principal rather than to a guess.
    static func resolved(_ row: WorkloadRegistration) -> ResolvedWorkload? {
        switch row.kind {
        case .agent:
            guard let name = row.agentName else { return nil }
            return .agent(name: name)
        case .serviceAccount:
            guard let id = row.$serviceAccount.id else { return nil }
            return .serviceAccount(id: id)
        case .workload:
            guard let id = row.id else { return nil }
            return .workload(id: id)
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
    static func registerAgent(identity: AgentIdentity, on db: any Database) async throws {
        do {
            try await WorkloadRegistration(spiffeID: identity.key, kind: .agent, agentName: identity.name)
                .save(on: db)
        } catch {
            guard let dbError = error as? any DatabaseError, dbError.isConstraintFailure else { throw error }
            // A concurrent connection won the insert race; the unique key
            // guarantees the winner registered the same URI. Verify it names
            // the same agent rather than adopting it blind.
            guard
                let existing = try await resolve(spiffeID: identity.key, on: db),
                existing == .agent(name: identity.name)
            else { throw error }
        }
    }

    /// Remove an agent's registration row when the agent is deprovisioned.
    /// Exact-URI deletion, for the same reason registration is URI-keyed.
    static func deregisterAgent(identity: AgentIdentity, on db: any Database) async throws {
        try await WorkloadRegistration.query(on: db)
            .filter(\.$kind == .agent)
            .filter(\.$spiffeID == identity.key)
            .delete()
    }

    /// Enforce the registry mapping for a verified agent identity: a URI
    /// registered to a different principal is rejected even with a valid
    /// agent path, and a first-seen identity is registered so every later
    /// connection resolves through the registry (issue #491).
    static func requireAgentRegistration(identity: AgentIdentity, on db: any Database) async throws {
        if let registered = try await resolve(spiffeID: identity.key, on: db) {
            guard case .agent(let registeredName) = registered, registeredName == identity.name else {
                throw Abort(.forbidden, reason: "SPIFFE identity is registered to a different principal")
            }
            return
        }
        try await registerAgent(identity: identity, on: db)
    }
}
