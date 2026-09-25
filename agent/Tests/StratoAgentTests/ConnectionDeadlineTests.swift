import Testing
@testable import StratoAgentCore

@Suite("Connection deadlines", .timeLimit(.minutes(1)))
struct ConnectionDeadlineTests {
    private actor Transport {
        var started = false
        var closed = false
        var cleanupFinished = false
        var interrupts = 0
        var waiter: CheckedContinuation<Void, Never>?

        func connect() async {
            started = true
            if closed { return }
            // Deliberately ignores task cancellation, as a library-owned
            // activation promise can. Only closing the transport releases it.
            await withCheckedContinuation { waiter = $0 }
        }
        func close() async {
            interrupts += 1
            closed = true
            waiter?.resume()
            waiter = nil
            await Task.yield()
            cleanupFinished = true
        }
    }

    @Test func timeoutInterruptsNonCooperativeConnect() async {
        let transport = Transport()
        await #expect(throws: ConnectionDeadline.Exceeded.self) {
            try await ConnectionDeadline.run(
                timeout: .milliseconds(20), connect: { await transport.connect() },
                interrupt: { await transport.close() })
        }
        #expect(await transport.closed)
        #expect(await transport.cleanupFinished)
        #expect(await transport.interrupts == 1)
    }

    @Test func cancellationInterruptsAndJoinsCleanup() async {
        let transport = Transport()
        let task = Task {
            try await ConnectionDeadline.run(
                timeout: .seconds(60), connect: { await transport.connect() },
                interrupt: { await transport.close() })
        }
        while !(await transport.started) { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await transport.closed)
        #expect(await transport.cleanupFinished)
        #expect(await transport.interrupts == 1)
    }

    @Test func successfulConnectKeepsTransportOpen() async throws {
        let transport = Transport()
        try await ConnectionDeadline.run(
            timeout: .seconds(60), connect: {}, interrupt: { await transport.close() })
        #expect(await transport.interrupts == 0)
    }
}
