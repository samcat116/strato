import Dispatch
import Foundation
import Logging
import NIOConcurrencyHelpers

#if os(Linux)
import Glibc

// Glibc exposes SIGRTMIN as a function-backed macro, which Swift cannot import.
// Firecracker uses the same function plus one for its vCPU kick signal.
@_silgen_name("__libc_current_sigrtmin")
private func libcCurrentSignalRTMin() -> Int32
#else
import Darwin
#endif

/// Launches Firecracker with the real-time signal its vCPU threads use left
/// unblocked in the child.
///
/// libdispatch blocks almost every signal on its worker threads. Linux process
/// launch inherits the launching thread's mask in the child, and Firecracker's
/// vCPU threads inherit it again. If `SIGRTMIN + 1` stays blocked, `PATCH /vm`
/// queues Pause and sets KVM's `immediate_exit`, but the kick signal remains
/// pending and a vCPU in `KVM_RUN` never returns to acknowledge the request.
///
/// The mask change is scoped to the synchronous `Process.run()`: the child
/// inherits the unblocked bit, then this thread gets its exact old mask back.
/// Ordinary subprocesses do not need this Firecracker-specific exception.
enum FirecrackerProcessLauncher {
    #if os(Linux)
    static var vcpuKickSignal: Int32 { libcCurrentSignalRTMin() + 1 }

    static func withVCPUKickSignalUnblocked<T>(_ operation: () throws -> T) throws -> T {
        var kickSet = sigset_t()
        guard sigemptyset(&kickSet) == 0, sigaddset(&kickSet, vcpuKickSignal) == 0 else {
            throw FirecrackerError.processSpawnFailed(
                "could not construct the Firecracker vCPU signal mask: \(String(cString: strerror(errno)))")
        }

        var oldMask = sigset_t()
        let unblockResult = pthread_sigmask(SIG_UNBLOCK, &kickSet, &oldMask)
        guard unblockResult == 0 else {
            throw FirecrackerError.processSpawnFailed(
                "could not unblock Firecracker vCPU signal \(vcpuKickSignal): "
                    + String(cString: strerror(unblockResult)))
        }
        defer { _ = pthread_sigmask(SIG_SETMASK, &oldMask, nil) }
        return try operation()
    }
    #else
    static func withVCPUKickSignalUnblocked<T>(_ operation: () throws -> T) throws -> T {
        try operation()
    }
    #endif

    static func run(_ process: Process) throws {
        try withVCPUKickSignalUnblocked { try process.run() }
    }
}

/// A one-shot latch bridging `Process.terminationHandler` into async/await.
///
/// `Process.waitUntilExit()` blocks the calling thread — inside an actor that
/// means the actor is held for the whole teardown and every other VM's
/// operations queue behind it. This latch lets the wait suspend instead.
///
/// Waiters genuinely suspend until signalled; there is no polling. A timed wait
/// registers a `DispatchQueue.asyncAfter` that resumes the same waiter with
/// `false`, so an expired budget costs one timer rather than a wakeup every
/// 20 ms. Safe against every ordering: the handler may fire before, during, or
/// after a `wait` suspends, and multiple waiters are supported.
final class ExitLatch: Sendable {
    private struct State {
        var signaled = false
        var waiters: [UInt64: CheckedContinuation<Bool, Never>] = [:]
        var nextWaiterID: UInt64 = 0
    }

    private let state = NIOLockedValueBox(State())

    /// Marks the process as exited and wakes every waiter. Idempotent.
    func signal() {
        let waiting = state.withLockedValue { state -> [CheckedContinuation<Bool, Never>] in
            guard !state.signaled else { return [] }
            state.signaled = true
            let waiting = Array(state.waiters.values)
            state.waiters.removeAll()
            return waiting
        }
        waiting.forEach { $0.resume(returning: true) }
    }

    var isSignaled: Bool {
        state.withLockedValue { $0.signaled }
    }

    /// Suspends until the child exits.
    ///
    /// Deliberately not cancellation-aware: `terminationStatus` is only valid
    /// once the handler has fired, so resuming a cancelled caller early would
    /// let it read a bogus status.
    func wait() async {
        _ = await wait(upTo: nil)
    }

    /// Suspends until the child exits or `budget` elapses, returning whether it
    /// exited. A `nil` budget waits indefinitely.
    ///
    /// A bounded wait matters on teardown paths: on Linux a grandchild that
    /// inherited the exit descriptor can hold the termination handler hostage
    /// long after the child itself is gone.
    @discardableResult
    func wait(upTo budget: Duration?) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let waiterID = state.withLockedValue { state -> UInt64? in
                guard !state.signaled else { return nil }
                let id = state.nextWaiterID
                state.nextWaiterID += 1
                state.waiters[id] = continuation
                return id
            }
            guard let id = waiterID else {
                continuation.resume(returning: true)
                return
            }

