#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import ArgumentParser
import Foundation
import Logging
import StratoAgentSPIFFE
import Synchronization

extension StratoAgent {
    /// Node-side diagnostic for guest identity: ask the local spire-agent, over
    /// its Delegated Identity API, for the SVID of a workload it cannot attest
    /// directly.
    ///
    /// The point of the command is that a passing run is evidence for a design
    /// claim, not just a green check: the SPIFFE ID it prints belongs to a guest
    /// VM or sandbox, and no workload attestor on this host could ever have
    /// produced it. See `docs/architecture/guest-identity.md`.
    struct SpiffeDelegatedProbe: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "spiffe-delegated-probe",
            abstract:
                "Verify that this node's SPIRE agent will issue a guest SVID to strato-agent as a delegate",
            discussion: """
                Requires the local spire-agent to have `admin_socket_path` set and this \
                agent's SPIFFE ID listed in `authorized_delegates`, and a registration \
                entry carrying the given selectors parented to this node's SPIFFE ID.

                Example:
                  strato-agent spiffe-delegated-probe \\
                    --selector strato:instance:11111111-1111-1111-1111-111111111111 \\
                    --selector strato:kind:vm
                """
        )

        @Option(
            name: .long,
            help:
                "SPIRE agent admin socket (default: $SPIRE_ADMIN_ENDPOINT_SOCKET, then /var/run/spire/admin.sock)"
        )
        var adminSocket: String?

        @Option(
            name: .long, parsing: .singleValue,
            help: "Selector as type:value. Repeat for each; at least one is required.")
        var selector: [String] = []

        @Flag(name: .long, help: "Stay on the stream and print every update, including revocation")
        var watch: Bool = false

        @Option(name: .long, help: "Seconds to wait for the first stream message")
        var timeout: Int = 10

        @Flag(name: .long, help: "Emit JSON instead of the human-readable report")
        var json: Bool = false

        func run() async throws {
            // A bare `LoggingSystem.bootstrap` rather than `launchAgent`'s: this
            // command must not install signal handlers or read agent config.
            let baseLoggingMetadata = AgentLoggingMetadata.base()
            LoggingSystem.bootstrap { label in
                var handler = StreamLogHandler.standardError(label: label)
                handler.logLevel = .warning
                handler.metadata = baseLoggingMetadata
                return handler
            }

            guard !selector.isEmpty else {
                throw ValidationError("At least one --selector is required.")
            }
            let selectors = try selector.map { text -> DelegatedSelector in
                guard let parsed = DelegatedSelector(text) else {
                    throw ValidationError("Invalid selector '\(text)'. Expected type:value.")
                }
                return parsed
            }

            let socketPath = DelegatedIdentitySPIFFEClient.resolveSocketPath(override: adminSocket)
            let client = DelegatedIdentitySPIFFEClient(
                socketPath: socketPath,
                logger: Logger(label: "spiffe-delegated-probe")
            )

            if watch {
                await runWatch(client: client, selectors: selectors, socketPath: socketPath)
                // Only reachable if the stream finished on its own (a refused
                // delegate stops rather than retrying forever).
                exitImmediately(1)
            }

            let report = await withTimeout(seconds: timeout) {
                await DelegatedIdentityProbe.probe(client: client, selectors: selectors)
            } orElse: {
                DelegatedIdentityProbe.Report(
                    socketPath: socketPath,
                    socketPresent: FileManager.default.fileExists(atPath: socketPath),
                    selectors: selectors.map(\.description),
                    outcome: .timedOut,
                    detail: "timed out after \(timeout)s waiting for the first stream message"
                )
            }

            print(json ? try DelegatedIdentityProbe.formatJSON(report) : DelegatedIdentityProbe.format(report))

            // Never `return`: this command built an `HTTP2ClientTransport.Posix`,
            // which spins up NIO event-loop threads, and returning normally from
            // an async ArgumentParser command is exactly the path that hangs
            // instead of exiting (issue #522, see `exitImmediately`).
            exitImmediately(report.succeeded ? 0 : 1)
        }

        private func runWatch(
            client: DelegatedIdentitySPIFFEClient,
            selectors: [DelegatedSelector],
            socketPath: String
        ) async {
            print("Watching \(socketPath) for \(selectors.map(\.description).joined(separator: " "))")
            print("An empty update means the registration entry was deleted. Ctrl-C to stop.\n")

            for await svids in client.watchX509SVIDs(selectors: selectors) {
                let report = DelegatedIdentityProbe.Report(
                    socketPath: socketPath,
                    socketPresent: FileManager.default.fileExists(atPath: socketPath),
                    selectors: selectors.map(\.description),
                    identities: svids.map(DelegatedIdentityProbe.makeIdentityReport),
                    outcome: svids.isEmpty ? .noEntryMatched : .ok
                )
                if json {
                    print((try? DelegatedIdentityProbe.formatJSON(report)) ?? "{}")
                } else {
                    print(DelegatedIdentityProbe.format(report))
                    print("")
                }
                // Watch output is usually redirected to a file while someone
                // deletes an entry in another shell; block buffering would hide
                // the revocation update until the process is killed, which is
                // the one moment this mode exists to show.
                fflush(nil)
            }
        }

        /// Run `work`, returning `fallback()` if it has not finished within
        /// `seconds`. The probe never throws, so neither does this.
        ///
        /// Deliberately *not* a task group: a group awaits its remaining
        /// children when the body returns, so `cancelAll()` followed by `return`
        /// still blocks until the probe task observes cancellation — which makes
        /// `--timeout` a hint rather than a bound, and defeats it in exactly the
        /// case it exists for, a socket that accepts the connection and then
        /// wedges. Racing two detached tasks through one continuation gives a
        /// real deadline; the loser is abandoned rather than awaited, which is
        /// sound here because the caller prints the report and `_exit`s.
        private func withTimeout<Result: Sendable>(
            seconds: Int,
            _ work: @escaping @Sendable () async -> Result,
            orElse fallback: @escaping @Sendable () -> Result
        ) async -> Result {
            // Holds the continuation until someone claims it, so whichever task
            // finishes first resumes exactly once and the other becomes a no-op.
            let pending = Mutex<CheckedContinuation<Result, Never>?>(nil)

            return await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
                pending.withLock { $0 = continuation }

                let resume: @Sendable (Result) -> Void = { value in
                    let claimed = pending.withLock { held -> CheckedContinuation<Result, Never>? in
                        defer { held = nil }
                        return held
                    }
                    claimed?.resume(returning: value)
                }

                Task.detached { resume(await work()) }
                Task.detached {
                    try? await Task.sleep(for: .seconds(seconds))
                    resume(fallback())
                }
            }
        }
    }
}
