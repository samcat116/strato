import Foundation
import Testing

@testable import StratoAgentCore

/// The decision table behind STR-179: deleting an orphan the agent could not
/// re-adopt may take the VM's whole directory — boot disk included — with it,
/// but only when the failure says the hypervisor process is gone. Everything
/// else has to leave a possibly-live guest's disk alone, so the *default* is
/// the property worth pinning: a case added to `HypervisorServiceError` later
/// must not silently become grounds for an unlink.
@Suite("Orphan Delete Adoption")
struct OrphanDeleteAdoptionTests {

    @Test("A gone adoption target is the one failure that permits reclaiming the directory")
    func adoptionTargetGoneIsProcessGone() {
        let error = HypervisorServiceError.adoptionTargetGone("no domain named abc")
        #expect(OrphanDeleteAdoption.classify(adoptionFailure: error) == .processGone)
    }

    /// A re-adoption that timed out is the case the classification exists for:
    /// the VM may be alive and merely unreachable, so a driver raises
    /// `.timeout` rather than `.adoptionTargetGone` for exactly that reason.
    @Test(
        "Every other hypervisor failure leaves the VM's files alone",
        arguments: [
            HypervisorServiceError.timeout("re-adopting VM abc exceeded 30s"),
            .notSupported("Firecracker does not support re-adopting orphaned VMs"),
            .hypervisorNotInstalled("/usr/bin/firecracker"),
            .vmNotFound("abc"),
            .invalidConfiguration("no desired entry"),
            .diskError("qemu-img failed"),
        ])
    func otherHypervisorFailuresAreIndeterminate(error: HypervisorServiceError) {
        #expect(OrphanDeleteAdoption.classify(adoptionFailure: error) == .indeterminate)
    }

    /// Drivers throw their own error types too (libvirt's, `FirecrackerError`,
    /// NIO's), and a bare `catch` sees them all.
    @Test("An error from outside the hypervisor vocabulary is indeterminate")
    func foreignErrorsAreIndeterminate() {
        struct Boom: Error {}
        #expect(OrphanDeleteAdoption.classify(adoptionFailure: Boom()) == .indeterminate)
        #expect(OrphanDeleteAdoption.classify(adoptionFailure: CancellationError()) == .indeterminate)
        #expect(
            OrphanDeleteAdoption.classify(adoptionFailure: StageBudgetError.exceeded(stage: "adopt", seconds: 30))
                == .indeterminate)
    }
}
