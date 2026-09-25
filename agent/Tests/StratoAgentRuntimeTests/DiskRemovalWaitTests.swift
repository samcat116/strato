import Testing
import StratoAgentCore
@testable import StratoAgentRuntime

@Suite("Asynchronous disk removal", .timeLimit(.minutes(1)))
struct DiskRemovalWaitTests {
    private actor Disk {
        var reads = 0
        func stillPresent() -> Bool {
            reads += 1
            return reads < 3
        }
    }

    @Test func delayedLiveRemovalAllowsPersistentDetach() async throws {
        let live = Disk()
        let persistent = Disk()
        // The live disk remains in two observations after the RPC succeeds.
        // Only confirmed absence permits the persistent scope to proceed.
        for disk in [live, persistent] {
            try await LibvirtService.waitForDiskRemoval(
                volumeId: "volume", vmId: "vm", timeout: .seconds(5), pollInterval: .milliseconds(1)
            ) { await disk.stillPresent() }
        }
        #expect(await live.reads == 3)
        #expect(await persistent.reads == 3)
    }

    @Test func diskThatRemainsAttachedTimesOut() async {
        await #expect(throws: HypervisorServiceError.self) {
            try await LibvirtService.waitForDiskRemoval(
                volumeId: "volume", vmId: "vm", timeout: .milliseconds(10), pollInterval: .milliseconds(1)
            ) { true }
        }
    }

    @Test func observationFailureIsNotAbsence() async {
        struct ObservationFailed: Error {}
        await #expect(throws: ObservationFailed.self) {
            try await LibvirtService.waitForDiskRemoval(volumeId: "volume", vmId: "vm") {
                throw ObservationFailed()
            }
        }
    }

    @Test func cancellationStopsPolling() async {
        let started = AsyncStream<Void>.makeStream()
        let task = Task {
            try await LibvirtService.waitForDiskRemoval(volumeId: "volume", vmId: "vm") {
                started.continuation.finish()
                return true
            }
        }
        for await _ in started.stream {}
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
