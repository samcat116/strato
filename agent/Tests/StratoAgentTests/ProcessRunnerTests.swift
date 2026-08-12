import Foundation
import Testing

@testable import StratoAgentCore

@Suite("Process Runner Tests", .serialized)
struct ProcessRunnerTests {

    private let descriptorChildEnvironmentKey =
        "STRATO_PROCESS_RUNNER_DESCRIPTOR_STRESS_SCENARIO"
    private let commandDescriptorStressIterations = 1_200
    // Linux corelibs-foundation needs substantially longer to reap each
    // timed-out child. Fifty iterations still exceed the old two-FD leak's
    // allowance without making this suite take several minutes.
    private let timeoutDescriptorStressIterations = 50
    private let descriptorSampleInterval = 100
    private let descriptorAllowance = 64

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

    @Test("A child crossing the combined output ceiling is terminated")
    func outputLimitTerminatesAndThrows() async {
        await #expect(throws: ProcessRunnerError.self) {
            try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf 12345; printf 67890 >&2"],
                timeout: .seconds(5),
                maxOutputBytes: 8)
        }
    }

    @Test("Repeated successful commands release their file descriptors")
    func successfulCommandsReleaseFileDescriptors() async throws {
        let scenario = "successful"
        if try await launchIsolatedDescriptorTestIfNeeded(
            scenario: scenario,
            filter: "ProcessRunnerTests.successfulCommandsReleaseFileDescriptors"
        ) {
            return
        }
        let baseline = try openFileDescriptorCount()

        for iteration in 0..<commandDescriptorStressIterations {
            let result = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf ok"]
            )
            #expect(result.terminationStatus == 0)
            try requireOpenFileDescriptorsRemainBounded(
                after: iteration, from: baseline)
        }

        try requireOpenFileDescriptorsRemainBounded(from: baseline)
        print(descriptorTestSentinel(for: scenario))
    }

    @Test("Repeated failed commands release their file descriptors")
    func failedCommandsReleaseFileDescriptors() async throws {
        let scenario = "failed"
        if try await launchIsolatedDescriptorTestIfNeeded(
            scenario: scenario,
            filter: "ProcessRunnerTests.failedCommandsReleaseFileDescriptors"
        ) {
            return
        }
        let baseline = try openFileDescriptorCount()

        for iteration in 0..<commandDescriptorStressIterations {
            let result = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "exit 1"]
            )
            #expect(result.terminationStatus == 1)
            try requireOpenFileDescriptorsRemainBounded(
                after: iteration, from: baseline)
        }

        try requireOpenFileDescriptorsRemainBounded(from: baseline)
        print(descriptorTestSentinel(for: scenario))
    }

    @Test("Repeated timed-out commands release their file descriptors")
    func timedOutCommandsReleaseFileDescriptors() async throws {
        let scenario = "timed-out"
        if try await launchIsolatedDescriptorTestIfNeeded(
            scenario: scenario,
            filter: "ProcessRunnerTests.timedOutCommandsReleaseFileDescriptors"
        ) {
            return
        }
        let baseline = try openFileDescriptorCount()

        for iteration in 0..<timeoutDescriptorStressIterations {
            await #expect(throws: ProcessTimedOutError.self) {
                try await ProcessRunner.run(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "exec >/dev/null 2>&1; exec sleep 60"],
                    timeout: .milliseconds(5)
                )
            }
            try requireOpenFileDescriptorsRemainBounded(
                after: iteration, from: baseline)
        }

        try requireOpenFileDescriptorsRemainBounded(from: baseline)
        print(descriptorTestSentinel(for: scenario))
    }

    /// Descriptor counts are process-wide. The agent suite runs in parallel,
    /// so each stress scenario re-executes only itself in a child test process
    /// where unrelated suites cannot move the baseline.
    private func launchIsolatedDescriptorTestIfNeeded(
        scenario: String,
        filter: String
    ) async throws -> Bool {
        if ProcessInfo.processInfo.environment[descriptorChildEnvironmentKey] == scenario {
            return false
        }

        var environment = ProcessInfo.processInfo.environment
        environment[descriptorChildEnvironmentKey] = scenario
        var arguments = Array(CommandLine.arguments.dropFirst())
        if let filterIndex = arguments.firstIndex(of: "--filter"),
            arguments.indices.contains(filterIndex + 1)
        {
            arguments[filterIndex + 1] = filter
        } else {
            arguments.append(contentsOf: ["--filter", filter])
        }
        let result = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: CommandLine.arguments[0]),
            arguments: arguments,
            timeout: .seconds(300),
            environment: environment,
            maxOutputBytes: 1 << 20)
        let output = result.combinedOutput
        try #require(
            result.terminationStatus == 0,
            "isolated descriptor test failed: \(output)")
        try #require(
            output.contains(descriptorTestSentinel(for: scenario)),
            "isolated descriptor test did not execute: \(output)")
        return true
    }

    private func descriptorTestSentinel(for scenario: String) -> String {
        "STRATO_PROCESS_RUNNER_DESCRIPTOR_STRESS_PASSED_\(scenario)"
    }

    private func requireOpenFileDescriptorsRemainBounded(
        after iteration: Int? = nil,
        from baseline: Int
    ) throws {
        if let iteration, !(iteration + 1).isMultiple(of: descriptorSampleInterval) {
            return
        }
        let observed = try openFileDescriptorCount()
        try #require(
            observed <= baseline + descriptorAllowance,
            "open file descriptors grew from \(baseline) to \(observed)"
        )
    }

    private func openFileDescriptorCount() throws -> Int {
        #if os(Linux)
        let descriptorDirectory = "/proc/self/fd"
        #else
        let descriptorDirectory = "/dev/fd"
        #endif
        return try FileManager.default.contentsOfDirectory(atPath: descriptorDirectory).count
    }
}
