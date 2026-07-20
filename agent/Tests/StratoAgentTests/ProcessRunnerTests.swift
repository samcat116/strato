import Foundation
import Testing

@testable import StratoAgentCore

@Suite("Process Runner Tests")
struct ProcessRunnerTests {

    @Test("Captures exit status, stdout, and stderr")
    func capturesOutputAndStatus() async throws {
        let result = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo out; echo err >&2; exit 3"]
        )
        #expect(result.terminationStatus == 3)
        let stdout = String(data: result.standardOutput, encoding: .utf8)
        let stderr = String(data: result.standardError, encoding: .utf8)
        #expect(stdout == "out\n")
        #expect(stderr == "err\n")
    }

    @Test("A cancelled caller still waits for the child to exit")
    func cancellationStillWaitsForExit() async throws {
        // The child closes both output streams immediately (so the drains
        // finish long before exit), then keeps running briefly. A cancelled
        // waiter that returned early would read `terminationStatus` while the
        // child is still alive — a trap on Linux, garbage elsewhere.
        let task = Task {
            try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "exec 1>&- 2>&-; sleep 0.3; exit 7"]
            )
        }
        task.cancel()
        let result = try await task.value
        #expect(result.terminationStatus == 7)
    }

    @Test("A child that outlives its timeout is terminated and reported")
    func timeoutTerminatesAndThrows() async throws {
        // `waitForExit` deliberately ignores cancellation, so without the
        // watchdog this call would park for the full 60s and no caller could
        // escape it (issue #428 review).
        let started = Date()
        await #expect(throws: ProcessTimedOutError.self) {
            try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 60"],
                timeout: .milliseconds(200)
            )
        }
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 10)
    }

    @Test("A child that finishes inside its timeout is unaffected")
    func timeoutDoesNotDisturbFastChildren() async throws {
        let result = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf ok; exit 0"],
            timeout: .seconds(30)
        )
        #expect(result.terminationStatus == 0)
        let stdout = String(data: result.standardOutput, encoding: .utf8)
        #expect(stdout == "ok")
    }
}
