import Foundation

#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Result of running a subprocess to completion.
public struct ProcessResult: Sendable {
    public let terminationStatus: Int32
    public let standardOutput: Data
    public let standardError: Data

    public init(terminationStatus: Int32, standardOutput: Data, standardError: Data) {
        self.terminationStatus = terminationStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    /// stdout and stderr decoded and concatenated — convenient for building
    /// human-readable error messages where the two streams were previously
    /// merged into a single pipe.
    public var combinedOutput: String {
        let out = String(data: standardOutput, encoding: .utf8) ?? ""
        let err = String(data: standardError, encoding: .utf8) ?? ""
        return out + err
    }
}

public enum ProcessRunnerError: Error, CustomStringConvertible {
    /// A streamed subprocess wrote more than the caller's byte ceiling and was
    /// terminated. Used to stop a decompression bomb from filling the host disk.
    case outputLimitExceeded(limit: Int)

    public var description: String {
        switch self {
        case .outputLimitExceeded(let limit):
            return "process output exceeded the \(limit)-byte limit and was terminated"
        }
    }
}

/// Thrown when a `run(executableURL:arguments:timeout:)` budget expires. The
/// child has been sent SIGTERM by the time this surfaces, so the call returns
/// promptly instead of leaking a subprocess.
public struct ProcessTimedOutError: Error, CustomStringConvertible, Sendable {
    public let executable: String
    public let timeout: Duration

    public var description: String {
        "\(executable) did not exit within \(timeout)"
    }
}

/// Runs external commands without blocking the Swift concurrency cooperative
/// thread pool.
///
/// `Process.run()` + `waitUntilExit()` blocks the calling thread for the entire
/// lifetime of the subprocess. Doing that directly inside an `async` method ties
/// up a cooperative-pool thread, which can starve unrelated work. `ProcessRunner`
/// moves pipe draining onto global dispatch queues and observes exit through the
/// process's `terminationHandler`, so `await`ing it suspends rather than blocks.
///
/// Exit is deliberately NOT observed via `waitUntilExit()`: on macOS
/// (reproducible with the Xcode 27.0 beta toolchain) it can block forever when
/// the child exits quickly — Foundation's internal event machinery reaps the
/// child, but the thread parked in `waitUntilExit()` misses its wakeup.
/// `terminationHandler` is driven by the same event that performs the reap, so
/// it cannot miss, provided it is installed before the process is launched.
public enum ProcessRunner {
    /// Launches `executableURL` with `arguments`, draining stdout and stderr, and
    /// returns once the process exits.
    ///
    /// stdout and stderr are drained concurrently (each from its own file
    /// descriptor), so a process that fills one stream while the other is idle
    /// cannot deadlock.
    ///
    /// `timeout` bounds the child's lifetime. It matters because `waitForExit`
    /// deliberately ignores cancellation, so without it a child that never
    /// exits parks this call forever — and callers on the agent's registration
    /// path have no other escape (issue #428 review). On expiry the child is
    /// sent SIGTERM, which closes its pipes so both drains hit EOF and the
    /// termination handler fires; the normal path below then completes and
    /// `ProcessTimedOutError` is thrown. Nil means wait indefinitely, the
    /// behaviour every existing caller already relies on.
    public static func run(
        executableURL: URL,
        arguments: [String],
        timeout: Duration? = nil
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let exited = exitSignal(for: process)

        // `run()` only spawns the child and returns; it does not block for the
        // subprocess lifetime, so calling it inline is fine.
        try process.run()

        // Watchdog on the pid rather than the `Process` (which is not
        // Sendable). It re-checks the exit latch before signalling so a child
        // that finished while the budget was expiring is never killed by pid
        // after the kernel may have recycled it. SIGKILL follows SIGTERM so a
        // child that ignores the polite signal still can't park `waitForExit`,
        // which is not cancellation-aware.
        let expired = TimeoutFlag()
        let watchdog = timeout.map { budget -> Task<Void, Never> in
            let pid = process.processIdentifier
            return Task {
                try? await Task.sleep(for: budget)
                guard !Task.isCancelled, !exited.isSignaled else { return }
                expired.trip()
                kill(pid, SIGTERM)
                try? await Task.sleep(for: signalEscalationGrace)
                guard !exited.isSignaled else { return }
                kill(pid, SIGKILL)
            }
        }
        defer { watchdog?.cancel() }

        // Drain both streams concurrently before awaiting exit — a full pipe
        // buffer on either stream would otherwise stall the subprocess.
        //
        // The drains get their own deadline rather than relying on the child's
        // death to close the pipes: a *grandchild* inherits the write ends, so
        // killing the direct child does not necessarily produce EOF. Without
        // this, `/bin/sh script-that-runs-sleep-60` returns only when the
        // orphaned `sleep` exits — the timeout would appear to do nothing.
        let drainDeadline = timeout.map {
            Date().addingTimeInterval(Double($0.components.seconds) + drainGrace)
        }
        let stdoutFD = stdoutPipe.fileHandleForReading.fileDescriptor
        let stderrFD = stderrPipe.fileHandleForReading.fileDescriptor
        async let stdoutData = drain(fd: stdoutFD, deadline: drainDeadline)
        async let stderrData = drain(fd: stderrFD, deadline: drainDeadline)

        let (out, err) = await (stdoutData, stderrData)

        // The timed-out path must not wait unboundedly for the termination
        // handler. On Linux, corelibs-foundation detects exit through an
        // internal descriptor the child can pass on: a grandchild that
        // inherited it holds the handler hostage until *it* exits (observed:
        // `sh -c "sleep 60"` — sh dies to SIGKILL at once, but its handler
        // fires only when the orphaned sleep ends). This path throws without
        // ever reading `terminationStatus`, so it does not need the handler;
        // the bounded wait just keeps bookkeeping tidy when the kill worked.
        if expired.isTripped, let timeout {
            _ = await exited.wait(upTo: exitObservationGrace)
            throw ProcessTimedOutError(
                executable: executableURL.lastPathComponent, timeout: timeout)
        }

        await waitForExit(exited)

        if expired.isTripped, let timeout {
            throw ProcessTimedOutError(
                executable: executableURL.lastPathComponent, timeout: timeout)
        }

        return ProcessResult(
            terminationStatus: process.terminationStatus,
            standardOutput: out,
            standardError: err
        )
    }

