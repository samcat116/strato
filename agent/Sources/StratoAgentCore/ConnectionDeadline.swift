import Foundation
import Synchronization

/// A connection deadline must interrupt the transport, not just cancel a
/// waiter on a library-owned task. All interruption finishes before a retry.
public enum ConnectionDeadline {
    public struct Exceeded: Error, Sendable {}

    public static func run(
        timeout: Duration,
        connect: @escaping @Sendable () async throws -> Void,
        interrupt: @escaping @Sendable () async -> Void
    ) async throws {
        let cleanup = Cleanup(interrupt: interrupt)
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await withTaskCancellationHandler {
                        try Task.checkCancellation()
                        try await connect()
                        try Task.checkCancellation()
                    } onCancel: {
                        cleanup.start()
                    }
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw Exceeded()
                }
                defer { group.cancelAll() }
                try await group.next()
            }
            try Task.checkCancellation()
        } catch {
            await cleanup.start().value
            throw error
        }
    }

    private final class Cleanup: Sendable {
        let task = Mutex<Task<Void, Never>?>(nil)
        let interrupt: @Sendable () async -> Void

        init(interrupt: @escaping @Sendable () async -> Void) {
            self.interrupt = interrupt
        }

        @discardableResult
        func start() -> Task<Void, Never> {
            task.withLock { task in
                if let task { return task }
                let work = Task { await interrupt() }
                task = work
                return work
            }
        }
    }
}
