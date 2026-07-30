import Dispatch
import Foundation
import Logging

#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// A one-shot latch bridging `Process.terminationHandler` into async/await.
///
/// `Process.waitUntilExit()` blocks the calling thread — inside an actor that
/// means the actor is held for the whole teardown and every other VM's
/// operations queue behind it. This latch lets the wait suspend instead.
///
/// Safe against every ordering: the handler may fire before, during, or after
/// `wait()` suspends.
final class ExitLatch: @unchecked Sendable {
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

    var isSignaled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return signaled
    }

    /// Suspends until the child exits. Deliberately not cancellation-aware:
    /// `terminationStatus` is only valid once the handler has fired, so
    /// returning early would let a cancelled caller read a bogus status.
    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if signaled {
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    /// Bounded wait, for teardown paths that must not hang if the handler never
    /// fires (on Linux a grandchild that inherited the exit descriptor can hold
    /// it hostage). Polls rather than registering a second continuation, since
    /// the latch holds exactly one waiter.
    func wait(upTo budget: Duration) async -> Bool {
        let deadline = ContinuousClock.now + budget
        while ContinuousClock.now < deadline {
            if isSignaled { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return isSignaled
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
final class OutputDrain: @unchecked Sendable {
    private let lock = NSLock()
    private var recent = Data()
    private var partialLine = Data()
    private let limit: Int
    private let label: String
    private let logger: Logger
    private let handle: FileHandle
    private var source: DispatchSourceRead?

    /// - Parameters:
    ///   - handle: The pipe's read end. Retained for the drain's lifetime so
    ///     the child never writes into a closed pipe.
    ///   - label: Stream name used in log metadata (`stdout`/`stderr`).
    ///   - limit: How many trailing bytes to retain for diagnostics.
    init(handle: FileHandle, label: String, logger: Logger, limit: Int = 8192) {
        self.handle = handle
        self.label = label
        self.logger = logger
        self.limit = limit

        let fd = handle.fileDescriptor
        // Non-blocking: the source only guarantees *some* data is ready, and a
        // blocking read after a spurious wakeup would park the queue's thread.
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        source.setEventHandler { [weak self] in self?.readAvailable(fd: fd) }
        self.source = source
        source.resume()
    }

    deinit {
        source?.cancel()
    }

    /// Stops draining. Idempotent.
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

    private func readAvailable(fd: Int32) {
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
                // EOF — the child closed its end.
                stop()
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
            logger.debug("firecracker \(label)", metadata: ["line": "\(line)"])
        }
    }
}
