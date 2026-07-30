import Foundation
import Logging
import Testing

@testable import SwiftFirecracker

#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// The process-supervision half of the client: the exit latch teardown depends
/// on, the output drains that keep a VMM from wedging on a full pipe, and the
/// pid identity check that is now the sole gate on whether a process gets
/// killed.
@Suite("Process supervision")
struct ProcessSupervisionTests {

    // MARK: - ExitLatch

    @Test("wait() resumes when the latch is signalled after suspending")
    func latchResumesOnLateSignal() async throws {
        let latch = ExitLatch()

        async let waited: Void = latch.wait()
        // Let the waiter suspend before signalling, so this exercises the
        // stored-continuation path rather than the already-signalled shortcut.
        try await Task.sleep(for: .milliseconds(50))
        latch.signal()

        await waited
        #expect(latch.isSignaled)
    }

    @Test("wait() returns immediately when already signalled")
    func latchReturnsWhenAlreadySignalled() async throws {
        let latch = ExitLatch()
        latch.signal()
        await latch.wait()
        #expect(latch.isSignaled)
    }

    @Test("wait(upTo:) reports false on expiry without spinning")
    func latchTimedWaitExpires() async throws {
        let latch = ExitLatch()
        let start = ContinuousClock.now
        let exited = await latch.wait(upTo: .milliseconds(120))
        let elapsed = ContinuousClock.now - start

        #expect(exited == false)
        // Should wait roughly the budget — not return instantly, and not
        // overshoot wildly.
        #expect(elapsed > .milliseconds(80))
        #expect(elapsed < .seconds(2))
    }

    @Test("wait(upTo:) reports true when signalled inside the budget")
    func latchTimedWaitSucceeds() async throws {
        let latch = ExitLatch()
        Task {
            try? await Task.sleep(for: .milliseconds(40))
            latch.signal()
        }
        let exited = await latch.wait(upTo: .seconds(5))
        #expect(exited)
    }

    @Test("a cancelled timed wait still completes rather than spinning")
    func latchTimedWaitSurvivesCancellation() async throws {
        let latch = ExitLatch()
        let task = Task { await latch.wait(upTo: .milliseconds(200)) }
        task.cancel()
        // The wait deliberately ignores cancellation (an early resume would let
        // a caller read a bogus terminationStatus), so it must still finish on
        // its own — the point is that it does so without burning a core.
        let exited = await task.value
        #expect(exited == false)
    }

    @Test("multiple waiters are all released by one signal")
    func latchReleasesAllWaiters() async throws {
        let latch = ExitLatch()
        async let first = latch.wait(upTo: .seconds(5))
        async let second = latch.wait(upTo: .seconds(5))
        async let third = latch.wait(upTo: .seconds(5))

        try await Task.sleep(for: .milliseconds(50))
        latch.signal()

        let results = await [first, second, third]
        #expect(results.allSatisfy { $0 })
    }

    // MARK: - OutputDrain

    /// Writes to a pipe and lets the drain consume it, returning the drain's
    /// view once it has caught up.
    private func drained(
        writing chunks: [String], limit: Int = 8192
    ) async throws -> String {
        let pipe = Pipe()
        let drain = try #require(
            OutputDrain(
                fileDescriptor: pipe.fileHandleForReading.fileDescriptor,
                label: "stdout", logger: Logger(label: "test"), limit: limit))
        defer { drain.stop() }

        for chunk in chunks {
            try pipe.fileHandleForWriting.write(contentsOf: Data(chunk.utf8))
        }
        try pipe.fileHandleForWriting.close()

