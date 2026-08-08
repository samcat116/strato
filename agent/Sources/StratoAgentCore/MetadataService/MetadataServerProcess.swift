import Foundation
import Logging

/// Starts metadata listeners as child processes of the agent, one per network
/// namespace (STR-56).
///
/// The child is this same binary under its `metadata-server` subcommand, run
/// through `ip netns exec` so it is already inside `strato-md-<network>` and can
/// bind the metadata addresses with no `setns(2)` of its own. One binary rather
/// than two keeps the agent updater's job unchanged: it replaces one file.
public struct MetadataServerProcessSpawner: MetadataServerSpawning {
    private let ipBinaryPath: String
    private let agentBinaryPath: String
    private let logLevel: String
    private let hopLimit: Int
    private let logger: Logger

    public init(
        ipBinaryPath: String, agentBinaryPath: String = MetadataServerProcessSpawner.currentBinaryPath(),
        logLevel: String, hopLimit: Int, logger: Logger
    ) {
        self.ipBinaryPath = ipBinaryPath
        self.agentBinaryPath = agentBinaryPath
        self.logLevel = logLevel
        self.hopLimit = hopLimit
        self.logger = logger
    }

    public func namespaceExists(networkId: UUID) -> Bool {
        // The same probe `ObservedMetadataPort.namespacePresent` uses, and for
        // the same reason: `/var/run/netns` is tmpfs, so the namespace and the
        // OVS row it belongs to have different lifetimes.
        FileManager.default.fileExists(atPath: MetadataChassisPlan.netnsPath(networkId: networkId))
    }

    public func spawn(networkId: UUID) throws -> any MetadataServerHandle {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ipBinaryPath)
        process.arguments = [
            "netns", "exec", MetadataChassisPlan.netnsName(networkId: networkId),
            agentBinaryPath, "metadata-server",
            "--network-id", networkId.uuidString,
            "--hop-limit", String(hopLimit),
            "--log-level", logLevel,
        ]

        let input = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors

        try process.run()
        return MetadataServerProcessHandle(
            process: process, input: input, errors: errors, networkId: networkId, logger: logger)
    }

    /// This binary's own path, so a child is always the same build as its
    /// parent — an agent updated in place must not keep starting listeners from
    /// the version it replaced.
    public static func currentBinaryPath() -> String {
        #if os(Linux)
        if let resolved = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe") {
            return resolved
        }
        #endif
        return CommandLine.arguments.first ?? "strato-agent"
    }
}

/// One running listener child.
final class MetadataServerProcessHandle: MetadataServerHandle, @unchecked Sendable {
    private let process: Process
    private let input: Pipe
    private let networkId: UUID
    private let logger: Logger

    /// Writes happen here, never on the caller's thread.
    ///
    /// A pipe write blocks once the buffer fills, and a snapshot can be far
    /// larger than a pipe buffer — so pushing inline would let a wedged child
    /// stall the agent's whole reconcile. That is the one failure this design
    /// exists to avoid, so the write is queued and the caller is never blocked
    /// by it.
    private let queue: DispatchQueue
    private let state = NSLock()
    /// Only the newest snapshot is worth writing: the channel is level-triggered
    /// like everything else, so a backlog is just an older version of what is
    /// pending.
    private var pending: MetadataSnapshot?
    private var draining = false
    private var failure: (any Error)?

    init(process: Process, input: Pipe, errors: Pipe, networkId: UUID, logger: Logger) {
        self.process = process
        self.input = input
        self.networkId = networkId
        self.logger = logger
        self.queue = DispatchQueue(label: "strato.metadata-listener.\(networkId.uuidString)")
        relay(errors)
    }

    var isRunning: Bool { process.isRunning }

    func push(_ snapshot: MetadataSnapshot) throws {
        state.lock()
        // Reported one push late, deliberately: the write it describes happened
        // on the queue after the previous call returned, and there is nowhere
        // else to surface it. The supervisor reaps the child on the next sync.
        let previous = failure
        failure = nil
        pending = snapshot
        let alreadyDraining = draining
        draining = true
        state.unlock()

        if let previous { throw previous }
        guard !alreadyDraining else { return }
        queue.async { [weak self] in self?.drain() }
    }

    func terminate() {
        // Closing stdin is the graceful exit — the child stops on EOF — and the
        // terminate covers a child that is wedged somewhere else.
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    private func drain() {
        while true {
            state.lock()
            guard let snapshot = pending else {
                draining = false
                state.unlock()
                return
            }
            pending = nil
            state.unlock()

            do {
                try input.fileHandleForWriting.write(contentsOf: MetadataControlProtocol.encode(snapshot))
            } catch {
                state.lock()
                failure = error
                draining = false
                state.unlock()
                return
            }
        }
    }

    /// The child logs to stderr; the parent republishes it so one agent log
    /// carries both halves.
    private func relay(_ errors: Pipe) {
        let logger = self.logger
        let networkId = self.networkId
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where !line.isEmpty {
                logger.info(
                    "\(line)",
                    metadata: ["source": .string("metadata-listener"), "networkId": .string(networkId.uuidString)])
            }
        }
    }
}
