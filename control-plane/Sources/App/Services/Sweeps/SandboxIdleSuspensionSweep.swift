import Fluent
import StratoShared
import Vapor

extension AgentMaintenanceLoop {
    /// Disabled independently of the agent opt-in. Reports nominate only;
    /// guest prepare and the durable CP fence authorize lifecycle actions.
    func sweepIdleSandboxes(at instant: ClusterInstant) async {
        guard !isShutDown, !app.didShutdown, instant.permitsDestructiveSweeps,
            app.controlPlaneConfiguration.bool(.sandboxIdleSuspendEnabled),
            await app.coordination.acquireSweepLock("sandbox_idle_suspension")
        else { return }
        do {
            // One bounded keyset page per tick. Continue on the next tick,
            // rather than opening transactions for the entire running fleet.
            let page = try await SandboxIdleFenceService.nominationCandidates(
                after: idleSuspensionCursor, at: instant, on: app.db)
            idleSuspensionCursor = page.nextCursor
            for sandbox in page.sandboxes {
                guard !isShutDown, !app.didShutdown else { return }
                do { try await SandboxIdleFenceService.nominate(sandbox, app: app, at: instant) } catch let error
                    as AbortError where error.status == .conflict
                {
                    // Level-triggered nomination lost freshness/admission; the
                    // next sweep recomputes rather than retrying a stale claim.
                } catch { app.logger.warning("Idle sandbox nomination failed: \(error)") }
            }
        } catch { app.logger.warning("Idle sandbox sweep failed: \(error)") }
    }
}
