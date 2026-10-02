import Foundation
import StratoAgentCore
import StratoShared

extension Agent {
    /// Runs after the heartbeat was sent; inventory reads only the cache.
    func refreshGuestAgentCacheIfDue() async {
        let now = ContinuousClock.now
        if let last = lastGuestAgentRefresh, now - last < Self.guestInfoRefreshInterval { return }
        lastGuestAgentRefresh = now
        let targets = managedVMs.compactMap { vmId, entry -> (String, UInt32)? in
            guard entry.hypervisorType == .qemu, entry.spec.guestAgentEnabled,
                let cid = entry.vsockCID
            else { return nil }
            return (vmId, cid)
        }
        let logger = logger
        do {
            let observations = try await StageBudget.run(
                seconds: 5, stage: "strato-guest-agent-probe", onTimeout: .abandon
            ) {
                await withTaskGroup(of: (String, GuestAgentObservation?).self) { group in
                    for (vmId, cid) in targets {
                        group.addTask { (vmId, try? await GuestAgentProbe.check(cid: cid, logger: logger)) }
                    }
                    var result: [String: GuestAgentObservation] = [:]
                    for await (vmId, observation) in group { result[vmId] = observation }
                    return result
                }
            }
            // The probe suspends; never reuse a result after CID ownership changes.
            guestAgentObservationCache = observations.filter { vmId, _ in
                targets.contains { $0.0 == vmId && $0.1 == managedVMs[vmId]?.vsockCID }
            }
        } catch {
            logger.debug("Strato guest-agent probe exceeded its budget; previous observations will expire")
        }
    }
}
