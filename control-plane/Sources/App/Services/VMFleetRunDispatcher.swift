import Fluent
import Foundation
import SQLKit
import StratoShared
import Vapor

struct VMFleetRunDispatcher {
    /// Each replica competes for the same parent row lock. Claimed children
    /// remain active until terminal (including uncertain delivery); they are
    /// never put back in the queue. Existing command timeouts recover slots.
    static func advance(
        id: UUID, app: Application,
        deliver: (@Sendable (GuestExecStartMessage, String) async throws -> Void)? = nil
    ) async throws {
        let claimed: [(UUID, UUID, String, [String], Bool)] = try await app.db.transaction { db in
            guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
            try await sql.raw("SELECT id FROM vm_fleet_runs WHERE id = \(bind: id) FOR UPDATE").run()
            guard let fleet = try await VMFleetRun.find(id, on: db), fleet.confirmed else { return [] }
            let now = try await ClusterClock.read(on: db)
            let operationIDs = fleet.entries.compactMap(\.operationID)
            let executions =
                operationIDs.isEmpty
                ? []
                : try await VMCommandExecution.query(on: db)
                    .filter(\.$id ~~ operationIDs).all()
            let byID = Dictionary(
                uniqueKeysWithValues: executions.compactMap { execution in
                    execution.id.map { ($0, execution) }
                })
            let active = fleet.entries.filter { entry in
                entry.state == "dispatched" && entry.operationID.flatMap { byID[$0] }?.status == .pending
            }.count
            var slots = max(0, VMFleetRunController.concurrency - active)
            var claims: [(UUID, UUID, String, [String], Bool)] = []
            for index in fleet.entries.indices where fleet.entries[index].state == "queued" {
                guard let executionID = fleet.entries[index].operationID, let execution = byID[executionID] else {
                    fleet.entries[index].state = "skipped"
                    fleet.entries[index].reason = "Command record is unavailable"
                    continue
                }
                if execution.status != .pending {
                    fleet.entries[index].state = "dispatched"
                    continue
                }
                if fleet.deadline <= now.date {
                    fleet.entries[index].state = "skipped"
                    fleet.entries[index].reason = "Fleet queue expired before dispatch"
                    claims.append((executionID, execution.vmID, execution.agentKey, fleet.command, true))
                    continue
                }
                guard slots > 0 else { continue }
                slots -= 1
                fleet.entries[index].state = "dispatched"
                execution.deadline = now.date.addingTimeInterval(VMCommandExecutionService.completionBudget)
                try await execution.save(on: db)
                claims.append((executionID, execution.vmID, execution.agentKey, fleet.command, false))
            }
            try await fleet.save(on: db)
            return claims
        }
        // No retry after committing the claim: interrupted delivery is an
        // unknown outcome, resolved by the child's stream or durable deadline.
        for (executionID, _, _, _, expired) in claimed where expired {
            await app.vmCommandExecutionService.markDispatchFailed(
                id: executionID, reason: "Fleet queue expired before dispatch")
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (executionID, vmID, agentKey, command, expired) in claimed where !expired {
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let message = GuestExecStartMessage(
                            resourceKind: .virtualMachine, resourceId: vmID.uuidString,
                            sessionKind: .recorded, sessionId: executionID.uuidString,
                            command: command, tty: false)
                        if let deliver {
                            try await deliver(message, agentKey)
                        } else {
                            try await app.replicaBridge.deliver(message, agentKey: agentKey)
                        }
                    } catch let error as ReplicaMessageBridge.DeliveryError where !error.isDefinitive {
                        app.logger.warning(
                            "Fleet command delivery outcome unknown",
                            metadata: [
                                "executionId": .string(executionID.uuidString)
                            ])
                    } catch is CancellationError {
                        // The claim is durable; never replay after interruption.
                    } catch {
                        await app.vmCommandExecutionService.markDispatchFailed(
                            id: executionID,
                            reason: "Could not dispatch fleet command: \(error.localizedDescription)")
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    static func sweep(app: Application) async {
        do {
            let fleets = try await VMFleetRun.query(on: app.db).filter(\.$confirmed == true)
                .filter(.sql(unsafeRaw: "(entries -> 'values') @> '[{\"state\":\"queued\"}]'::jsonb"))
                .sort(\.$createdAt).limit(100).all()
            for fleet in fleets {
                guard !app.didShutdown else { return }
                try await advance(id: fleet.requireID(), app: app)
            }
        } catch {
            app.logger.error("Fleet queue sweep failed: \(error)")
        }
    }
}
