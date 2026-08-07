import Fluent
import SQLKit
import StratoShared
import Testing

import AppTestSupport
@testable import App

/// `agent_workload_claims.resource_kind` is a third `CHECK` on a third install
/// mechanism, and it is the one that gets missed.
///
/// `EnforcePersistedEnumValues` does not own it (the table postdates that
/// migration and installs its own guard inline in `CreateAgentWorkloadClaim`),
/// and neither does `CreateResourceEvent` — so `PersistedEnumConstraintTests`
/// and `ResourceEventEnumConstraintTests`, which between them pin every other
/// `resource_kind` column, both look straight past it. STR-148 added
/// `WorkloadKind.volume` without widening it and nothing caught that; STR-150
/// added three more kinds and this suite is what makes the gap visible.
///
/// The cost of the gap is not one rejected row. `applyUnrecognizedWorkloads`
/// runs inside observed-report handling, so a constraint violation throws and
/// *nothing* in that agent's report is applied — and the stray artifact is
/// still there on the next report, so the agent stops converging permanently.
@Suite("Agent workload claim enum constraint", .serialized)
struct AgentWorkloadClaimEnumConstraintTests {

    @Test("A claim can be recorded for every workload kind an agent can report")
    func everyWorkloadKindIsInsertable() async throws {
        try await withTestApp { app in
            // Every kind the agent can put in `ObservedStateReport.unrecognized`
            // maps to a `resource_kind` this table has to accept. Driven off
            // `WorkloadKind.allCases` rather than a literal list, so a kind
            // added later fails here instead of in production.
            for kind in WorkloadKind.allCases {
                let claim = AgentWorkloadClaim(
                    agentId: "claim-agent",
                    resourceKind: kind.resourceKind,
                    resourceID: UUID(),
                    disposition: .tombstoned,
                    tombstoneGeneration: 7,
                    reason: nil,
                    observedGeneration: 6,
                    observedStatus: "present"
                )
                try await claim.save(on: app.db)
            }

            let recorded = try await AgentWorkloadClaim.query(on: app.db)
                .filter(\.$agentId == "claim-agent")
                .count()
            #expect(recorded == WorkloadKind.allCases.count)
        }
    }

    @Test("The constraint still rejects a value no workload kind maps to")
    func unknownKindIsRejected() async throws {
        try await withTestApp { app in
            let sql = try #require(app.db as? any SQLDatabase)
            // The guard is not merely widened to everything: FluentKit
            // force-unwraps `RawRepresentable.init(rawValue:)` on enum columns,
            // so an unexpected value traps the process rather than failing a
            // request. That is what the `CHECK` is for.
            await #expect(throws: (any Error).self) {
                try await sql.raw(
                    """
                    INSERT INTO agent_workload_claims
                        (id, agent_id, resource_kind, resource_id, disposition, observed_generation)
                    VALUES (\(bind: UUID()), 'claim-agent', 'rbd_snapshot', \(bind: UUID()), 'held', 0)
                    """
                ).run()
            }
        }
    }

    @Test("The installed constraint covers every OperationResourceKind")
    func constraintCoversEveryResourceKind() async throws {
        try await withTestApp { app in
            let sql = try #require(app.db as? any SQLDatabase)
            let row = try #require(
                try await sql.raw(
                    """
                    SELECT pg_get_constraintdef(oid) AS definition FROM pg_constraint
                    WHERE conname = \(bind: AddSnapshotOperationKinds.claimConstraint.name)
                    """
                ).first()
            )
            let definition = try row.decode(column: "definition", as: String.self)
            for kind in OperationResourceKind.allCases {
                #expect(
                    definition.contains("'\(kind.rawValue)'"),
                    "constraint omits \(kind.rawValue): \(definition)")
            }
        }
    }
}
