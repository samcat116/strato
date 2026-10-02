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
            for sandbox in try await Sandbox.query(on: app.db)
                .filter(\.$status == .running).filter(\.$desiredStatus == .running).all()
            {
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
