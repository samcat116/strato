#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Dispatch
import Foundation
import Synchronization

/// Traps process termination signals (SIGINT/SIGTERM by default) and runs a
/// graceful-shutdown closure exactly once when the first such signal arrives.
///
/// Backed by `DispatchSource` signal sources, which are available on both macOS
/// and Linux. Each trapped signal's default disposition is set to `SIG_IGN`
/// first, so the kernel doesn't terminate the process before the dispatch
/// source can observe the signal.
///
final class SignalHandler: Sendable {
    private struct State {
        var installed = false
        var sources: [DispatchSourceSignal] = []
        var hasFired = false
    }

    private let queue = DispatchQueue(label: "com.strato.agent.signal-handler")
    private let state = Mutex(State())
    private let handler: @Sendable (Int32) -> Void

    /// - Parameter handler: Invoked with the signal number the first time any
    ///   trapped signal is received. Later signals are ignored so shutdown runs
    ///   once even if the operator sends a second Ctrl-C.
    init(handler: @escaping @Sendable (Int32) -> Void) {
        self.handler = handler
    }

    /// Begins trapping the given signals (SIGINT and SIGTERM by default).
    func install(signals: [Int32] = [SIGINT, SIGTERM]) {
        let shouldInstall = state.withLock { state -> Bool in
            guard !state.installed else { return false }
            state.installed = true
            return true
        }
        guard shouldInstall else { return }

        state.withLock { state in
            for sig in signals {
                // Ignore the default action so the dispatch source can observe it
                // instead of the process being terminated immediately.
                signal(sig, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
                source.setEventHandler { [weak self] in
                    self?.fire(signal: sig)
                }
                state.sources.append(source)
            }
            state.sources.forEach { $0.resume() }
        }
    }

    private func fire(signal: Int32) {
        let shouldFire = state.withLock { state -> Bool in
            guard !state.hasFired else { return false }
            state.hasFired = true
            return true
        }
        if shouldFire { handler(signal) }
    }
}
