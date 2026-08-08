import Foundation

/// Serializes tests that mutate a process-wide environment variable.
///
/// `Environment.get` reads the live process environment on every access, so a
/// feature flag driven by one is global mutable state shared by every test in
/// the binary. `.serialized` does **not** make that safe: it orders tests
/// *within* one suite, while swift-testing runs suites in parallel — so a suite
/// asserting flag-*off* behavior can be running while a different suite has the
/// same variable set to `true`. Both directions have to take the gate, not just
/// the one that writes `true`, or the reader is the one that loses.
///
/// An async gate rather than a lock: the body is `async` and must hold the
/// variable for its whole duration, including across the `await`s inside it, and
/// `NSLock` is unavailable from an async context precisely because it cannot
/// survive a suspension safely. A bare `actor` would not do either — actor
/// reentrancy lets a second caller in the moment the first suspends, which is
/// exactly the window this exists to close.
public enum EnvironmentFlag {

    /// One gate for all flags. Distinct variables are rare enough here that
    /// per-variable gates would buy nothing but a chance to deadlock two suites
    /// against each other in opposite orders.
    private static let gate = Gate()

    /// Runs `body` with `name` set to `value` (or unset, when `value` is nil),
    /// restoring whatever was there before and releasing the gate afterwards.
    ///
    /// Use this even to assert the *absence* of a flag — passing `nil` is what
    /// makes an off-path assertion immune to a parallel suite turning it on.
    public static func withValue<T>(
        _ name: String, _ value: String?, _ body: () async throws -> T
    ) async throws -> T {
        await gate.acquire()

        let previous = ProcessInfo.processInfo.environment[name]
        if let value {
            setenv(name, value, 1)
        } else {
            unsetenv(name)
        }

        func restore() async {
            if let previous {
                setenv(name, previous, 1)
            } else {
                unsetenv(name)
            }
            await gate.release()
        }

        do {
            let result = try await body()
            await restore()
            return result
        } catch {
            await restore()
            throw error
        }
    }

    /// A one-holder async semaphore: FIFO, so a suite cannot be starved by a
    /// steady stream of others.
    private actor Gate {
        private var held = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func acquire() async {
            guard held else {
                held = true
                return
            }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            if waiters.isEmpty {
                held = false
            } else {
                waiters.removeFirst().resume()
            }
        }
    }
}