    /// Launches `executableURL` with stdin wired to `inputFile` and stdout to
    /// `outputFile` (created/truncated), so arbitrarily large streams never
    /// pass through this process's memory — used for filter-style tools like
    /// gzip/zstd. stderr is drained into the result for error messages;
    /// `standardOutput` in the result is always empty.
    public static func runStreaming(
        executableURL: URL,
        arguments: [String],
        inputFile: URL,
        outputFile: URL,
        maxOutputBytes: Int? = nil
    ) async throws -> ProcessResult {
        let inputHandle = try FileHandle(forReadingFrom: inputFile)
        defer { try? inputHandle.close() }
        FileManager.default.createFile(atPath: outputFile.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputFile)
        defer { try? outputHandle.close() }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = inputHandle
        process.standardOutput = outputHandle

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        let exited = exitSignal(for: process)

        try process.run()

        // Enforce an output ceiling by polling the growing output file and
        // terminating the subprocess if it blows past the limit. The stream
        // goes straight to the file (not through this process's memory), so the
        // size must be observed out of band. This is what stops a decompression
        // bomb — a tiny, digest-valid gzip/zstd layer expanding to fill the
        // host disk — since the ceiling can't be derived from the trusted input.
        let outputPath = outputFile.path
        let limitMonitor: Task<Bool, Never>? = maxOutputBytes.map { limit in
            Task {
                while process.isRunning {
                    // stat(2) rather than FileManager attributes: this is the
                    // enforcement point of a security control, and an NSNumber
                    // bridging cast that returns nil would silently disable the
                    // ceiling instead of failing loudly.
                    if let size = fileSize(atPath: outputPath), size > Int64(limit) {
                        process.terminate()
                        // A decompressor that ignores SIGTERM would keep
                        // filling the disk, so give it a moment and escalate.
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        if process.isRunning {
                            kill(process.processIdentifier, SIGKILL)
                        }
                        return true
                    }
                    try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
                }
                return false
            }
        }

        let stderrFD = stderrPipe.fileHandleForReading.fileDescriptor
        async let stderrData = drain(fd: stderrFD)

        let err = await stderrData
        await waitForExit(exited)

        if await limitMonitor?.value == true {
            try? FileManager.default.removeItem(atPath: outputPath)
            throw ProcessRunnerError.outputLimitExceeded(limit: maxOutputBytes ?? 0)
        }

        return ProcessResult(
            terminationStatus: process.terminationStatus,
            standardOutput: Data(),
            standardError: err
        )
    }

