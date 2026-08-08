import ArgumentParser
import Foundation
import Logging
import NIOPosix
import StratoAgentCore
import StratoShared

extension StratoAgent {
    /// The guest-facing instance metadata listener for one network (STR-56).
    ///
    /// Not something an operator runs. The agent starts one of these per network
    /// it hosts a metadata-enabled NIC on, through
    /// `ip netns exec strato-md-<network> strato-agent metadata-server ...`, so
    /// the process is already inside the namespace ADR 0003 puts each network's
    /// metadata interface in and binds `169.254.169.254` / `[fd00:ec2::254]`
    /// normally.
    ///
    /// It serves entirely from what its parent pushes down stdin, and exits when
    /// that stream ends — so a dead agent leaves no orphan answering guests with
    /// nobody supervising it.
    struct MetadataServer: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "metadata-server",
            abstract: "Serve instance metadata inside one network's namespace (started by the agent)",
            discussion: """
                Started by strato-agent, not by hand: it expects to be inside the network's \
                metadata namespace and to receive its payload on stdin.
                """,
            shouldDisplay: false
        )

        @Option(name: .long, help: "The logical network this namespace belongs to")
        var networkId: String

        @Option(name: .long, help: "IP TTL / hop limit applied to responses")
        var hopLimit: Int = 1

        @Option(name: .long, help: "Log level")
        var logLevel: String = "info"

        func run() async throws {
            guard let network = UUID(uuidString: networkId) else {
                throw ValidationError("--network-id must be a UUID")
            }
            // Straight to stderr, which the parent relays into its own log: this
            // process reads no config and installs no signal handlers.
            //
            // A tab-tagged handler rather than `StreamLogHandler`, so the parent
            // can re-emit each line at the level the child chose instead of
            // flattening everything to one level and printing the level twice.
            let level = Logger.Level(rawValue: logLevel) ?? .info
            LoggingSystem.bootstrap { _ in
                var handler = MetadataListenerLogHandler()
                handler.logLevel = level
                return handler
            }
            var logger = Logger(label: "strato-metadata")
            logger.logLevel = level

            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

            // Cold until the first push: a listener that has been told nothing
            // answers 503, never a confident 404 (see `MetadataSnapshotOrigin`).
            let responder = MetadataResponder(snapshot: .cold(networkId: network), logger: logger)
            let server = MetadataHTTPServer(
                group: group, responder: responder, hopLimit: hopLimit, logger: logger)

            do {
                try await bind(server: server, logger: logger)
            } catch {
                try? await group.shutdownGracefully()
                throw error
            }
            await serve(pushesTo: server, logger: logger)
            await server.shutdown()
            try? await group.shutdownGracefully()
        }

        /// Binds both families, tolerating a v6 that never appears.
        ///
        /// Retried rather than attempted once, because the namespace and its
        /// addresses are established by separate commands: the agent starts this
        /// process as soon as the namespace exists, which can be a moment before
        /// the addresses are on the interface. Without the retry that race would
        /// cost a whole sync interval of metadata for a booting guest.
        ///
        /// The two families are independent for the reason `MetadataChassisPlan`
        /// gives: on a host without IPv6 the v6 half simply never works, and the
        /// v4 metadata service must not be held hostage to it.
        private func bind(server: MetadataHTTPServer, logger: Logger) async throws {
            // Raced rather than sequenced. Attempting v4's full retry budget
            // first would delay the v6 listener by up to half a minute on a host
            // where v4 never binds — with the parent seeing a perfectly healthy
            // child throughout — which contradicts the independence the comment
            // above claims.
            async let ipv4 = attemptBind(
                server: server, address: InstanceMetadataEndpoint.address, attempts: 30, logger: logger)
            async let ipv6 = attemptBind(
                server: server, address: InstanceMetadataEndpoint.addressV6, attempts: 30, logger: logger)
            let (v4, v6) = await (ipv4, ipv6)
            guard v4 || v6 else {
                // Exiting non-zero is the honest report: the parent sees the
                // child gone and retries on the next sync, rather than a
                // process that is up and answers nothing.
                throw MetadataServerError.couldNotBind
            }
        }

        private func attemptBind(
            server: MetadataHTTPServer, address: String, attempts: Int, logger: Logger
        ) async -> Bool {
            for attempt in 1...attempts {
                do {
                    try await server.listen(address: address, port: InstanceMetadataEndpoint.port)
                    return true
                } catch {
                    if attempt == attempts {
                        logger.warning(
                            "Could not bind the metadata address",
                            metadata: ["address": .string(address), "error": .string("\(error)")])
                        return false
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            return false
        }

        /// Reads snapshot frames until stdin closes.
        private func serve(pushesTo server: MetadataHTTPServer, logger: Logger) async {
            var reader = MetadataFrameReader()
            let decoder = JSONDecoder()

            for await chunk in Self.standardInputChunks() {
                let frames: [Data]
                do {
                    frames = try reader.append(chunk)
                } catch {
                    // A desynchronized control stream cannot be resynchronized,
                    // and continuing to serve from a payload that may be half a
                    // frame old is worse than stopping.
                    logger.error("Metadata control stream is unreadable", metadata: ["error": .string("\(error)")])
                    return
                }
                for frame in frames {
                    do {
                        let snapshot = try decoder.decode(MetadataSnapshot.self, from: frame)
                        await server.update(snapshot)
                        logger.debug(
                            "Adopted a metadata snapshot",
                            metadata: [
                                "instances": .stringConvertible(snapshot.instances.count),
                                "origin": .string(snapshot.origin.rawValue),
                            ])
                    } catch {
                        // One unreadable frame is survivable: the channel is
                        // level-triggered, so the next push is a full
                        // replacement and this listener keeps serving what it
                        // has until then.
                        logger.error(
                            "Ignoring an unreadable metadata snapshot", metadata: ["error": .string("\(error)")])
                    }
                }
            }
            logger.info("Metadata control stream closed; shutting the listener down")
        }

        /// stdin as an async stream, read on its own thread.
        ///
        /// A dedicated thread rather than the cooperative pool because the read
        /// is blocking and this process spends all of its time in it.
        private static func standardInputChunks() -> AsyncStream<Data> {
            AsyncStream { continuation in
                let thread = Thread {
                    while true {
                        let data = FileHandle.standardInput.availableData
                        if data.isEmpty {
                            continuation.finish()
                            return
                        }
                        continuation.yield(data)
                    }
                }
                thread.name = "strato-metadata-control"
                thread.start()
            }
        }
    }
}

/// Writes `<level>\t<message>` lines to stderr for the parent agent to relay.
///
/// Deliberately minimal: nothing reads this output but the parent, which adds
/// its own timestamp, label and metadata, so anything this handler formatted
/// would be duplicated there.
struct MetadataListenerLogHandler: LogHandler {
    var logLevel: Logger.Level = .info
    var metadata: Logger.Metadata = [:]

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?,
        source: String, file: String, function: String, line: UInt
    ) {
        let merged = self.metadata.merging(metadata ?? [:]) { _, new in new }
        let rendered =
            merged.isEmpty
            ? message.description
            : message.description + " "
                + merged.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        // Newlines would be read by the parent as extra, untagged lines.
        let oneLine = rendered.replacingOccurrences(of: "\n", with: " ")
        FileHandle.standardError.write(Data("\(level.rawValue)\t\(oneLine)\n".utf8))
    }
}

enum MetadataServerError: Error, CustomStringConvertible {
    case couldNotBind

    var description: String {
        switch self {
        case .couldNotBind:
            return "could not bind either metadata address in this namespace"
        }
    }
}
