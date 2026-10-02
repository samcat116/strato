import Foundation
import StratoShared
import Testing

@testable import StratoAgentCore

@Suite("Suspension generation, activity and durable admission")
struct SandboxSuspensionTests {
    @Test func admissionContentionDoesNotConsumeFailureBudget() {
        #expect(SandboxSuspensionGuard.GateError.busy.failureClassification == .waitingOnDependency)
        #expect(SandboxSuspensionGuard.GateError.unknownIntent.failureClassification == .waitingOnDependency)
        #expect(SandboxSuspensionGuard.GateError.active.failureClassification == .blocked)
        #expect(SandboxSuspensionGuard.GateError.stale.failureClassification == .blocked)
    }
    @Test func unknownIntentIsRefused() {
        var gate = SandboxSuspensionGuard()
        #expect(throws: SandboxSuspensionGuard.GateError.unknownIntent) {
            try gate.beginSuspension(generation: 1, automatic: true)
        }
    }

    @Test func explicitStopRequiresStoppedIntent() throws {
        var gate = SandboxSuspensionGuard()
        gate.updateIntent(generation: 2, desiredRunning: true)
        #expect(throws: SandboxSuspensionGuard.GateError.stale) {
            try gate.beginSuspension(generation: 2, automatic: false)
        }
        let ticket = try gate.beginSuspension(generation: 2, automatic: true)
        gate.finish(ticket)
    }

    @Test func pendingHandshakePreventsAdmission() {
        var gate = SandboxSuspensionGuard()
        gate.updateIntent(generation: 1, desiredRunning: false)
        let activity = gate.beginActivity()
        #expect(throws: SandboxSuspensionGuard.GateError.active) {
            try gate.beginSuspension(generation: 1, automatic: false)
        }
        gate.endActivity(activity)
    }

    @Test func evenCompletedActivityInvalidatesCapture() throws {
        var gate = SandboxSuspensionGuard()
        gate.updateIntent(generation: 1, desiredRunning: false)
        let ticket = try gate.beginSuspension(generation: 1, automatic: false)
        let activity = gate.beginActivity()
        gate.endActivity(activity)
        #expect(throws: SandboxSuspensionGuard.GateError.stale) { try gate.commitDestruction(ticket) }
        #expect(!gate.needsRestore(after: ticket))
        gate.finish(ticket)
    }

    @Test func staleAndEqualSyncsCannotUndoIntent() throws {
        var gate = SandboxSuspensionGuard()
        gate.updateIntent(generation: 3, desiredRunning: false)
        gate.updateIntent(generation: 2, desiredRunning: true)
        gate.updateIntent(generation: 3, desiredRunning: true)
        let ticket = try gate.beginSuspension(generation: 3, automatic: false)
        try gate.commitDestruction(ticket)
        #expect(!gate.needsRestore(after: ticket))
    }

    @Test func newerGenerationBeforeCommitPreservesOriginal() throws {
        var gate = SandboxSuspensionGuard()
        gate.updateIntent(generation: 1, desiredRunning: false)
        let ticket = try gate.beginSuspension(generation: 1, automatic: false)
        gate.updateIntent(generation: 2, desiredRunning: true)
        #expect(throws: SandboxSuspensionGuard.GateError.stale) { try gate.commitDestruction(ticket) }
    }

    @Test func newerStartAfterCommitRequiresRestore() throws {
        var gate = SandboxSuspensionGuard()
        gate.updateIntent(generation: 1, desiredRunning: false)
        let ticket = try gate.beginSuspension(generation: 1, automatic: false)
        try gate.commitDestruction(ticket)
        gate.updateIntent(generation: 2, desiredRunning: true)
        #expect(gate.needsRestore(after: ticket))
        #expect(throws: SandboxSuspensionGuard.GateError.stale) { try gate.commitDestruction(ticket) }
    }

    @Test func activityAfterCommitRequiresRestore() throws {
        var gate = SandboxSuspensionGuard()
        gate.updateIntent(generation: 1, desiredRunning: true)
        let ticket = try gate.beginSuspension(generation: 1, automatic: true)
        try gate.commitDestruction(ticket)
        let activity = gate.beginActivity()
        gate.endActivity(activity)
        #expect(gate.needsRestore(after: ticket))
    }

    @Test func oneOwnerPerSandbox() throws {
        var gate = SandboxSuspensionGuard()
        gate.updateIntent(generation: 1, desiredRunning: false)
        let ticket = try gate.beginSuspension(generation: 1, automatic: false)
        #expect(throws: SandboxSuspensionGuard.GateError.busy) {
            try gate.beginSuspension(generation: 1, automatic: false)
        }
        gate.finish(ticket)
        let replacement = try gate.beginSuspension(generation: 1, automatic: false)
        gate.finish(ticket)
        #expect(throws: SandboxSuspensionGuard.GateError.busy) {
            try gate.beginSuspension(generation: 1, automatic: false)
        }
        gate.finish(replacement)
    }

    @Test func boundedRestorePermitsDoNotOverrelease() throws {
        var permits = try SandboxRestoreAdmission(limit: 2)
        let first = try permits.acquire()
        let second = try permits.acquire()
        #expect(throws: SandboxSuspensionGuard.GateError.busy) { try permits.acquire() }
        permits.release(UUID())
        #expect(permits.activeCount == 2)
        permits.release(first)
        permits.release(first)
        #expect(permits.activeCount == 1)
        let third = try permits.acquire()
        #expect(permits.activeCount == 2)
        permits.release(second)
        permits.release(third)
        #expect(permits.activeCount == 0)
    }

    @Test(arguments: [0, -1, 33, Int.max])
    func invalidRestoreLimitIsRejected(_ limit: Int) {
        #expect(throws: SandboxSuspensionGuard.GateError.active) { try SandboxRestoreAdmission(limit: limit) }
    }

    @Test func restartReopensCaptureAndRejectsUnverifiedSuspension() throws {
        let directory = NSTemporaryDirectory() + "suspension-store-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let id = UUID()
        var record = SandboxSuspensionRecord(
            sandboxId: id, snapshotId: UUID(), generation: 4, activityEpoch: 12, jailUID: 60_001,
            spec: SandboxSpec(image: "fixture", cpus: 1, memoryBytes: 256 * 1024 * 1024))
        try SandboxSuspensionStore(directory: directory).save(record)
        let reopened = try SandboxSuspensionStore(directory: directory).load(sandboxId: id)
        #expect(reopened?.generation == 4)
        #expect(reopened?.phase == .capturing)
        #expect(reopened?.reservesGuestMemory == true)
        record.phase = .suspended
        try SandboxSuspensionStore(directory: directory).save(record)
        #expect(throws: SandboxSuspensionGuard.GateError.stale) {
            try SandboxSuspensionStore(directory: directory).load(sandboxId: id)
        }
        try SandboxSuspensionStore(directory: directory).remove(sandboxId: id)
        let missing = try SandboxSuspensionStore(directory: directory).load(sandboxId: id)
        #expect(missing == nil)
    }

    @Test(arguments: SandboxSuspensionRecord.Phase.allCases)
    func durablePhaseRecoveryAndReservation(_ phase: SandboxSuspensionRecord.Phase) throws {
        let directory = NSTemporaryDirectory() + "suspension-phase-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        // These bytes exercise filesystem/journal recovery, not a VM restore.
        for kind in SandboxSnapshotArtifactKind.allCases {
            try Data("fixture-\(kind.rawValue)".utf8).write(
                to: URL(fileURLWithPath: directory + "/" + kind.filename))
        }
        let id = UUID()
        let snapshotId = UUID()
        let checkpoint = try SandboxCheckpointManifest.publish(
            directory: directory, sandboxId: id.uuidString, snapshotId: snapshotId.uuidString,
            identityNonce: "fixture", firecrackerVersion: "fixture", guestControlProtocolVersion: 4)
        let spec = SandboxSpec(image: "fixture", cpus: 2, memoryBytes: 256 * 1024 * 1024)
        var record = SandboxSuspensionRecord(
            sandboxId: id, snapshotId: snapshotId, generation: 7, activityEpoch: 42,
            jailUID: 60_001, spec: spec)
        record.phase = phase
        record.checkpoint = phase == .capturing ? nil : checkpoint
        record.storageReservationBytes = 512 * 1024 * 1024
        let store = SandboxSuspensionStore(directory: directory + "/journal")
        try store.save(record)
        let loaded = try SandboxSuspensionStore(directory: directory + "/journal").load(sandboxId: id)
        let reopened = try #require(loaded)
        #expect(reopened.phase == phase)
        #expect(reopened.snapshotId == snapshotId)
        #expect(reopened.generation == 7)
        #expect(reopened.activityEpoch == 42)
        #expect(reopened.reservesGuestMemory == (phase != .suspended))
        #expect(
            reopened.mayReplayCheckpointWithoutGuest
                == [.verified, .destroying, .suspended, .restoring].contains(phase))
        var entry = VMManifestEntry(sandboxSpec: spec, jailUID: 60_001, jailerUsed: true)
        entry.sandboxSuspension = reopened
        let reservation = SandboxHostReservation.forManifestEntry(entry)
        #expect(reservation.memoryBytes == (phase == .suspended ? 0 : spec.memoryBytes))
        #expect(reservation.cpus == (phase == .suspended ? 0 : spec.cpus))
        #expect(reservation.diskBytes == 512 * 1024 * 1024)
        // Without a larger admitted staging plan, File restore still reserves
        // both the immutable archive and the fresh jail copy.
        var actualOnly = reopened
        actualOnly.storageReservationBytes = 0
        entry.sandboxSuspension = actualOnly
        let copies: Int64 = [.restoring, .resuming, .resumed].contains(phase) ? 2 : 1
        #expect(SandboxHostReservation.forManifestEntry(entry).diskBytes == actualOnly.checkpointBytes * copies)
        // Corrupt/legacy host identity cannot authorize releasing RAM.
        var legacy = VMManifestEntry(sandboxSpec: spec)
        legacy.sandboxSuspension = reopened
        #expect(SandboxHostReservation.forManifestEntry(legacy).memoryBytes == spec.memoryBytes)
    }
}