    /// Current size of `path` via `stat(2)`, or nil if it cannot be read.
    static func fileSize(atPath path: String) -> Int64? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return Int64(info.st_size)
    }

    /// Grace between SIGTERM and SIGKILL for a timed-out child.
    private static let signalEscalationGrace: Duration = .seconds(2)

    /// How long the timed-out path waits for the termination handler before
    /// throwing anyway — bounded because a grandchild can delay the handler
    /// indefinitely on Linux (see the comment at the call site).
    private static let exitObservationGrace: Duration = .seconds(3)

    /// Extra time the drains get beyond the child's own budget, so a child
    /// killed at its deadline still has its final bytes collected before the
    /// readers give up.
    private static let drainGrace: TimeInterval = 3

    /// Reads a file descriptor to EOF on a background queue, or until
    /// `deadline` passes. Nil deadline reads to EOF unconditionally — the
    /// behaviour every caller without a timeout relies on.
    private static func drain(fd: Int32, deadline: Date? = nil) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var data = Data()
                let bufferSize = 4096
                var buffer = [UInt8](repeating: 0, count: bufferSize)
                while true {
                    if let deadline {
                        // Poll in slices so an expired deadline is noticed even
                        // while a grandchild holds the write end open and no
                        // bytes are arriving.
                        let remaining = deadline.timeIntervalSinceNow
                        if remaining <= 0 { break }
                        var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                        let slice = Int32(min(remaining, 1) * 1000)
                        let ready = poll(&pollFD, 1, slice)
                        if ready < 0 {
                            if errno == EINTR { continue }
                            break
                        }
                        if ready == 0 { continue }
                    }
                    let count = buffer.withUnsafeMutableBytes { ptr in
                        read(fd, ptr.baseAddress, bufferSize)
                    }
                    if count < 0 {
                        if errno == EINTR { continue }
                        break
                    }
                    if count == 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
                continuation.resume(returning: data)
            }
        }
    }

    /// Installs a termination handler on `process` and returns a latch that
    /// opens when it fires. Must be called before `process.run()` — a
    /// fast-exiting child could otherwise terminate before the handler is
    /// installed and never signal it.
    private static func exitSignal(for process: Process) -> ExitLatch {
        let latch = ExitLatch()
        process.terminationHandler = { _ in latch.signal() }
        return latch
    }

    /// Suspends until the process's termination handler has fired. Once this
    /// returns, the process's `terminationStatus` is valid.
    ///
    /// Deliberately NOT cancellation-aware: callers run under cancelling
    /// timeouts (e.g. `StageBudget`), and returning early would let them read
    /// `terminationStatus` while the child is still alive — a trap on Linux.
    private static func waitForExit(_ exited: ExitLatch) async {
        await exited.wait()
    }

    /// A one-shot latch bridging `Process.terminationHandler` to async. Safe
    /// against every ordering: the handler may fire before, during, or after
    /// `wait()` suspends. `wait()` uses a bare continuation with no
    /// cancellation handler, so a cancelled caller still waits for the signal.
    private final class ExitLatch: @unchecked Sendable {
        private let lock = NSLock()
        private var signaled = false
        private var continuation: CheckedContinuation<Void, Never>?

        func signal() {
            lock.lock()
            signaled = true
            let waiter = continuation
            continuation = nil
            lock.unlock()
            waiter?.resume()
        }

        /// Whether the child has already exited, for the timeout watchdog's
        /// last-moment check before it signals by pid.
        var isSignaled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return signaled
        }

        /// Bounded wait for the signal, for the timed-out path only. Polling
        /// rather than a second continuation: the latch holds exactly one
        /// waiter, and a raced-and-abandoned continuation would leak.
        func wait(upTo budget: Duration) async -> Bool {
            let deadline = ContinuousClock.now + budget
            while ContinuousClock.now < deadline {
                if isSignaled { return true }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return isSignaled
        }

        func wait() async {
            await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
                lock.lock()
                if signaled {
                    lock.unlock()
                    waiter.resume()
                } else {
                    continuation = waiter
                    lock.unlock()
                }
            }
        }
    }

    /// One-way flag recording that the timeout watchdog fired, so `run` can
    /// tell a SIGTERM it requested from one the child received elsewhere.
    private final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var tripped = false

        func trip() {
            lock.lock()
            tripped = true
            lock.unlock()
        }

        var isTripped: Bool {
            lock.lock()
            defer { lock.unlock() }
            return tripped
        }
    }
}
