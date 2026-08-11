#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Foundation
import Logging
import Synchronization

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
    private let identityMinter: GuestIdentityMinter
    private let logger: Logger

    public init(
        ipBinaryPath: String, agentBinaryPath: String = MetadataServerProcessSpawner.currentBinaryPath(),
        logLevel: String, hopLimit: Int, identityMinter: GuestIdentityMinter, logger: Logger
    ) {
        self.ipBinaryPath = ipBinaryPath
        self.agentBinaryPath = agentBinaryPath
        self.logLevel = logLevel
        self.hopLimit = hopLimit
        self.identityMinter = identityMinter
        self.logger = logger
    }

    public func namespaceExists(networkId: UUID) -> Bool {
        // The same probe `ObservedChassisServicePort.namespacePresent` uses, and for
        // the same reason: `/var/run/netns` is tmpfs, so the namespace and the
        // OVS row it belongs to have different lifetimes.
        FileManager.default.fileExists(atPath: ChassisServicePlan.netnsPath(networkId: networkId))
    }

    public func existingNamespaces() -> [UUID] {
        let names =
            (try? FileManager.default.contentsOfDirectory(atPath: ChassisServicePlan.netnsDirectory)) ?? []
        return names.compactMap(ChassisServicePlan.networkId(fromNetnsName:))
            .sorted { $0.uuidString < $1.uuidString }
    }

    public func spawn(networkId: UUID) throws -> any MetadataServerHandle {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ipBinaryPath)
        process.arguments = [
            "netns", "exec", ChassisServicePlan.netnsName(networkId: networkId),
            agentBinaryPath, "metadata-server",
            "--network-id", networkId.uuidString,
            "--hop-limit", String(hopLimit),
            "--log-level", logLevel,
        ]

        let input = Pipe()
        let requests = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = requests
        process.standardError = errors

        try process.run()
        return MetadataServerProcessHandle(
            process: process, input: input, requests: requests, errors: errors,
            networkId: networkId, identityMinter: identityMinter, logger: logger)
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
struct MetadataServerProcessIO: Sendable {
    let isRunning: @Sendable () -> Bool
    let write: @Sendable (Data) throws -> Void
    let terminateProcess: @Sendable () -> Void
    let forceTerminateProcess: @Sendable () -> Void
    let closeInput: @Sendable () -> Void

    private final class LiveResourceBox: Sendable {
        let process: Mutex<Process>
        let input: Mutex<FileHandle>

        init(process: Process, input: FileHandle) {
            self.process = Mutex(process)
            self.input = Mutex(input)
        }
    }

    static func live(process: Process, input: Pipe) -> MetadataServerProcessIO {
        let resources = LiveResourceBox(
            process: process, input: input.fileHandleForWriting)
        return MetadataServerProcessIO(
            // Process observation must not wait behind a pipe write that can
            // block on a wedged child. Pipe closure is still serialized behind
            // writes by MetadataServerProcessHandle's private queue.
            isRunning: { resources.process.withLock { $0.isRunning } },
            write: { data in
                try resources.input.withLock { input in
                    try input.write(contentsOf: data)
                }
            },
            terminateProcess: {
                resources.process.withLock { process in
                    if process.isRunning { process.terminate() }
                }
            },
            forceTerminateProcess: {
                resources.process.withLock { process in
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            },
            closeInput: {
                resources.input.withLock { try? $0.close() }
            }
        )
    }
}

private enum MetadataServerProcessLifecycleError: Error {
    case terminated
}

final class MetadataServerProcessHandle: MetadataServerHandle, Sendable {
    private struct State {
        var pending: MetadataSnapshot?
        var pendingIdentityResponses: [MetadataIdentityResponse] = []
        var draining = false
        var failure: (any Error)?
        var terminated = false
    }

    private let io: MetadataServerProcessIO
    private let networkId: UUID
    private let logger: Logger
    private let terminationGrace: Duration

    /// Writes happen here, never on the caller's thread.
    ///
    /// A pipe write blocks once the buffer fills, and a snapshot can be far
    /// larger than a pipe buffer — so pushing inline would let a wedged child
    /// stall the agent's whole reconcile. That is the one failure this design
    /// exists to avoid, so the write is queued and the caller is never blocked
    /// by it.
    private let queue: DispatchQueue
    private let state = Mutex(State())

    convenience init(
        process: Process, input: Pipe, requests: Pipe, errors: Pipe, networkId: UUID,
        identityMinter: GuestIdentityMinter, logger: Logger
    ) {
        self.init(
            io: .live(process: process, input: input), errors: errors,
            networkId: networkId, logger: logger)
        receiveIdentityRequests(requests, minter: identityMinter)
    }

    init(
        io: MetadataServerProcessIO, errors: Pipe? = nil,
        networkId: UUID, logger: Logger,
        terminationGrace: Duration = ProcessRunner.signalEscalationGrace
    ) {
        self.io = io
        self.networkId = networkId
        self.logger = logger
        self.terminationGrace = terminationGrace
        self.queue = DispatchQueue(label: "strato.metadata-listener.\(networkId.uuidString)")
        if let errors { relay(errors) }
    }

