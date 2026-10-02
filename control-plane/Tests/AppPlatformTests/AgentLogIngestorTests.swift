import Foundation
import NIOConcurrencyHelpers
import StratoShared
import Testing
import Vapor

import AppTestSupport
@testable import App

/// Unit tests for `AgentLogIngestor`: the serial consumer must preserve
/// enqueue order (Loki rejects out-of-order entries per stream) and must
/// cache both positive and negative agent-ownership answers within the TTL
/// instead of issuing one database query per log line.
///
/// The ingestor's dependencies are injected closures, so these tests need no
/// application, database, or Loki.
@Suite("Agent Log Ingestor Tests")
struct AgentLogIngestorTests {

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
                pushed.withLockedValue { $0.append(contentsOf: message.map(\.message)) }
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
            push: { messages in
                pushedCount.withLockedValue { $0 += messages.count }
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
            push: { messages in
                pushedCount.withLockedValue { $0 += messages.count }
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

    /// The VM console path (issue #698) used to issue one `VM.find` per log
    /// line; it now shares the sandbox pipeline, so a chatty guest costs one
    /// ownership query per (vm, agent) per TTL and spoofed lines still drop.
    @Test("VM log lines share the cached ownership check")
    func vmLogsCacheOwnership() async throws {
        let checks = NIOLockedValueBox<[String]>([])
        let pushed = NIOLockedValueBox<[String]>([])
        let ingestor = VMLogIngestor(
            logger: Logger(label: "test"),
            checkOwnership: { vmId, _ in
                checks.withLockedValue { $0.append(vmId) }
                return vmId == "owned"
            },
            push: { message in
                pushed.withLockedValue { $0.append(contentsOf: message.map(\.message)) }
            }
        )

        func makeVMMessage(vmId: String, line: String) -> VMLogMessage {
            VMLogMessage(
                vmId: vmId, level: .info, source: .agent, eventType: .operation, message: line)
        }

        for index in 0..<50 {
            ingestor.enqueue(makeVMMessage(vmId: "spoofed", line: "drop"), fromAgentKey: agentKey("agent-a"))
            ingestor.enqueue(makeVMMessage(vmId: "owned", line: "line-\(index)"), fromAgentKey: agentKey("agent-a"))
        }

        let drained = await poll { pushed.withLockedValue { $0.count } == 50 }
        #expect(drained == true)

        // One query per (vm, agent) pair regardless of line rate, and the
        // consumer preserved enqueue order for the owned VM's stream.
        let consulted = checks.withLockedValue { $0 }
        #expect(consulted == ["spoofed", "owned"])
        let lines = pushed.withLockedValue { $0 }
        #expect(lines == (0..<50).map { "line-\($0)" })
        ingestor.shutdown()
    }
    @Test("Hung delivery stays bounded, sheds oldest, batches followers and cancels at shutdown")
    func slowConsumer() async throws {
        let batches = NIOLockedValueBox<[[String]]>([])
        let release = NIOLockedValueBox(false)
        let ingestor = SandboxLogIngestor(
            logger: Logger(label: "test"), bufferLimitBytes: 4096, batchInterval: .zero,
            checkOwnership: { _, _ in true },
            push: { messages in
                let first = batches.withLockedValue { batches in
                    batches.append(messages.map(\.message))
                    return batches.count == 1
                }
                if first {
                    while !release.withLockedValue({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
                }
            }
        )
        ingestor.enqueue(makeMessage(sandboxId: "s", line: "initial"), fromAgentKey: "a")
        #expect(await poll { batches.withLockedValue { $0.count == 1 } })
        for index in 0..<100_000 {
            ingestor.enqueue(makeMessage(sandboxId: "s", line: "line-\(index)"), fromAgentKey: "a")
        }
        let snapshot = ingestor.queueSnapshot
        #expect(snapshot.bytes <= 4096)
        #expect(snapshot.count < 32)
        #expect(snapshot.dropped > 99_900)
        release.withLockedValue { $0 = true }
        #expect(await poll { batches.withLockedValue { $0.count == 2 } })
        let followers = batches.withLockedValue { $0[1] }
        #expect(followers == (100_000 - snapshot.count..<100_000).map { "line-\($0)" })
        ingestor.shutdown()
        #expect(ingestor.queueSnapshot.bytes == 0)
    }

    @Test("Shutdown cancels an active push and releases all pending lines")
    func cancelsStalledPush() async {
        let started = NIOLockedValueBox(false)
        let cancelled = NIOLockedValueBox(false)
        let ingestor = SandboxLogIngestor(
            logger: Logger(label: "test"), batchInterval: .zero,
            checkOwnership: { _, _ in true },
            push: { _ in
                started.withLockedValue { $0 = true }
                defer { cancelled.withLockedValue { $0 = Task.isCancelled } }
                try await Task.sleep(for: .seconds(300))
            }
        )
        ingestor.enqueue(makeMessage(sandboxId: "s", line: "initial"), fromAgentKey: "a")
        #expect(await poll { started.withLockedValue { $0 } })
        for _ in 0..<1000 { ingestor.enqueue(makeMessage(sandboxId: "s", line: "pending"), fromAgentKey: "a") }
        ingestor.shutdown()
        #expect(ingestor.queueSnapshot.count == 0)
        #expect(await poll { cancelled.withLockedValue { $0 } })
    }

    @Test("Cached unowned lines never occupy the queue while Loki is stalled")
    func earlyOwnershipRejection() async {
        let checked = NIOLockedValueBox(false)
        let started = NIOLockedValueBox(false)
        let ingestor = SandboxLogIngestor(
            logger: Logger(label: "test"), batchInterval: .zero,
            checkOwnership: { resource, _ in
                if resource == "spoofed" { checked.withLockedValue { $0 = true }; return false }
                return true
            },
            push: { _ in
                started.withLockedValue { $0 = true }
                try await Task.sleep(for: .seconds(300))
            }
        )
        ingestor.enqueue(makeMessage(sandboxId: "spoofed", line: "x"), fromAgentKey: "a")
        ingestor.enqueue(makeMessage(sandboxId: "owned", line: "x"), fromAgentKey: "a")
        #expect(await poll { checked.withLockedValue { $0 } && started.withLockedValue { $0 } })
        for _ in 0..<10_000 { ingestor.enqueue(makeMessage(sandboxId: "spoofed", line: "x"), fromAgentKey: "a") }
        #expect(ingestor.queueSnapshot.count == 0)
        #expect(ingestor.queueSnapshot.dropped == 0)
        ingestor.shutdown()
    }

    @Test("Loki outage sheds immediately and allows one serial recovery probe per window")
    func circuitBreaker() async {
        struct Failed: Error {}
        let clock = NIOLockedValueBox(Date())
        let pushes = NIOLockedValueBox(0)
        let ingestor = SandboxLogIngestor(
            logger: Logger(label: "test"), now: { clock.withLockedValue { $0 } }, batchInterval: .zero,
            checkOwnership: { _, _ in true },
            push: { _ in
                let attempt = pushes.withLockedValue {
                    $0 += 1; return $0
                }
                if attempt < 3 { throw Failed() }
            }
        )
        ingestor.enqueue(makeMessage(sandboxId: "s", line: "fails"), fromAgentKey: "a")
        #expect(await poll { ingestor.isCircuitOpen })
        for _ in 0..<10_000 { ingestor.enqueue(makeMessage(sandboxId: "s", line: "drop"), fromAgentKey: "a") }
        #expect(pushes.withLockedValue { $0 } == 1)
        #expect(ingestor.queueSnapshot.count == 0)
        clock.withLockedValue { $0 = $0.addingTimeInterval(31) }
        ingestor.enqueue(makeMessage(sandboxId: "s", line: "probe"), fromAgentKey: "a")
        #expect(await poll { pushes.withLockedValue { $0 == 2 } && ingestor.isCircuitOpen })
        clock.withLockedValue { $0 = $0.addingTimeInterval(31) }
        ingestor.enqueue(makeMessage(sandboxId: "s", line: "recovers"), fromAgentKey: "a")
        #expect(await poll { pushes.withLockedValue { $0 == 3 } && !ingestor.isCircuitOpen })
        ingestor.enqueue(makeMessage(sandboxId: "s", line: "healthy"), fromAgentKey: "a")
        #expect(await poll { pushes.withLockedValue { $0 == 4 } })
        ingestor.shutdown()
    }

    @Test("Time flush batches sparse entries, size flush leaves a bounded active batch")
    func batchesBySizeAndTime() async {
        let batches = NIOLockedValueBox<[[String]]>([])
        let ingestor = SandboxLogIngestor(
            logger: Logger(label: "test"), batchInterval: .milliseconds(100),
            checkOwnership: { _, _ in true },
            push: { messages in batches.withLockedValue { $0.append(messages.map(\.message)) } }
        )
        for index in 0..<300 { ingestor.enqueue(makeMessage(sandboxId: "s", line: "\(index)"), fromAgentKey: "a") }
        #expect(await poll { batches.withLockedValue { $0.flatMap { $0 }.count == 300 } })
        #expect(batches.withLockedValue { $0.map(\.count) } == [256, 44])
        #expect(batches.withLockedValue { $0.flatMap { $0 } } == (0..<300).map(String.init))
        ingestor.shutdown()
    }

    @Test("All retained strings count toward the queue budget, including request IDs")
    func requestIDBudget() async {
        let checks = NIOLockedValueBox(0)
        let ingestor = SandboxLogIngestor(
            logger: Logger(label: "test"), bufferLimitBytes: 1024,
            checkOwnership: { _, _ in
                checks.withLockedValue { $0 += 1 }; return true
            },
            push: { _ in Issue.record("Oversize message reached Loki") }
        )
        ingestor.enqueue(
            SandboxLogMessage(
                requestId: String(repeating: "x", count: 2048), sandboxId: "s", stream: "stdout", message: "x"),
            fromAgentKey: "a")
        #expect(ingestor.queueSnapshot.count == 0)
        #expect(ingestor.queueSnapshot.dropped == 1)
        ingestor.enqueue(makeMessage(sandboxId: String(repeating: "x", count: 1024), line: "x"), fromAgentKey: "a")
        #expect(ingestor.queueSnapshot.count == 0)
        #expect(checks.withLockedValue { $0 } == 0)
        ingestor.shutdown()
    }

}
