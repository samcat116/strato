#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Dispatch
import Foundation

/// Traps process termination signals (SIGINT/SIGTERM by default) and runs a
/// graceful-shutdown closure exactly once when the first such signal arrives.
///
/// Backed by `DispatchSource` signal sources, which are available on both macOS
/// and Linux. Each trapped signal's default disposition is set to `SIG_IGN`
/// first, so the kernel doesn't terminate the process before the dispatch
/// source can observe the signal.
///
/// `@unchecked Sendable`: mutable state is confined to the private serial
/// `queue`. `install()` populates `sources` once, before any signal can fire,
/// and `hasFired` is only ever touched from `fire(signal:)`, which runs on that
/// queue.
final class SignalHandler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.strato.agent.signal-handler")
    private var sources: [DispatchSourceSignal] = []
    private var hasFired = false
    private let handler: @Sendable (Int32) -> Void

    /// - Parameter handler: Invoked with the signal number the first time any
    ///   trapped signal is received. Later signals are ignored so shutdown runs
    ///   once even if the operator sends a second Ctrl-C.
    init(handler: @escaping @Sendable (Int32) -> Void) {
        self.handler = handler
    }

    /// Begins trapping the given signals (SIGINT and SIGTERM by default).
    func install(signals: [Int32] = [SIGINT, SIGTERM]) {
        for sig in signals {
            // Ignore the default action so the dispatch source can observe it
            // instead of the process being terminated immediately.
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler { [weak self] in
                self?.fire(signal: sig)
            }
            source.resume()
            sources.append(source)
        }
    }

    // Runs on `queue`, so access to `hasFired` is serialized.
    private func fire(signal: Int32) {
        guard !hasFired else { return }
        hasFired = true
        handler(signal)
    }
}