            guard let budget else { return }
            let deadline = DispatchTime.now() + .milliseconds(Int(budget / .milliseconds(1)))
            DispatchQueue.global().asyncAfter(deadline: deadline) { [weak self] in
                guard let self else { return }
                // Resume only if this waiter is still registered; `signal()`
                // may have taken it first.
                let waiter = self.state.withLockedValue { $0.waiters.removeValue(forKey: id) }
                waiter?.resume(returning: false)
            }
        }
    }
}

/// Continuously drains one of a child's output pipes, retaining only the most
/// recent bytes.
///
/// A pipe that nobody reads fills its ~64KB kernel buffer and then blocks the
/// writer *inside the VMM* — a Firecracker logging at `Info` will eventually
/// wedge the whole microVM. Equally, dropping the read end while the child is
/// still alive (which happens when the spawning `Process` handle is released)
/// leaves it writing into a broken pipe. Draining continuously avoids both.
///
/// The drain is event-driven via `DispatchSource`, so it holds no thread while
/// idle — important because a host runs many VMs at once and a parked reader
/// thread per stream would exhaust the pool.
///
/// The drain **owns its descriptor**: it dups the pipe's read end at init and
/// closes that copy from the source's cancel handler. GCD requires a monitored
/// descriptor stay open until cancellation completes, and `cancel()` is
/// asynchronous — so letting a `FileHandle` deinit close the original out from
/// under an in-flight cancellation would be a use-after-close of exactly the
/// kind this package moved to NIO to eliminate.
///
/// Safety: `recent`, `partialLine`, and `source` are accessed only under
/// `lock`; `fd` is immutable, read only by the source handler, and closed only
/// by that source's cancel handler after GCD stops callbacks.
final class OutputDrain: @unchecked Sendable {
    private let lock = NSLock()
    private var recent = Data()
    private var partialLine = Data()
    private let limit: Int
    private let label: String
    private let logger: Logger
    private let fd: Int32
    private var source: DispatchSourceRead?

    /// - Parameters:
    ///   - fileDescriptor: The pipe's read end. Duplicated; the caller keeps
    ///     ownership of the descriptor it passed in.
    ///   - label: Stream name recorded in log metadata (`stdout`/`stderr`).
    ///   - limit: How many trailing bytes to retain for diagnostics.
    init?(fileDescriptor: Int32, label: String, logger: Logger, limit: Int = 8192) {
        let owned = dup(fileDescriptor)
        guard owned >= 0 else { return nil }
        self.fd = owned
        self.label = label
        self.logger = logger
        self.limit = limit

        // Non-blocking: the source only guarantees *some* data is ready, and a
        // blocking read after a spurious wakeup would park the queue's thread.
        let flags = fcntl(owned, F_GETFL)
        if flags >= 0 { _ = fcntl(owned, F_SETFL, flags | O_NONBLOCK) }

        let source = DispatchSource.makeReadSource(fileDescriptor: owned, queue: .global())
        source.setEventHandler { [weak self] in self?.readAvailable() }
        // The descriptor is closed here and nowhere else, once GCD guarantees
        // the source will not fire again.
        source.setCancelHandler { _ = close(owned) }
        self.source = source
        source.resume()
    }

    deinit {
        stop()
    }

    /// Stops draining and releases the descriptor. Idempotent.
    func stop() {
        lock.lock()
        let source = self.source
        self.source = nil
        lock.unlock()
        source?.cancel()
    }

    /// The most recent output, for error reporting.
    func recentText() -> String {
        lock.lock()
        let data = recent
        lock.unlock()
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { ptr in
                read(fd, ptr.baseAddress, 4096)
            }
            if count < 0 {
                if errno == EINTR { continue }
                // EAGAIN just means we drained everything currently buffered.
                if errno != EAGAIN && errno != EWOULDBLOCK { stop() }
                return
            }
            if count == 0 {
                stop()  // EOF — the child closed its end.
                return
            }
            append(Array(buffer.prefix(count)))
        }
    }

    private func append(_ bytes: [UInt8]) {
        var lines: [String] = []
        lock.lock()
        recent.append(contentsOf: bytes)
        if recent.count > limit {
            recent.removeFirst(recent.count - limit)
        }
        // Split off complete lines so VMM output reaches the agent's log rather
        // than vanishing into the ring buffer.
        partialLine.append(contentsOf: bytes)
        while let newline = partialLine.firstIndex(of: 0x0A) {
            let line = String(decoding: partialLine[..<newline], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            partialLine.removeSubrange(...newline)
            if !line.isEmpty { lines.append(line) }
        }
        // Cap the partial line so a child emitting no newlines can't grow it
        // without bound.
        if partialLine.count > limit {
            partialLine.removeFirst(partialLine.count - limit)
        }
        lock.unlock()

        for line in lines {
            // `stream` stays in metadata rather than being interpolated into
            // the message, so log backends can still group by message.
            logger.debug("Firecracker process output", metadata: ["stream": "\(label)", "line": "\(line)"])
        }
    }
}