    var isRunning: Bool {
        let terminated = state.withLock(\.terminated)
        return !terminated && io.isRunning()
    }

    func push(_ snapshot: MetadataSnapshot) throws {
        let result = try state.withLock { state -> (previous: (any Error)?, shouldDrain: Bool) in
            guard !state.terminated else { throw MetadataServerProcessLifecycleError.terminated }
            // Reported one push late, deliberately: the write it describes
            // happened after the previous call returned.
            let previous = state.failure
            state.failure = nil
            state.pending = snapshot
            let shouldDrain = !state.draining
            state.draining = true
            return (previous, shouldDrain)
        }

        if result.shouldDrain { queue.async { self.drain() } }
        if let previous = result.previous { throw previous }
    }

    func terminate() {
        let shouldTerminate = state.withLock { state -> Bool in
            guard !state.terminated else { return false }
            state.terminated = true
            state.pending = nil
            state.pendingIdentityResponses = []
            return true
        }
        guard shouldTerminate else { return }

        // Process termination must not queue behind a pipe write: a child that
        // stopped reading can block that write forever. FileHandle closure
        // remains queued after the write so those operations never overlap.
        io.terminateProcess()

        let escalationIO = io
        let grace = terminationGrace
        let logger = logger
        let networkId = networkId
        Task {
            try? await Task.sleep(for: grace)
            guard escalationIO.isRunning() else { return }
            logger.warning(
                "Metadata listener ignored SIGTERM; escalating to SIGKILL",
                metadata: ["networkId": .string(networkId.uuidString)])
            escalationIO.forceTerminateProcess()
        }

        queue.async { self.io.closeInput() }
    }

    private func drain() {
        while true {
            let message = state.withLock { state -> MetadataParentMessage? in
                guard !state.terminated else {
                    state.draining = false
                    return nil
                }
                // Policy and placement snapshots outrank credential replies so
                // a busy guest cannot delay a revocation behind mint traffic.
                if let snapshot = state.pending {
                    state.pending = nil
                    return .snapshot(snapshot)
                }
                if !state.pendingIdentityResponses.isEmpty {
                    return .identityResponse(state.pendingIdentityResponses.removeFirst())
                }
                state.draining = false
                return nil
            }
            guard let message else { return }

            do {
                try io.write(MetadataControlProtocol.encode(message))
            } catch {
                state.withLock { state in
                    if !state.terminated { state.failure = error }
                    state.draining = false
                }
                return
            }
        }
    }

    private func enqueue(_ response: MetadataIdentityResponse) {
        let shouldDrain = state.withLock { state -> Bool in
            guard !state.terminated else { return false }
            state.pendingIdentityResponses.append(response)
            let shouldDrain = !state.draining
            state.draining = true
            return shouldDrain
        }
        if shouldDrain { queue.async { self.drain() } }
    }

    private func receiveIdentityRequests(_ requests: Pipe, minter: GuestIdentityMinter) {
        let reader = MetadataChildRequestReader()
        requests.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let decoded: [MetadataIdentityRequest]
            do {
                decoded = try reader.append(data)
            } catch {
                self?.logger.warning(
                    "Metadata listener sent an unreadable identity request",
                    metadata: ["error": .string("\(error)")])
                return
            }
            for request in decoded {
                Task { [weak self] in
                    let svid = try? await minter.mint(
                        vmId: request.vmId, audience: request.audience,
                        ttlSeconds: request.ttlSeconds)
                    self?.enqueue(MetadataIdentityResponse(requestId: request.requestId, svid: svid))
                }
            }
        }
    }

    /// The child logs to stderr; the parent republishes it so one agent log
    /// carries both halves.
    ///
    /// Each line arrives tagged `<level>\t<message>` (see the child's log
    /// handler) and is re-emitted at that level. Relaying everything at one
    /// level instead would both misreport a child's warning as routine and
    /// print the level twice — once as the parent's, once inside the message.
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
                let (level, message) = MetadataServerProcessHandle.split(line: String(line))
                logger.log(
                    level: level, "\(message)",
                    metadata: ["source": .string("metadata-listener"), "networkId": .string(networkId.uuidString)])
            }
        }
    }

    /// Splits a child log line into its level and its message. A line without a
    /// recognizable tag is relayed whole at `info` rather than dropped — it is
    /// most likely something the runtime wrote straight to stderr, which is
    /// exactly the output worth keeping.
    static func split(line: String) -> (Logger.Level, String) {
        guard let tab = line.firstIndex(of: "\t"),
            let level = Logger.Level(rawValue: String(line[line.startIndex..<tab]))
        else {
            return (.info, line)
        }
        return (level, String(line[line.index(after: tab)...]))
    }
}

/// Mutable frame reassembly behind a lock because `FileHandle` owns the queue
/// on which its readability callback runs.
private final class MetadataChildRequestReader: Sendable {
    private let reader = Mutex(MetadataFrameReader())

    func append(_ data: Data) throws -> [MetadataIdentityRequest] {
        try reader.withLock { reader in
            try reader.append(data).map {
                try JSONDecoder().decode(MetadataIdentityRequest.self, from: $0)
            }
        }
    }
}
