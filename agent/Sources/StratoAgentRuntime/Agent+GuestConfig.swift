import Foundation
import StratoAgentCore
import StratoShared

extension Agent {
    func reconcileGuestConfig(_ item: ReconcileWorkItem) async throws {
        guard let desired = item.desired, let config = desired.guestConfig else { return }
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
