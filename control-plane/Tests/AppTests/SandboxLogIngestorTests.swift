import Foundation
import NIOConcurrencyHelpers
import StratoShared
import Testing
import Vapor

@testable import App

/// Unit tests for `SandboxLogIngestor`: the serial consumer must preserve
/// enqueue order (Loki rejects out-of-order entries per stream) and must
/// cache both positive and negative agent-ownership answers within the TTL
/// instead of issuing one database query per log line.
///
/// The ingestor's dependencies are injected closures, so these tests need no
/// application, database, or Loki.
@Suite("Sandbox Log Ingestor Tests")
struct SandboxLogIngestorTests {

    private func makeMessage(sandboxId: String, line: String) -> SandboxLogMessage {
        SandboxLogMessage(sandboxId: sandboxId, stream: "stdout", message: line)
    }

    /// Poll until `condition` holds; returns whether it did before timeout.
    private func poll(
        timeout: Duration = .seconds(10),
        until condition: @escaping @Sendable () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test("Lines are pushed in enqueue order")
    func preservesEnqueueOrder() async throws {
        let pushed = NIOLockedValueBox<[String]>([])
        let ingestor = SandboxLogIngestor(
            logger: Logger(label: "test"),
            checkOwnership: { _, _ in true },
            push: { message in
                pushed.withLockedValue { $0.append(message.message) }
            }
        )

        let lines = (0..<200).map { "line-\($0)" }
        for line in lines {
            ingestor.enqueue(makeMessage(sandboxId: "sandbox-1", line: line), fromAgentKey: agentKey("agent-a"))
        }

        let drained = await poll { pushed.withLockedValue { $0.count } == lines.count }
        #expect(drained == true)
        let result = pushed.withLockedValue { $0 }
        #expect(result == lines)
        ingestor.shutdown()
    }

    @Test("Ownership answers are cached within the TTL, both positive and negative")
    func cachesOwnershipAnswers() async throws {
        let checks = NIOLockedValueBox<[String]>([])
        let pushedCount = NIOLockedValueBox<Int>(0)
        let ingestor = SandboxLogIngestor(
            logger: Logger(label: "test"),
            checkOwnership: { sandboxId, _ in
                checks.withLockedValue { $0.append(sandboxId) }
                return sandboxId == "owned"
            },
            push: { _ in
                pushedCount.withLockedValue { $0 += 1 }
            }
        )

        // Interleave lines for an owned sandbox and a spoofed one; end on an
        // owned line so the push count tells us the spoofed entries before it
        // were processed too.
        for _ in 0..<5 {
            ingestor.enqueue(makeMessage(sandboxId: "spoofed", line: "x"), fromAgentKey: agentKey("agent-a"))
            ingestor.enqueue(makeMessage(sandboxId: "owned", line: "x"), fromAgentKey: agentKey("agent-a"))
        }

        let drained = await poll { pushedCount.withLockedValue { $0 } == 5 }
        #expect(drained == true)

        // One database consultation per sandbox/agent pair; the rest served
        // from cache. Negative answers never reach the push closure.
        let consulted = checks.withLockedValue { $0 }
        #expect(consulted == ["spoofed", "owned"])
        let pushes = pushedCount.withLockedValue { $0 }
        #expect(pushes == 5)
        ingestor.shutdown()
    }

    @Test("Ownership is re-checked once the TTL elapses")
    func recheckAfterTTL() async throws {
        let currentNow = NIOLockedValueBox<Date>(Date())
        let checkCount = NIOLockedValueBox<Int>(0)
        let pushedCount = NIOLockedValueBox<Int>(0)
        let ingestor = SandboxLogIngestor(
            logger: Logger(label: "test"),
            now: { currentNow.withLockedValue { $0 } },
            checkOwnership: { _, _ in
                checkCount.withLockedValue { $0 += 1 }
                return true
            },
            push: { _ in
                pushedCount.withLockedValue { $0 += 1 }
            }
        )

        ingestor.enqueue(makeMessage(sandboxId: "sandbox-1", line: "a"), fromAgentKey: agentKey("agent-a"))
        ingestor.enqueue(makeMessage(sandboxId: "sandbox-1", line: "b"), fromAgentKey: agentKey("agent-a"))
        let firstDrain = await poll { pushedCount.withLockedValue { $0 } == 2 }
        #expect(firstDrain == true)
        let checksWithinTTL = checkCount.withLockedValue { $0 }
        #expect(checksWithinTTL == 1)

        // Advance the injected clock past the TTL: the next line must consult
        // the ownership check again.
        currentNow.withLockedValue { $0 = $0.addingTimeInterval(SandboxLogIngestor.ownershipTTL + 1) }
        ingestor.enqueue(makeMessage(sandboxId: "sandbox-1", line: "c"), fromAgentKey: agentKey("agent-a"))
        let secondDrain = await poll { pushedCount.withLockedValue { $0 } == 3 }
        #expect(secondDrain == true)
        let checksAfterTTL = checkCount.withLockedValue { $0 }
        #expect(checksAfterTTL == 2)
        ingestor.shutdown()
    }
}