        // The drain is event-driven; give it a moment to catch up.
        try await Task.sleep(for: .milliseconds(200))
        return drain.recentText()
    }

    @Test("the drain collects everything written to the pipe")
    func drainCollectsOutput() async throws {
        let text = try await drained(writing: ["hello\n", "world\n"])
        #expect(text.contains("hello"))
        #expect(text.contains("world"))
    }

    @Test("the retained tail is capped at the limit")
    func drainTrimsToLimit() async throws {
        // Well past the limit, so the ring must discard the oldest bytes.
        let chunks = (0..<200).map { "line-\($0)-padding-padding-padding\n" }
        let text = try await drained(writing: chunks, limit: 512)

        #expect(text.utf8.count <= 512)
        // The newest output survives; the oldest is gone.
        #expect(text.contains("line-199"))
        #expect(!text.contains("line-0-"))
    }

    @Test("a stream with no newlines cannot grow the buffer without bound")
    func drainCapsPartialLine() async throws {
        let text = try await drained(writing: [String(repeating: "x", count: 20_000)], limit: 256)
        #expect(text.utf8.count <= 256)
    }

    @Test("stop() is idempotent and safe to call after EOF")
    func drainStopIsIdempotent() async throws {
        let pipe = Pipe()
        let drain = try #require(
            OutputDrain(
                fileDescriptor: pipe.fileHandleForReading.fileDescriptor,
                label: "stderr", logger: Logger(label: "test")))
        try pipe.fileHandleForWriting.close()
        try await Task.sleep(for: .milliseconds(100))

        drain.stop()
        drain.stop()
        #expect(drain.recentText().isEmpty)
    }

    @Test("the drain owns its descriptor, so the caller's handle closing is harmless")
    func drainSurvivesCallerClosingItsHandle() async throws {
        let pipe = Pipe()
        let readFD = pipe.fileHandleForReading.fileDescriptor
        let drain = try #require(
            OutputDrain(
                fileDescriptor: readFD, label: "stdout", logger: Logger(label: "test")))
        defer { drain.stop() }

        // The drain dup'd the descriptor at init, so the caller closing its own
        // copy must not disturb the in-flight source. Before the dup this was a
        // close out from under a live DispatchSource.
        try pipe.fileHandleForReading.close()
        try pipe.fileHandleForWriting.write(contentsOf: Data("after-close\n".utf8))
        try pipe.fileHandleForWriting.close()

        try await Task.sleep(for: .milliseconds(200))
        #expect(drain.recentText().contains("after-close"))
    }

    // MARK: - PIDIdentity

    /// Spawns a long-lived process whose argv carries `trailing`, so the
    /// `/proc` scan has a real entry to find.
    ///
    /// `sh -c` rather than `sleep` directly: the extra words have to survive
    /// into the process's own argv, and `sleep` rejects unknown options and
    /// exits immediately. The `; :` is load-bearing too — dash exec-optimises
    /// `sh -c '<single command>'`, replacing the argv we are trying to observe.
    private func spawnCarryingArgv(_ trailing: [String]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 2; :", "fake-firecracker"] + trailing
        try process.run()
        return process
    }

    @Test("a live process matching the recorded socket path is recognised")
    func identityMatchesLiveProcess() async throws {
        #if os(Linux)
        let socketPath = "/tmp/fc-identity-\(UUID().uuidString.prefix(8)).sock"
        let process = try spawnCarryingArgv(["--api-sock", socketPath])
        // terminate() only: it signals the shell, not the `sleep` it forked, and
        // waitUntilExit() would then block on that grandchild holding the exit
        // descriptor. The orphan self-reaps well inside the suite.
        defer { process.terminate() }
        try await Task.sleep(for: .milliseconds(200))

        let identity = FirecrackerClient.PIDIdentity.socketPath(socketPath)
        #expect(identity.matches(pid: process.processIdentifier))
        // A different socket path must not match the same pid.
        #expect(
            !FirecrackerClient.PIDIdentity.socketPath("/tmp/other.sock")
                .matches(pid: process.processIdentifier))
        #else
        // /proc is Linux-only; off Linux the check is conservatively false.
        let identity = FirecrackerClient.PIDIdentity.socketPath("/tmp/whatever.sock")
        #expect(!identity.matches(pid: 1))
        #endif
    }

    @Test("a live process matching the recorded vm id is recognised")
    func identityMatchesLiveProcessByVMId() async throws {
        #if os(Linux)
        let vmId = "vm-\(UUID().uuidString.prefix(8))"
        let process = try spawnCarryingArgv(["--id", vmId])
        defer { process.terminate() }
        try await Task.sleep(for: .milliseconds(200))

        #expect(FirecrackerClient.PIDIdentity.vmId(vmId).matches(pid: process.processIdentifier))
        #expect(
            !FirecrackerClient.PIDIdentity.vmId("some-other-vm")
                .matches(pid: process.processIdentifier))
        #else
        #expect(!FirecrackerClient.PIDIdentity.vmId("anything").matches(pid: 1))
        #endif
    }

    @Test("an exited process no longer matches, so it is never signalled")
    func identityRejectsExitedProcess() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exit 0"]
        try process.run()
        process.waitUntilExit()
        try await Task.sleep(for: .milliseconds(100))

        // This is the check that stands between `destroyVM` and SIGKILLing an
        // unrelated process that inherited a recycled pid.
        let identity = FirecrackerClient.PIDIdentity.vmId("some-vm")
        #expect(!identity.matches(pid: process.processIdentifier))
    }

    @Test("a live process that is not ours does not match")
    func identityRejectsUnrelatedProcess() {
        // pid 1 exists on every platform and is definitively not a Firecracker
        // spawned by this client.
        let identity = FirecrackerClient.PIDIdentity.vmId("definitely-not-pid-1")
        #expect(!identity.matches(pid: 1))
    }

    @Test("argv matching accepts both --id spellings and rejects near misses")
    func argvMatching() {
        #expect(FirecrackerClient.argvCarriesVMId(["firecracker", "--id", "vm-1"], vmId: "vm-1"))
        #expect(FirecrackerClient.argvCarriesVMId(["firecracker", "--id=vm-1"], vmId: "vm-1"))
        #expect(!FirecrackerClient.argvCarriesVMId(["firecracker", "--id", "vm-11"], vmId: "vm-1"))
        #expect(!FirecrackerClient.argvCarriesVMId(["firecracker", "--id"], vmId: "vm-1"))
        #expect(!FirecrackerClient.argvCarriesVMId([], vmId: "vm-1"))
    }
}
