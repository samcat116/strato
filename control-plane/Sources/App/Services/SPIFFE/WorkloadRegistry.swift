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

    /// Idempotently register an agent's SPIFFE identity.
    ///
    /// Called from the mTLS edge after the certificate chain verified and the
    /// path-derived agent name was validated — the registry row then makes
    /// the mapping first-class for every later connection, which is rejected
    /// if the same URI ever resolves to a different principal.
    static func registerAgent(spiffeID: String, agentName: String, on db: any Database) async throws {
        do {
            try await WorkloadRegistration(spiffeID: spiffeID, kind: .agent, agentName: agentName)
                .save(on: db)
        } catch {
            guard let dbError = error as? any DatabaseError, dbError.isConstraintFailure else { throw error }
            // A concurrent connection won the insert race; the unique key
            // guarantees the winner registered the same URI. Verify it names
            // the same agent rather than adopting it blind.
            guard
                let existing = try await resolve(spiffeID: spiffeID, on: db),
                existing == .agent(name: agentName)
            else { throw error }
        }
    }

    /// Remove an agent's registration rows when the agent is deprovisioned.
    static func deregisterAgent(named agentName: String, on db: any Database) async throws {
        try await WorkloadRegistration.query(on: db)
            .filter(\.$kind == .agent)
            .filter(\.$agentName == agentName)
            .delete()
    }
}
