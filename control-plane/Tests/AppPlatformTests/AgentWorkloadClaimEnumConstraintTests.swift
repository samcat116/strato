import Fluent
import Foundation
import SQLKit
import StratoShared
import Testing

import AppTestSupport
@testable import App

/// `agent_workload_claims.resource_kind` is a third `CHECK` on a third install
/// mechanism, and it is the one that gets missed.
///
/// The current-schema baseline installs the guard, and this suite keeps the SQL
/// definition aligned with the Swift enum as new workload kinds are added.
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
                let claim = AgentWorkloadClaimWrite(
                    agentId: "claim-agent",
                    resourceKind: kind.resourceKind,
                    resourceID: UUID(),
                    disposition: .tombstoned,
                    tombstoneGeneration: 7,
                    reason: nil,
                    observedGeneration: 6,
                    observedStatus: "present"
                )
                try await app.workloadsPersistence.insertClaims([claim.native])
            }

            let recorded = try await app.workloadsPersistence.countClaims(agentID: "claim-agent")
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
                    WHERE conname = \(bind: AgentWorkloadClaim.resourceKindConstraintName)
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
