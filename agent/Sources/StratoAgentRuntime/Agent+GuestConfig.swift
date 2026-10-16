import Foundation
import StratoAgentCore
import StratoShared

extension Agent {
    /// Runs on the generation-guarded convergence path, including no-step items.
    /// Keeping withdrawal on that path prevents an older in-flight pass from
    /// repopulating the cache after the newer intent has retired it.
    func retireGuestConfigObservation(_ item: ReconcileWorkItem) async {
        guard item.kind == .vm, item.desired?.guestConfig?.isEmpty != false else { return }
        guestConfigObservationCache.removeValue(forKey: item.id)
    }

    /// Reconciler facts and the cache live on different actors. A heartbeat can
    /// read either side of a drift/recovery transition, so publish only a
    /// guest observation whose status agrees with the captured verdict.
    func guestConfigObservation(
        for vmId: String, status: VMStatus, observedGeneration: Int64, failedGeneration: Int64?
    ) -> GuestConfigObservation? {
        guard status == .running, let observation = guestConfigObservationCache[vmId] else { return nil }
        switch observation.status {
        case .failed:
            return observation.generation == failedGeneration ? observation : nil
        case .converged:
            return observation.generation == observedGeneration && observation.generation != failedGeneration
                ? observation : nil
        }
    }

    func reconcileGuestConfig(_ item: ReconcileWorkItem) async throws {
        guard let desired = item.desired, let config = desired.guestConfig, !config.isEmpty else {
            await retireGuestConfigObservation(item)
            return
        }
        guard desired.spec.guestAgentEnabled else {
            throw ConvergenceError.unsupported("Guest configuration requires the VM guest-agent opt-in")
        }
        let placement = try VMGuestExecPlacement.resolve(vmId: item.id, managedVMs: managedVMs)
        let observation = try await GuestConfigClient(logger: logger).converge(
            placement: placement, config: config, generation: item.generation,
            placementIsCurrent: { [weak self] in
                guard let self else { return false }
                return await self.guestConfigPlacementIsCurrent(placement)
            })
        guestConfigObservationCache[item.id] = observation
        if observation.status == .failed {
            throw GuestConfigurationFailure.failed(reason: GuestConfigurationFailure.safeReason(observation.error))
        }
    }

    private func guestConfigPlacementIsCurrent(_ placement: VMGuestExecPlacement) -> Bool {
        !shutdownRequested
            && (try? VMGuestExecPlacement.resolve(vmId: placement.vmId, managedVMs: managedVMs)) == placement
    }
}
