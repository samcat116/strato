import Foundation

/// Supervises one sandbox's transport with bounded admission and independent
/// deadlines. The transport must close its owned descriptors on `stop`. This
/// type never signals an arbitrary PID or creates a parallel VMM lifecycle.
/// It is not a UFFD transport and cannot enable lazy restore.
public actor SandboxPageServerSupervisor {
    public enum State: Sendable, Equatable { case idle, starting, ready, failed, cancelled }
    public enum Failure: Error, Sendable, Equatable {
        case invalidLimits, notReady, queueFull, deadline, handlerExited, transport, invalidPage, cancelled
    }
    public struct Metrics: Sendable {
        public fileprivate(set) var admitted = 0
        public fileprivate(set) var served = 0
        public fileprivate(set) var highWater = 0
        public fileprivate(set) var failures = 0
        public fileprivate(set) var timeouts = 0
        public fileprivate(set) var queueOverflows = 0
        public fileprivate(set) var bytesServed = 0
        public fileprivate(set) var totalFaultWait = Duration.zero
        public fileprivate(set) var maximumFaultWait = Duration.zero
    }
    public struct Transport: Sendable {
        /// Must validate peer identity, received descriptor and memory layout.
        public let handshake: @Sendable () async throws -> Void
        public let readPage: @Sendable (Int) async throws -> Data
        /// Nonblocking revocation of this transport only. The owning lifecycle
        /// must separately prove handler/VMM exit before reclaiming its lease.
        public let stop: @Sendable (Failure) -> Void
        public init(
            handshake: @escaping @Sendable () async throws -> Void,
            readPage: @escaping @Sendable (Int) async throws -> Data,
            stop: @escaping @Sendable (Failure) -> Void
        ) {
            self.handshake = handshake
            self.readPage = readPage
            self.stop = stop
        }
    }
    private struct Job {
        let page: Int
        let admittedAt: ContinuousClock.Instant
        let continuation: CheckedContinuation<Data, any Error>
        let deadline: Task<Void, Never>
    }
    public private(set) var state = State.idle
    public private(set) var metrics = Metrics()
    private let transport: Transport
    private let capacity: Int
    private let pageCount: Int
    private let faultTimeout: Duration
    private let handshakeTimeout: Duration
    private var pending: [UUID: Job] = [:]
    private var queue: [UUID] = []
    private var worker: Task<Void, Never>?
    private var handshakeWorker: Task<Void, Never>?
    private var handshakeDeadline: Task<Void, Never>?
    private var handshakeResult: CheckedContinuation<Void, any Error>?

    public init(
        transport: Transport, pageCount: Int, capacity: Int = 64,
        faultTimeout: Duration = .seconds(1), handshakeTimeout: Duration = .seconds(5)
    ) throws {
        guard pageCount > 0, capacity > 0, capacity <= 4096,
            faultTimeout > .zero, faultTimeout <= .seconds(60),
            handshakeTimeout > .zero, handshakeTimeout <= .seconds(60)
        else { throw Failure.invalidLimits }
        self.transport = transport
        self.pageCount = pageCount
        self.capacity = capacity
        self.faultTimeout = faultTimeout
        self.handshakeTimeout = handshakeTimeout
    }

    public func start() async throws {
        try Task.checkCancellation()
        guard state == .idle else { throw Failure.notReady }
        state = .starting
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                handshakeResult = continuation
                let transport = self.transport
                handshakeWorker = Task.detached { [weak self] in
                    do {
                        try await transport.handshake()
                        await self?.handshakeFinished(success: true)
                    } catch {
                        await self?.handshakeFinished(success: false)
                    }
                }
                handshakeDeadline = Task { [weak self, handshakeTimeout] in
                    do { try await Task.sleep(for: handshakeTimeout) } catch { return }
                    await self?.fail(.deadline)
                }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    public func request(page: Int) async throws -> Data {
        try Task.checkCancellation()
        guard state == .ready else { throw Failure.notReady }
        guard page >= 0, page < pageCount else {
            fail(.invalidPage)
            throw Failure.invalidPage
        }
        guard pending.count < capacity else {
            fail(.queueFull)
            throw Failure.queueFull
        }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeout = faultTimeout
                let deadline = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    await self?.expired(id)
                }
                pending[id] = Job(
                    page: page, admittedAt: ContinuousClock().now, continuation: continuation, deadline: deadline)
                queue.append(id)
                metrics.admitted += 1
                metrics.highWater = max(metrics.highWater, pending.count)
                runNext()
            }
        } onCancel: {
            // Cancellation invalidates the lease
            // serving later faults from a
            // cancelled guest could replay stale state after a generation change.
            Task { await self.cancel() }
        }
    }

    public func cancel() { terminate(.cancelled, state: .cancelled) }
    public func handlerExited() { fail(.handlerExited) }

    private func handshakeFinished(success: Bool) {
        guard state == .starting else { return }
        guard success else {
            fail(.transport)
            return
        }
        handshakeDeadline?.cancel()
        handshakeDeadline = nil
        handshakeWorker = nil
        state = .ready
        handshakeResult?.resume()
        handshakeResult = nil
    }
    private func runNext() {
        guard state == .ready, worker == nil, !queue.isEmpty else { return }
        let id = queue.removeFirst()
        guard let job = pending[id] else {
            runNext()
            return
        }
        let transport = self.transport
        worker = Task.detached { [weak self] in
            do {
                let data = try await transport.readPage(job.page)
                await self?.completed(id, data: data)
            } catch {
                await self?.failedRequest(id)
            }
        }
    }
    private func completed(_ id: UUID, data: Data) {
        guard state == .ready, let job = pending[id] else { return }
        guard data.count == 4096 else {
            fail(.transport)
            return
        }
        pending.removeValue(forKey: id)
        job.deadline.cancel()
        worker = nil
        metrics.served += 1
        metrics.bytesServed += data.count
        let waited = job.admittedAt.duration(to: ContinuousClock().now)
        metrics.totalFaultWait += waited
        metrics.maximumFaultWait = max(metrics.maximumFaultWait, waited)
        job.continuation.resume(returning: data)
        runNext()
    }
    private func failedRequest(_ id: UUID) {
        guard pending[id] != nil else { return }
        fail(.transport)
    }
    private func expired(_ id: UUID) {
        guard pending[id] != nil else { return }
        fail(.deadline)
    }
    private func fail(_ failure: Failure) { terminate(failure, state: .failed) }
    private func terminate(_ failure: Failure, state target: State) {
        guard state != .failed, state != .cancelled else { return }
        state = target
        metrics.failures += 1
        if failure == .deadline { metrics.timeouts += 1 }
        if failure == .queueFull { metrics.queueOverflows += 1 }
        worker?.cancel()
        worker = nil
        handshakeWorker?.cancel()
        handshakeWorker = nil
        handshakeDeadline?.cancel()
        handshakeDeadline = nil
        handshakeResult?.resume(throwing: failure)
        handshakeResult = nil
        for job in pending.values {
            job.deadline.cancel()
            job.continuation.resume(throwing: failure)
        }
        pending.removeAll()
        queue.removeAll()
        transport.stop(failure)
    }
}
