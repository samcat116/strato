import Foundation
import Testing

@testable import StratoAgentCore

@Suite("SingleFlight")
struct SingleFlightTests {

    /// Counts executions and lets a test hold an operation open until it says otherwise.
    private actor Recorder {
        private(set) var executions = 0
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func begin() { executions += 1 }

        func awaitRelease() async {
            if released { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            released = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }

    @Test("Concurrent callers for one key share a single execution")
    func concurrentCallersCoalesce() async throws {
        let flight = SingleFlight<String>()
        let recorder = Recorder()

        let callers = (0..<8).map { _ in
            Task {
                try await flight.run(key: "same") {
                    await recorder.begin()
                    await recorder.awaitRelease()
                    return "value"
                }
            }
        }

        // Let every caller reach the actor and join the flight before it finishes.
        while await recorder.executions == 0 {
            await Task.yield()
        }
        try await Task.sleep(for: .milliseconds(50))
        await recorder.release()

        for caller in callers {
            let value = try await caller.value
            #expect(value == "value")
        }
        let executions = await recorder.executions
        #expect(executions == 1)
    }

    @Test("Distinct keys run independently")
    func distinctKeysDoNotCoalesce() async throws {
        let flight = SingleFlight<String>()
        let recorder = Recorder()
        await recorder.release()

        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<4 {
                group.addTask {
                    try await flight.run(key: "key-\(index)") {
                        await recorder.begin()
                        return "value-\(index)"
                    }
                }
            }
            return try await group.reduce(into: [String]()) { $0.append($1) }
        }

        #expect(Set(results) == Set((0..<4).map { "value-\($0)" }))
        let executions = await recorder.executions
        #expect(executions == 4)
    }

    @Test("A finished flight is retired, so a later caller runs again")
    func flightIsNotACache() async throws {
        let flight = SingleFlight<String>()
        let recorder = Recorder()
        await recorder.release()

        for _ in 0..<3 {
            _ = try await flight.run(key: "same") {
                await recorder.begin()
                return "value"
            }
        }

        let executions = await recorder.executions
        #expect(executions == 3)
        let remaining = await flight.inFlightCount
        #expect(remaining == 0)
    }

    @Test("A cancelled waiter stops waiting without cancelling the shared operation")
    func cancelledWaiterStopsWaiting() async throws {
        let flight = SingleFlight<String>()
        let recorder = Recorder()

        // Two waiters on one flight. Callers wrap this in deadlines (StageBudget.run cancels
        // the operation task on timeout), so a cancelled waiter has to come back promptly
        // instead of sitting on someone else's download.
        let cancelled = Task {
            try await flight.run(key: "same") {
                await recorder.begin()
                await recorder.awaitRelease()
                return "value"
            }
        }
        let survivor = Task {
            try await flight.run(key: "same") {
                await recorder.begin()
                await recorder.awaitRelease()
                return "value"
            }
        }

        while await recorder.executions == 0 {
            await Task.yield()
        }
        try await Task.sleep(for: .milliseconds(50))

        cancelled.cancel()
        let cancelledResult = await cancelled.result
        #expect(throws: CancellationError.self) { try cancelledResult.get() }

        // The shared operation was never cancelled: releasing it still resolves the survivor.
        await recorder.release()
        let value = try await survivor.value
        #expect(value == "value")
        let executions = await recorder.executions
        #expect(executions == 1)
    }

    @Test("Failures propagate to every caller in the flight")
    func failurePropagatesToAllCallers() async throws {
        struct Boom: Error {}
        let flight = SingleFlight<String>()
        let recorder = Recorder()

        let callers = (0..<4).map { _ in
            Task {
                try await flight.run(key: "same") {
                    await recorder.begin()
                    await recorder.awaitRelease()
                    throw Boom()
                }
            }
        }

        while await recorder.executions == 0 {
            await Task.yield()
        }
        try await Task.sleep(for: .milliseconds(50))
        await recorder.release()

        for caller in callers {
            let result = await caller.result
            #expect(throws: Boom.self) { try result.get() }
        }
        let executions = await recorder.executions
        #expect(executions == 1)

        // A failed flight leaves nothing behind: the next caller retries rather than
        // inheriting the error.
        await recorder.release()
        let retried = try await flight.run(key: "same") {
            await recorder.begin()
            return "value"
        }
        #expect(retried == "value")
    }
}
