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
        observedGeneration: Int64 = 1,
        failedGeneration: Int64? = nil
    ) -> Volume {
        let volume = Volume()
        volume.$vm.id = vmID
        volume.desiredStatus = desired
        volume.status = status
        volume.generation = generation
        volume.observedGeneration = observedGeneration
        if let failedGeneration {
            volume.errorMessage = "resize failed: no space left on device"
            volume.failedGeneration = failedGeneration
        }
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

    /// Attachment stopped being a reason to refuse a resize in STR-19: whether
    /// a grow happens online or offline is the agent's call, so the only thing
    /// left without a size to converge on is a volume on its way out.
    @Test("canResize admits an attached volume but not a terminating one")
    func canResizeIsAboutDesiredPresence() {
        #expect(volume().canResize)
        #expect(volume(attachedTo: UUID(), status: .attached).canResize)
        // Still converging is fine, for the same reason `canAttach` allows it.
        #expect(volume(status: .creating, observedGeneration: 0).canResize)
        #expect(volume(desired: .absent).canResize == false)
    }

    /// Cloning and snapshotting are the two verbs that read the source's bytes,
    /// so they keep a `bytesAtRest` requirement the others dropped: copying a
    /// volume whose create is still writing it yields a torn image, and unlike a
    /// resize that cannot be re-driven into correctness.
    @Test("canClone and canSnapshot additionally require the bytes to be at rest")
    func readingVerbsRequireBytesAtRest() {
        #expect(volume().canClone)
        #expect(volume().canSnapshot)

        let converging = volume(status: .creating, generation: 2, observedGeneration: 1)
        #expect(converging.canClone == false)
        #expect(converging.canSnapshot == false)

        #expect(volume(attachedTo: UUID(), status: .attached).canClone == false)
        #expect(volume(attachedTo: UUID(), status: .attached).canSnapshot == false)
    }

    @Test("bytesAtRest needs the generation caught up and a resting status")
    func bytesAtRestNeedsBoth() {
        #expect(volume(status: .available, generation: 3, observedGeneration: 3).bytesAtRest)
        #expect(
            volume(attachedTo: UUID(), status: .attached, generation: 3, observedGeneration: 3)
                .bytesAtRest)
        // Generation caught up but the bytes are gone: not at rest, which is
        // what keeps an out-of-band deletion from reading as healthy.
        #expect(volume(status: .error, generation: 3, observedGeneration: 3).bytesAtRest == false)
        #expect(volume(status: .available, generation: 4, observedGeneration: 3).bytesAtRest == false)
        // A terminating volume is on its way out, never converging on anything.
        #expect(volume(desired: .absent, generation: 3, observedGeneration: 3).bytesAtRest == false)
    }

    /// The one place `isConverged` and `bytesAtRest` deliberately part company
    /// (STR-191). They sit next to each other so the difference is stated where
    /// both are read.
    @Test("A failure at the current generation un-converges a volume")
    func currentGenerationFailureUnconverges() {
        let failed = volume(generation: 3, observedGeneration: 3, failedGeneration: 3)
        #expect(failed.isConverged == false)
        #expect(failed.conditions.converged == false)
        #expect(failed.conditions.degraded?.sinceGeneration == 3)

        // A failure a newer mutation already moved past is not this generation's
        // verdict, so it does not un-converge anything.
        let superseded = volume(generation: 4, observedGeneration: 4, failedGeneration: 3)
        #expect(superseded.isConverged)
        #expect(superseded.conditions.converged)
    }

    @Test("A failed resize does not make a volume un-snapshottable")
    func failedResizeKeepsTheReadingVerbs() {
        // `bytesAtRest`, not `isConverged`: a resize that failed leaves
        // `failedGeneration == generation` with nothing to clear it — the
        // resolution bumps the generation only for a failed attach — so gating
        // these on convergence would lock the volume out permanently. And a copy
        // of the pre-resize volume is a perfectly good point-in-time copy.
        let failed = volume(generation: 3, observedGeneration: 3, failedGeneration: 3)
        #expect(failed.bytesAtRest)
        #expect(failed.canSnapshot)
        #expect(failed.canClone)
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
