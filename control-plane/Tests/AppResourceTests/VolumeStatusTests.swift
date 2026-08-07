import Testing
import Foundation
import StratoShared

@testable import App

/// The volume mutation guards, re-expressed against *desired* state in STR-148.
///
/// The point of the rewrite: these questions used to be answered by an observed
/// status, which meant the answer flipped while an agent was mid-convergence —
/// "can I attach this?" would say no simply because a resize was in flight. A
/// level-triggered loop needs guards that describe the request, not the weather.
@Suite("Volume Status Tests")
struct VolumeStatusTests {

    private func volume(
        attachedTo vmID: UUID? = nil,
        desired: DesiredVolumeStatus = .present,
        status: VolumeStatus = .available,
        generation: Int64 = 1,
        observedGeneration: Int64 = 1
    ) -> Volume {
        let volume = Volume()
        volume.$vm.id = vmID
        volume.desiredStatus = desired
        volume.status = status
        volume.generation = generation
        volume.observedGeneration = observedGeneration
        return volume
    }

    @Test("canDelete admits everything except an attached volume")
    func canDeleteIsAboutAttachment() {
        #expect(volume().canDelete)
        // A never-converged create is deletable: teardown is idempotent and
        // level-triggered, so there is no half-finished operation to interrupt.
        #expect(volume(status: .creating, observedGeneration: 0).canDelete)
        #expect(volume(status: .error).canDelete)
        #expect(volume(desired: .absent).canDelete)
        #expect(volume(attachedTo: UUID(), status: .attached).canDelete == false)
    }

    @Test("canAttach admits only a detached, live volume")
    func canAttachIsAboutAttachment() {
        #expect(volume().canAttach)
        // Still converging is fine: the attach lands on the same desired entry
        // and the agent sequences the two steps itself.
        #expect(volume(status: .creating, observedGeneration: 0).canAttach)
        #expect(volume(attachedTo: UUID(), status: .attached).canAttach == false)
        #expect(volume(desired: .absent).canAttach == false)
    }

    @Test("canDetach admits only an attached volume")
    func canDetachIsAboutAttachment() {
        #expect(volume(attachedTo: UUID(), status: .attached).canDetach)
        #expect(volume().canDetach == false)
    }

    @Test("canResize admits only a detached volume")
    func canResizeIsOfflineOnly() {
        #expect(volume().canResize)
        #expect(volume(attachedTo: UUID(), status: .attached).canResize == false)
        #expect(volume(desired: .absent).canResize == false)
    }

    /// Cloning and snapshotting are the two verbs that read the source's bytes,
    /// so they keep an `isConverged` requirement the others dropped: copying a
    /// volume whose create is still writing it yields a torn image, and unlike a
    /// resize that cannot be re-driven into correctness.
    @Test("canClone and canSnapshot additionally require convergence")
    func readingVerbsRequireConvergence() {
        #expect(volume().canClone)
        #expect(volume().canSnapshot)

        let converging = volume(status: .creating, generation: 2, observedGeneration: 1)
        #expect(converging.canClone == false)
        #expect(converging.canSnapshot == false)

        #expect(volume(attachedTo: UUID(), status: .attached).canClone == false)
        #expect(volume(attachedTo: UUID(), status: .attached).canSnapshot == false)
    }

    @Test("isConverged needs the generation caught up and a resting status")
    func convergenceNeedsBoth() {
        #expect(volume(status: .available, generation: 3, observedGeneration: 3).isConverged)
        #expect(
            volume(attachedTo: UUID(), status: .attached, generation: 3, observedGeneration: 3)
                .isConverged)
        // Generation caught up but the bytes are gone: not converged, which is
        // what keeps an out-of-band deletion from reading as healthy.
        #expect(volume(status: .error, generation: 3, observedGeneration: 3).isConverged == false)
        #expect(volume(status: .available, generation: 4, observedGeneration: 3).isConverged == false)
        // A terminating volume is on its way out, never converging on anything.
        #expect(volume(desired: .absent, generation: 3, observedGeneration: 3).isConverged == false)
    }

    @Test("setDesiredStatus and bumpGeneration both advance the generation")
    func mutatorsBumpTheGeneration() {
        let volume = volume(generation: 4)
        volume.setDesiredStatus(.absent)
        #expect(volume.generation == 5)
        #expect(volume.desiredStatus == .absent)
        volume.bumpGeneration()
        #expect(volume.generation == 6)
    }

    /// The failure resolution asymmetry, which is deliberate and easy to
    /// mistake for an oversight: a doomed attach is reverted so it does not
    /// replay on every sync, but a doomed resize keeps its desired size,
    /// because the control plane does not know what the agent actually realized
    /// and a larger desired size is harmless to re-attempt.
    @Test("A stuck attach reverts; a stuck resize does not")
    func stuckResolutionRevertsAttachmentOnly() {
        let attaching = volume(attachedTo: UUID(), status: .available, generation: 4)
        attaching.deviceName = "disk1"
        attaching.readonly = true
        #expect(attaching.resolveForStuckOperation(mutation: .attach, telemetryReason: "t"))
        #expect(attaching.$vm.id == nil)
        #expect(attaching.deviceName == nil)
        #expect(attaching.readonly == false)
        #expect(attaching.generation == 5)

        let resizing = volume(generation: 4)
        resizing.size = 20 << 30
        #expect(resizing.resolveForStuckOperation(mutation: .resize, telemetryReason: "t") == false)
        #expect(resizing.size == 20 << 30)
        #expect(resizing.generation == 4)
    }

    /// A stuck *delete* keeps its `.absent`, for the same reason a VM's does:
    /// reverting it would resurrect a volume the user deleted, and once the
    /// agent has removed the data the reconciler would create a fresh blank one
    /// in its place.
    @Test("A stuck delete is never reverted")
    func stuckDeleteKeepsItsIntent() {
        let deleting = volume(desired: .absent, generation: 4)
        #expect(deleting.resolveForStuckOperation(mutation: .delete, telemetryReason: "t") == false)
        #expect(deleting.desiredStatus == .absent)
    }
}
