import Foundation
import Logging
import StratoShared

/// A raw bidirectional byte channel to a VM's qga unix socket. Abstracted so
/// the client's framing/resync/command logic is unit-testable against an
/// in-memory fake with no real socket (issue #563).
public protocol QGAByteChannel: Sendable {
    /// Write raw bytes to the guest agent socket.
    func write(_ bytes: [UInt8]) async throws
    /// Read the next available inbound bytes. Returns an empty array at EOF.
    /// May return fewer bytes than are ultimately available; callers loop.
    func readSome() async throws -> [UInt8]
    /// Close the channel. Idempotent.
    func close() async
}

/// Opens fresh channels to a VM's qga socket. One transport is bound to one
/// socket path; each probe opens (and closes) its own channel, which suits
/// qga's one-connection-at-a-time chardev and keeps every operation
/// self-contained.
public protocol QGATransport: Sendable {
    func openChannel() async throws -> any QGAByteChannel
}

/// Talks to a single VM's QEMU guest agent over a `QGATransport`.
///
/// Unlike QMP there is no greeting or capability handshake: every operation
/// opens a channel, resynchronizes the stream with `guest-sync-delimited`
/// (which also proves the agent is actually answering), issues its command(s),
/// and closes. qga is **unresponsive whenever the guest is not running the
/// agent**, so callers must bound every method with a `StageBudget` — a timeout
/// is the normal outcome for a qga-less or hung guest, not an exceptional one.
public actor QGAClient {
    public enum QGAError: Error, LocalizedError, Equatable {
        /// The channel reached EOF before a complete reply arrived.
        case connectionClosed
        /// The `guest-sync-delimited` reply carried a token that wasn't ours —
        /// the stream is unusable, so the whole operation is abandoned.
        case syncMismatch
        /// qga answered with an `{"error": ...}` object.
        case commandError(String)
        /// qga rejected the command as one it will not answer — either an agent
        /// too old to know it, or a distro filtering it away with
        /// `--allow-rpcs`/`--block-rpcs`. Distinguished from `commandError`
        /// because it says nothing went wrong with the *request*: this guest
        /// simply cannot do this (issue #803).
        case commandUnavailable(String)
        /// A reply decoded but lacked the expected `return` value.
        case malformedResponse
        /// A reply exceeded the byte budget for the operation. Captured command
        /// output arrives as one JSON object, so an oversized one is refused at
        /// the framer rather than buffered — the guest's output cannot be
        /// truncated after the fact without having already held all of it.
        case responseTooLarge(limitBytes: Int)
        /// A `guest-exec`ed command was still running when its deadline passed.
        /// qga cannot signal a spawned process, so it is still running in the
        /// guest; the PID is carried so a caller can say which one.
        case executionTimedOut(pid: Int, seconds: Int)

        public var errorDescription: String? {
            switch self {
            case .connectionClosed: return "qga channel closed before a complete reply"
            case .syncMismatch: return "qga sync token mismatch"
            case .commandError(let desc): return desc
            case .commandUnavailable(let desc): return "qga command unavailable in this guest: \(desc)"
            case .malformedResponse: return "qga reply missing its return value"
            case .responseTooLarge(let limit): return "qga reply exceeded its \(limit)-byte budget"
            case .executionTimedOut(let pid, let seconds):
                return "guest command (pid \(pid)) did not exit within \(seconds)s and is still running"
            }
        }

        /// Maps a qga `error` object onto the case that describes it. qga reports
        /// a filtered-away command as `CommandNotFound` whose `desc` says it was
        /// disabled, so the class alone can't separate "agent too old" from
        /// "policy forbids it" — both mean unavailable, which is all a caller
        /// can act on (issue #803).
        static func from(_ error: QGA.ResponseError) -> QGAError {
            switch error.class {
            case "CommandNotFound", "CommandDisabled":
                return .commandUnavailable(error.desc ?? error.description)
            default:
                return .commandError(error.description)
            }
        }
    }

    private let transport: any QGATransport
    private let logger: Logger
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    /// Monotonic token source for `guest-sync-delimited`; a fresh value per
    /// resync lets a reply be confirmed as answering *this* sync.
    private var syncCounter = 0

    public init(transport: any QGATransport, logger: Logger) {
        self.transport = transport
        self.logger = logger
    }

    // MARK: - High-level operations

    /// Confirms the guest agent is answering. Throws on any failure (including a
    /// timeout imposed by the caller's `StageBudget`), which the caller reads as
    /// "no usable qga".
    public func ping() async throws {
        try await withChannel { channel, framer in
            try await self.performSync(channel, framer)
            _ = try await self.commandNoArgs(channel, framer, execute: "guest-ping", as: QGA.Empty.self)
        }
    }

    /// Asks the guest to power itself down cleanly (`guest-shutdown`, mode
    /// `powerdown`). Returns normally once the command is on the wire against a
    /// responsive agent; the guest often powers off before replying, so a
    /// connection drop *after* a successful sync is treated as success, not
    /// failure.
    public func requestShutdown() async throws {
        try await withChannel { channel, framer in
            try await self.performSync(channel, framer)
            do {
                try await self.writeRequest(
                    channel, execute: "guest-shutdown", arguments: QGA.ShutdownArguments())
                let object = try await self.readNextObject(channel, framer)
                let response = try self.decoder.decode(QGA.Response<QGA.Empty>.self, from: Data(object))
                if let error = response.error { throw QGAError.from(error) }
            } catch QGAError.connectionClosed {
                // The guest went down before answering — exactly what we asked
                // for. The sync above already proved qga was alive.
            }
        }
    }

    /// Freezes the guest's filesystems (`guest-fsfreeze-freeze`) for an
    /// application-consistent snapshot. Returns the number of filesystems
    /// frozen. **The caller must guarantee a matching `thawFilesystems()`** — a
    /// frozen guest is worse than a crash-consistent snapshot.
    public func freezeFilesystems() async throws -> Int {
        try await withChannel { channel, framer in
            try await self.performSync(channel, framer)
            return try await self.commandNoArgs(
                channel, framer, execute: "guest-fsfreeze-freeze", as: Int.self)
        }
    }

    /// Thaws the guest's filesystems (`guest-fsfreeze-thaw`). Returns the number
    /// of filesystems thawed. Safe to call when nothing is frozen (qga returns
    /// 0), which is what makes it usable from an unconditional `defer`.
    public func thawFilesystems() async throws -> Int {
        try await withChannel { channel, framer in
            try await self.performSync(channel, framer)
            return try await self.commandNoArgs(
                channel, framer, execute: "guest-fsfreeze-thaw", as: Int.self)
        }
    }

    /// Collects the guest's hostname and configured network interfaces into the
    /// shared `GuestInfo`. The sync handshake proves `qgaAvailable`; the detail
    /// queries are best-effort, so a failure of one still yields a `GuestInfo`
    /// carrying the positive liveness signal and whatever else succeeded.
    public func collectGuestInfo() async throws -> GuestInfo {
        try await withChannel { channel, framer in
            try await self.performSync(channel, framer)

            var hostName: String?
            if let name = try? await self.commandNoArgs(
                channel, framer, execute: "guest-get-host-name", as: QGA.HostName.self)
            {
                hostName = name.hostName
            }

            var interfaces: [QGA.NetworkInterface] = []
            if let reported = try? await self.commandNoArgs(
                channel, framer, execute: "guest-network-get-interfaces",
                as: [QGA.NetworkInterface].self)
            {
                interfaces = reported
            }

            return GuestInfo.from(qgaAvailable: true, hostName: hostName, interfaces: interfaces)
        }
    }

    /// Asks the guest agent which RPCs it will answer (`guest-info`).
    ///
    /// The result is deliberately *not* cached: a `QGAClient` is built per
    /// probe from a socket path, so there is no instance for a cache to
    /// outlive. A caller that wants to avoid re-asking should hold the returned
    /// value against the VM, and re-query when the VM restarts — a guest can be
    /// reconfigured and its agent restarted under a running VM.
    public func queryCapabilities() async throws -> GuestAgentCapabilities {
        try await withChannel { channel, framer in
            try await self.performSync(channel, framer)
            let info = try await self.commandNoArgs(
                channel, framer, execute: "guest-info", as: QGA.AgentInfo.self)
            return GuestAgentCapabilities(
                version: info.version,
                enabledCommands: Set(info.supportedCommands.filter(\.enabled).map(\.name)),
                disabledCommands: Set(info.supportedCommands.filter { !$0.enabled }.map(\.name))
            )
        }
    }

    // MARK: - Command execution (STR-74)

    /// Per-stream cap on captured output. qga hands over each stream whole, in
    /// one reply, so this is the amount of guest output the agent is willing to
    /// hold in memory for one command — not a truncation point.
    public static let defaultMaxCapturedBytes = 1 << 20  // 1 MiB

    /// Runs `command` in the guest and waits for it to exit, returning its exit
    /// status and captured output.
    ///
    /// qga models exec as spawn-and-poll: `guest-exec` returns a PID
    /// immediately and `guest-exec-status` reports completion. There is no
    /// completion notification, no PTY, no way to write more stdin, and no way
    /// to signal a running process — which is why this is a "run a command"
    /// primitive and can never be an interactive session. So this method polls
    /// with backoff until the guest reports the process exited or
    /// `timeoutSeconds` elapses. The polling is an ordinary loop over
    /// cancellable awaits rather than a background task, so a timed-out or
    /// cancelled call leaves nothing running on the agent side.
    ///
    /// **A timeout does not stop the guest process.** qga cannot signal it, so
    /// it keeps running (and keeps buffering output) inside the guest; the
    /// thrown `executionTimedOut` carries its PID. For the same reason the
    /// spawn is never retried — a retried `guest-exec` whose first attempt did
    /// reach the guest would run the command twice.
    ///
    /// Each round trip opens and closes its own channel rather than holding the
    /// qga chardev — which serves one client at a time — for the whole run, so
    /// a long command doesn't starve shutdown and guest-info probes for the
    /// same VM. A poll that loses that race is retried until the deadline.
    ///
    /// - Parameters:
    ///   - command: what to run; see `GuestCommand` for the no-shell caveat.
    ///   - timeoutSeconds: how long the command may run before it is abandoned.
    ///   - maxCapturedBytes: per-stream cap on captured output. A command that
    ///     produces more fails with `responseTooLarge` rather than buffering
    ///     unbounded guest output in the agent.
    public func runCommand(
        _ command: GuestCommand,
        timeoutSeconds: Int = StageBudget.guestExecSeconds,
        maxCapturedBytes: Int = QGAClient.defaultMaxCapturedBytes
    ) async throws -> GuestCommandResult {
        let pid = try await spawn(command)
        return try await awaitExit(
            pid: pid, timeoutSeconds: timeoutSeconds, maxCapturedBytes: maxCapturedBytes)
    }

    /// Issues `guest-exec` and returns the guest PID of the spawned process.
    private func spawn(_ command: GuestCommand) async throws -> Int {
        let arguments = QGA.ExecArguments(
            path: command.path,
            arg: command.arguments.isEmpty ? nil : command.arguments,
            env: command.environment.isEmpty ? nil : command.environment,
            inputData: command.input?.base64EncodedString(),
            captureOutput: command.captureOutput
        )
        return try await roundTrip(stage: "qga-exec-spawn") {
            try await self.spawnOnce(arguments)
        }
    }

    private func spawnOnce(_ arguments: QGA.ExecArguments) async throws -> Int {
        try await withChannel { channel, framer in
            try await self.performSync(channel, framer)
            try await self.writeRequest(channel, execute: "guest-exec", arguments: arguments)
            return try await self.readReturn(channel, framer, as: QGA.ExecPID.self).pid
        }
    }

    /// Polls `guest-exec-status` until the process exits or the deadline passes.
    private func awaitExit(
        pid: Int, timeoutSeconds: Int, maxCapturedBytes: Int
    ) async throws -> GuestCommandResult {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
        var delay = Self.initialPollInterval
        // The last failure to reach the agent, if the deadline arrives without
        // a single successful poll — more useful to report than "timed out".
        var lastFailure: (any Error)?

        while true {
            try Task.checkCancellation()
            do {
                if let result = try await fetchStatus(pid: pid, maxCapturedBytes: maxCapturedBytes) {
                    return result
                }
                lastFailure = nil
            } catch let error where Self.isRetryablePollFailure(error) {
                logger.debug(
                    "Retrying guest-exec-status",
                    metadata: ["pid": .stringConvertible(pid), "error": .string("\(error)")])
                lastFailure = error
            }

            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else {
                throw lastFailure ?? QGAError.executionTimedOut(pid: pid, seconds: timeoutSeconds)
            }
            try await Task.sleep(for: min(delay, remaining))
            delay = min(delay * 2, Self.maxPollInterval)
        }
    }

    /// One `guest-exec-status` round trip. Returns nil while the process is
    /// still running, which is the poll loop's cue to wait and ask again.
    private func fetchStatus(pid: Int, maxCapturedBytes: Int) async throws -> GuestCommandResult? {
        let status = try await roundTrip(stage: "qga-exec-status") {
            try await self.fetchStatusOnce(pid: pid, maxCapturedBytes: maxCapturedBytes)
        }
        guard status.exited else { return nil }
        let stdout = try Self.decodeCapture(status.outData, limit: maxCapturedBytes)
        let stderr = try Self.decodeCapture(status.errData, limit: maxCapturedBytes)
        return GuestCommandResult(
            exitCode: status.exitcode,
            signal: status.signal,
            stdout: stdout,
            stderr: stderr,
            stdoutTruncated: status.outTruncated ?? false,
            stderrTruncated: status.errTruncated ?? false
        )
    }

    private func fetchStatusOnce(pid: Int, maxCapturedBytes: Int) async throws -> QGA.ExecStatus {
        try await withChannel(maxBufferedBytes: Self.replyBudget(forCapture: maxCapturedBytes)) {
            channel, framer in
            try await self.performSync(channel, framer)
            try await self.writeRequest(
                channel, execute: "guest-exec-status", arguments: QGA.ExecStatusArguments(pid: pid))
            return try await self.readReturn(channel, framer, as: QGA.ExecStatus.self)
        }
    }

    /// Bounds one exec round trip with the ordinary qga budget. The command's
    /// own runtime is bounded by the caller's deadline; *this* bounds the
    /// millisecond-scale conversation with the agent, so a socket that goes
    /// silent mid-poll costs one interval instead of the whole deadline.
    private func roundTrip<T: Sendable>(
        stage: String, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await StageBudget.run(
            seconds: StageBudget.guestAgentSeconds, stage: stage, onTimeout: .cancelAndWait,
            operation: operation)
    }

    /// How long to wait before the first status poll, and the ceiling the
    /// backoff climbs to. Short at the start so a command that finishes in
    /// milliseconds is reported promptly; capped so a long-running one costs a
    /// round trip per second rather than per millisecond.
    private static let initialPollInterval = Duration.milliseconds(25)
    private static let maxPollInterval = Duration.seconds(1)

    /// Whether a failed poll is worth retrying before the deadline. A dropped
    /// or unreachable channel is expected: the qga chardev serves one client at
    /// a time, so a concurrent guest-info probe can transiently own it. An
    /// answer *from* the agent — an error object, an oversized reply — will not
    /// read differently next time.
    private static func isRetryablePollFailure(_ error: any Error) -> Bool {
        if error is CancellationError { return false }
        guard let qga = error as? QGAError else {
            // Transport level: connect refused, socket busy, a round trip that
            // blew its budget. All transient by nature.
            return true
        }
        switch qga {
        case .connectionClosed, .syncMismatch:
            return true
        case .commandError, .commandUnavailable, .malformedResponse, .responseTooLarge,
            .executionTimedOut:
            return false
        }
    }

    /// Framer budget for a `guest-exec-status` reply. Both captured streams
    /// arrive base64-encoded (4/3 expansion) inside one JSON object, so this
    /// admits any reply that could still decode within the caller's per-stream
    /// cap, plus the envelope. Anything larger trips the framer's bound and is
    /// refused mid-stream instead of being buffered whole.
    private static func replyBudget(forCapture limit: Int) -> Int {
        2 * ((limit * 4 + 2) / 3) + 64 * 1024
    }

    /// Decodes one base64 captured stream, refusing one that decodes past the
    /// cap. The framer bound above is the memory guard; this is the exact one,
    /// since base64 expansion leaves the framer's version necessarily loose.
    private static func decodeCapture(_ encoded: String?, limit: Int) throws -> Data {
        guard let encoded, !encoded.isEmpty else { return Data() }
        guard let data = Data(base64Encoded: encoded) else { throw QGAError.malformedResponse }
        guard data.count <= limit else { throw QGAError.responseTooLarge(limitBytes: limit) }
        return data
    }

    // MARK: - Channel lifecycle

    /// Opens a channel, runs `body`, and closes the channel whether or not
    /// `body` throws. `body` is non-escaping and runs within the actor, so it
    /// may call the actor's private helpers directly.
    ///
    /// `maxBufferedBytes` sizes the framer for what this operation legitimately
    /// expects back: qga replies are tiny, except a `guest-exec-status` that
    /// carries a command's captured output.
    private func withChannel<T>(
        maxBufferedBytes: Int = QGAObjectFramer.defaultMaxBufferedBytes,
        _ body: (any QGAByteChannel, QGAObjectFramer) async throws -> T
    ) async throws -> T {
        let channel = try await transport.openChannel()
        let framer = QGAObjectFramer(maxBufferedBytes: maxBufferedBytes)
        do {
            let result = try await body(channel, framer)
            await channel.close()
            return result
        } catch {
            await channel.close()
            throw error
        }
    }

    // MARK: - Protocol primitives

    /// Resynchronizes the stream with `guest-sync-delimited`: reset the agent's
    /// parser with a leading `0xFF`, send a unique token, discard everything up
    /// to the reply's `0xFF` marker, then confirm the reply echoes the token.
    /// Succeeding here is the liveness proof every operation depends on.
    private func performSync(_ channel: any QGAByteChannel, _ framer: QGAObjectFramer) async throws {
        syncCounter += 1
        let token = syncCounter

        var payload: [UInt8] = [0xFF]  // reset the guest agent's JSON parser
        let request = QGA.Request(
            execute: "guest-sync-delimited", arguments: QGA.SyncArguments(id: token))
        payload.append(contentsOf: try encoder.encode(request))
        payload.append(0x0A)  // newline: harmless, and nudges line-buffered agents
        try await channel.write(payload)

        // Discard buffered bytes up to and including the reply's leading marker.
        while !framer.consumeThroughSyncMarker() {
            let chunk = try await channel.readSome()
            if chunk.isEmpty { throw QGAError.connectionClosed }
            framer.append(chunk)
            if framer.isOverBudget { throw QGAError.responseTooLarge(limitBytes: framer.maxBufferedBytes) }
        }

        let object = try await readNextObject(channel, framer)
        let response = try decoder.decode(QGA.Response<Int>.self, from: Data(object))
        if let error = response.error { throw QGAError.from(error) }
        guard response.return == token else { throw QGAError.syncMismatch }
    }

    /// Sends a no-argument command and decodes its `return` value.
    private func commandNoArgs<Value: Decodable>(
        _ channel: any QGAByteChannel, _ framer: QGAObjectFramer,
        execute: String, as: Value.Type
    ) async throws -> Value {
        try await writeRequest(channel, execute: execute, arguments: QGA.NoArguments?.none)
        return try await readReturn(channel, framer, as: Value.self)
    }

    /// Encodes and writes a `{"execute": ...}` request (with `arguments` when
    /// present) followed by a newline.
    private func writeRequest<Arguments: Encodable>(
        _ channel: any QGAByteChannel, execute: String, arguments: Arguments?
    ) async throws {
        var payload = try Array(encoder.encode(QGA.Request(execute: execute, arguments: arguments)))
        payload.append(0x0A)
        try await channel.write(payload)
    }

    /// Reads the next reply object and returns its decoded `return` value,
    /// throwing on an `error` object or a missing `return`.
    private func readReturn<Value: Decodable>(
        _ channel: any QGAByteChannel, _ framer: QGAObjectFramer, as: Value.Type
    ) async throws -> Value {
        let object = try await readNextObject(channel, framer)
        let response = try decoder.decode(QGA.Response<Value>.self, from: Data(object))
        if let error = response.error { throw QGAError.from(error) }
        guard let value = response.return else { throw QGAError.malformedResponse }
        return value
    }

    /// Pulls chunks from the channel until the framer yields one complete JSON
    /// object. Throws `connectionClosed` at EOF.
    private func readNextObject(
        _ channel: any QGAByteChannel, _ framer: QGAObjectFramer
    ) async throws -> [UInt8] {
        while true {
            if let object = framer.nextObject() { return object }
            let chunk = try await channel.readSome()
            if chunk.isEmpty { throw QGAError.connectionClosed }
            framer.append(chunk)
            if framer.isOverBudget { throw QGAError.responseTooLarge(limitBytes: framer.maxBufferedBytes) }
        }
    }
}

extension QGA {
    /// Decodable placeholder for commands whose `return` is an empty object.
    struct Empty: Decodable {}
}
