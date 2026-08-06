#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import ArgumentParser
import Foundation
import Logging
import StratoAgentSPIFFE

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
            LoggingSystem.bootstrap { label in
                var handler = StreamLogHandler.standardError(label: label)
                handler.logLevel = .warning
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
                    outcome: .unavailable,
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

        /// Run `work`, falling back to `fallback` if it has not finished within
        /// `seconds`. The probe never throws, so neither does this.
        private func withTimeout<Result: Sendable>(
            seconds: Int,
            _ work: @escaping @Sendable () async -> Result,
            orElse fallback: @escaping @Sendable () -> Result
        ) async -> Result {
            await withTaskGroup(of: Result?.self) { group in
                group.addTask { await work() }
                group.addTask {
                    try? await Task.sleep(for: .seconds(seconds))
                    return nil
                }
                for await result in group {
                    group.cancelAll()
                    return result ?? fallback()
                }
                return fallback()
            }
        }
    }
}
