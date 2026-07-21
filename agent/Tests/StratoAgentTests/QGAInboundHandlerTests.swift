import Foundation
import Testing

@testable import StratoAgentCore

/// Cancellation coverage for the qga NIO inbound handler (issue #563, PR review
/// finding #1): a `readSome()` must never leave its awaiting task parked on a
/// continuation nothing resumes, or the `StageBudget.cancelAndWait` that awaits
/// it (shutdown / freeze / thaw) would hang past its budget. The live channel
/// path can't be unit-tested, so these drive the handler's continuation logic
/// directly with no bytes ever delivered.
@Suite("QGA Inbound Handler cancellation")
struct QGAInboundHandlerTests {

    /// Runs `work`, failing (rather than hanging the suite) if it doesn't finish
    /// within `seconds`. Returns whether `work` completed in time.
    private func completes(within seconds: Double, _ work: @escaping @Sendable () async -> Void) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await work()
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    @Test("A parked read unblocks with CancellationError when its task is cancelled")
    func parkedReadCancels() async {
        let handler = QGAInboundHandler()
        let finished = await completes(within: 5) {
            let task = Task { try await handler.readSome() }
            try? await Task.sleep(for: .milliseconds(50))  // let readSome park
            task.cancel()
            await #expect(throws: CancellationError.self) { _ = try await task.value }
        }
        #expect(finished, "a cancelled parked read must resume, not hang")
    }

    @Test("A read entered already-cancelled fails promptly instead of parking unreachably")
    func alreadyCancelledRead() async {
        let handler = QGAInboundHandler()
        let finished = await completes(within: 5) {
            // Spin until the task is cancelled, so readSome is *entered* already
            // cancelled — the window where onCancel runs before the body parks.
            let task = Task { () -> [UInt8] in
                while !Task.isCancelled { await Task.yield() }
                return try await handler.readSome()
            }
            task.cancel()
            await #expect(throws: CancellationError.self) { _ = try await task.value }
        }
        #expect(finished, "a read entered already-cancelled must fail, not hang on an unreachable continuation")
    }
}
