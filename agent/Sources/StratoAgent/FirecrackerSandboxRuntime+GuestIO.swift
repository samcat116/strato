import Foundation
import Logging
import StratoAgentCore
import StratoShared

#if os(Linux)
import Glibc
import SwiftFirecracker

/// Owns guest exec sessions, connection transitions, and workload log streaming.
extension FirecrackerSandboxRuntime {
    // MARK: - Exec sessions (issue #423)

    func startExec(
        sandboxId: String,
        sessionId: String,
        request: SandboxExecRequest,
        events: @escaping @Sendable (SandboxExecEvent) -> Void
    ) async throws {
        guard let managed = sandboxes[sandboxId] else {
            throw SandboxRuntimeError.sandboxNotFound(sandboxId)
        }
        guard !checkpointing.contains(sandboxId) else {
            throw SandboxRuntimeError.checkpointInProgress(sandboxId)
        }
        guard execSessions[sessionId] == nil else {
            // Session ids are minted per attach by the control plane; a
            // duplicate start is a stream replay we must not double-bridge.
            return
        }

        logger.info(
            "Starting sandbox exec session",
            metadata: [
                "sandboxId": .string(sandboxId),
                "sessionId": .string(sessionId),
                "tty": .stringConvertible(request.tty),
            ])

        // Snapshot the sweep epoch before suspending: a concurrent stop or
        // delete sweeps `execSessions` while this session is still mid-
        // handshake and would miss it.
        let sweepEpoch = managed.execSweepEpoch

        // A dedicated connection per session: its first line (`exec`) turns it
        // into the session's channel, and closing it later kills the exec
        // process group guest-side.
        let connection = try await VsockConnection.connect(
            udsPath: managed.vsockUdsPath, port: SandboxConfigDrive.defaultVsockPort,
            timeout: Self.execConnectTimeout, logger: logger)

        // Wait (bounded) for the guest to confirm the spawn. The connection
        // frames lines itself and retains anything the guest sent past the
        // confirmation, so early output is picked up by the reader below
        // without having to be handed across explicitly.
        do {
            try await Self.awaitExecStarted(
                .exec(request.guestRequest), on: connection, timeout: Self.execConnectTimeout)
        } catch {
            await connection.close()
            throw error
        }

        // Back on the actor: re-check that no teardown raced the awaits above.
        // If the sandbox was deleted, or a stop/delete swept its exec sessions
        // (epoch bumped) before this one was registered, registering now would
        // bind the session to a stopped/deleted sandbox that can never deliver
        // a terminal event — refuse instead; the thrown error becomes the
        // control plane's `guestExecClosed`.
        guard let current = sandboxes[sandboxId], current.execSweepEpoch == sweepEpoch else {
            await connection.close()
            throw SandboxRuntimeError.sandboxNotFound(
                "\(sandboxId) (stopped or deleted while the exec session was starting)")
        }

        // Confirmed: report `.started` before any output, then drain the
        // session on a detached reader (its reads block between output chunks,
        // which must never park the actor).
        events(.started)
        var session = ExecSession(sandboxId: sandboxId, connection: connection, events: events, reader: nil)
        session.reader = Task.detached { [weak self, logger] in
            await Self.runExecReader(
                sessionId: sessionId, connection: connection,
                events: events, runtime: self, logger: logger)
        }
        execSessions[sessionId] = session
    }

    func sendExecInput(sessionId: String, data: Data?, eof: Bool) async throws {
        guard let session = execSessions[sessionId] else {
            throw SandboxRuntimeError.execSessionNotFound(sessionId)
        }
        if let data, !data.isEmpty {
            try await session.connection.write(GuestControlProtocol.Request.stdin(data).encodedLine())
        }
        if eof {
            try await session.connection.write(GuestControlProtocol.Request.stdinEof.encodedLine())
        }
    }

    func resizeExec(sessionId: String, rows: Int, cols: Int) async throws {
        guard let session = execSessions[sessionId] else {
            throw SandboxRuntimeError.execSessionNotFound(sessionId)
        }
        try await session.connection.write(
            GuestControlProtocol.Request.resize(rows: rows, cols: cols).encodedLine())
    }

    func closeExec(sessionId: String) async {
        guard let session = execSessions.removeValue(forKey: sessionId) else { return }
        logger.info(
            "Closing sandbox exec session",
            metadata: ["sandboxId": .string(session.sandboxId), "sessionId": .string(sessionId)])
        // Closing the connection kills the exec process group guest-side and
        // unblocks the reader, whose end-of-session callback finds the session
        // already deregistered and stays silent — the closer needs no event.
        await session.connection.close()
        session.reader?.cancel()
    }

    /// Terminal teardown of every live exec session of one sandbox (stop or
    /// delete): each session's control-plane side gets a `.closed` with the
    /// reason. Bumps the sandbox's sweep epoch so a `startExec` still awaiting
    /// its handshake refuses to register a session this sweep could not see.
    func closeExecSessions(sandboxId: String, reason: String) async {
        sandboxes[sandboxId]?.execSweepEpoch += 1
        for (sessionId, session) in execSessions where session.sandboxId == sandboxId {
            execSessions.removeValue(forKey: sessionId)
            await session.connection.close()
            session.reader?.cancel()
            session.events(.closed(reason: reason))
        }
    }

    /// The reader's end-of-session callback: emits the terminal event unless
    /// the session was already deregistered (an explicit `closeExec` or a
    /// sandbox teardown, which speak for themselves).
    func execSessionEnded(sessionId: String, terminal: SandboxExecEvent) async {
        guard let session = execSessions.removeValue(forKey: sessionId) else { return }
        await session.connection.close()
        logger.info(
            "Sandbox exec session ended",
            metadata: [
                "sandboxId": .string(session.sandboxId),
                "sessionId": .string(sessionId),
                "terminal": .string(String(describing: terminal)),
            ])
        session.events(terminal)
    }

    /// Write the `exec` line and read until the guest confirms `exec_started`.
    /// A guest `error` line (spawn failure) throws.
    static func awaitExecStarted(
        _ request: GuestControlProtocol.Request, on connection: VsockConnection,
        timeout: TimeInterval
    ) async throws {
        try await connection.write(request.encodedLine())

        guard let line = try await nextControlLine(on: connection, timeout: timeout) else {
            throw GuestControlError.malformedResponse("guest closed before confirming exec start")
        }
        let response = try GuestControlProtocol.Response.decode(line: line)
        if case .error(_, let message) = response {
            throw GuestControlError.guestError(message)
        }
        guard case .execStarted = response else {
            throw GuestControlError.malformedResponse("expected exec_started, got \(response)")
        }
    }

    /// Drains one exec session's connection for its whole life: decodes
    /// `output` records into `.output` events and finishes the session on
    /// `exec_exit`, a guest `error`, or the channel dying. Runs detached, with
    /// no read deadline — the session ends when the guest closes or when
    /// teardown closes the connection, which completes the pending read.
    static func runExecReader(
        sessionId: String,
        connection: VsockConnection,
        events: @escaping @Sendable (SandboxExecEvent) -> Void,
        runtime: FirecrackerSandboxRuntime?,
        logger: Logger
    ) async {
        func finish(_ terminal: SandboxExecEvent) async {
            await runtime?.execSessionEnded(sessionId: sessionId, terminal: terminal)
        }

        while true {
            let line: String?
            do {
                line = try await connection.nextLine()
            } catch {
                // A read failure on a session we tore down ourselves is the
                // expected wakeup; `execSessionEnded` stays silent then.
                await finish(.closed(reason: "sandbox exec channel failed: \(error.localizedDescription)"))
                return
            }
            guard let line else {
                await finish(.closed(reason: "sandbox exec channel closed"))
                return
            }

            let response: GuestControlProtocol.Response
            do {
                response = try GuestControlProtocol.Response.decode(line: line)
            } catch {
                await finish(.closed(reason: "malformed exec record from guest"))
                return
            }
            switch response {
            case .output(_, let stream, let data):
                events(.output(stream: stream, data: data))
            case .execExit(_, let exitCode):
                await finish(.exited(code: exitCode))
                return
            case .error(_, let message):
                await finish(.closed(reason: "guest error: \(message)"))
                return
            default:
                await finish(.closed(reason: "unexpected exec record from guest"))
                return
            }
        }
    }

    // MARK: - Control-plane connectivity (issue #423)

    func controlPlaneDisconnected() async {
        // Exec sessions: their frontends are unreachable and the control plane
        // cannot send guestExecClose over the dead socket. Closing the guest
        // connections kills the exec process groups; the .closed events this
        // emits are dropped by the (dead) send path, which is fine — the
        // control plane tears its side down in its own agent-close handler.
        let sandboxIds = Set(execSessions.values.map(\.sandboxId))
        for sandboxId in sandboxIds {
            await closeExecSessions(sandboxId: sandboxId, reason: "control plane disconnected")
        }

        // Log follows: suspend, keeping seq/partial-line state. Output the
        // workload produces during the gap stays in the guest ring buffer for
        // the resumed follow; only records consumed in the instant before the
        // drop was noticed can be lost (the delivery path has no acks).
        for sandboxId in Array(logFollows.keys) {
            await stopLogFollow(sandboxId: sandboxId, retire: false)
        }
    }

    func controlPlaneConnected() async {
        for (sandboxId, managed) in sandboxes {
            // A checkpoint/restore in flight has deliberately drained this
            // sandbox's vsock connections; it restarts the follow itself
            // when it finishes.
            guard !checkpointing.contains(sandboxId) else { continue }
            guard let info = try? await managed.manager.getInstanceInfo(), info.state == .running else {
                continue
            }
            startLogFollow(sandboxId: sandboxId)
        }
    }

    // MARK: - Workload log shipping (issue #423)

    func setSandboxLogHandler(_ handler: @escaping @Sendable (String, String, String) -> Void) async {
        logHandler = handler
    }

    /// Start (or restart) the sandbox's log follow loop. Idempotent while a
    /// loop is live; seq/partial-line state carries over from a previous loop
    /// so delivery resumes without loss or duplication.
    func startLogFollow(sandboxId: String) {
        guard logHandler != nil else { return }
        guard let managed = sandboxes[sandboxId] else { return }
        if logFollows[sandboxId]?.task != nil { return }

        var follow =
            logFollows[sandboxId]
            ?? LogFollow(generation: 0, task: nil, connection: nil, lastSeq: 0, assembler: SandboxLogLineAssembler())
        follow.generation += 1
        let generation = follow.generation
        let udsPath = managed.vsockUdsPath

        logger.debug(
            "Starting sandbox log follow",
            metadata: ["sandboxId": .string(sandboxId), "sinceSeq": .stringConvertible(follow.lastSeq + 1)])

        follow.task = Task.detached { [weak self, logger] in
            await Self.runLogFollowLoop(
                sandboxId: sandboxId, generation: generation, udsPath: udsPath,
                runtime: self, logger: logger)
        }
        logFollows[sandboxId] = follow
    }

    /// Stop the sandbox's log follow loop. `retire: true` (delete) is the
    /// workload's end-of-stream: any buffered partial line is flushed and the
    /// state dropped; `retire: false` (stop/pause) keeps seq and partial-line
    /// state for the next boot.
    func stopLogFollow(sandboxId: String, retire: Bool) async {
        guard var follow = logFollows[sandboxId] else { return }
        // Bump the generation so a loop iteration already past its
        // cancellation check can no longer register connections or records.
        follow.generation += 1
        follow.task?.cancel()
        follow.task = nil
        if let connection = follow.connection {
            // Unblocks the loop's in-flight blocking read.
            await connection.close()
            follow.connection = nil
        }
        if retire {
            logFollows.removeValue(forKey: sandboxId)
            for line in follow.assembler.flush() {
                logHandler?(sandboxId, line.stream, line.text)
            }
        } else {
            logFollows[sandboxId] = follow
        }
    }

    /// The follow loop's per-connect checkpoint: the seq to resume from, or
    /// nil once this loop generation has been superseded or retired.
    ///
    /// `lastSeq` is guest-supplied, so this `+ 1` is only trap-free because the
    /// decoder caps a record's seq well below `UInt64.max`
    /// (`GuestControlProtocol.Limits.maxLogSeq`).
    func logFollowSinceSeq(sandboxId: String, generation: UInt64) -> UInt64? {
        guard let follow = logFollows[sandboxId], follow.generation == generation else { return nil }
        return follow.lastSeq + 1
    }

    /// Adopt `connection` as the follow loop's live connection so a stop can
    /// close it. Returns false when the loop generation was superseded — the
    /// caller must close the connection and exit.
    func registerLogConnection(
        sandboxId: String, generation: UInt64, connection: VsockConnection
    ) -> Bool {
        guard var follow = logFollows[sandboxId], follow.generation == generation else { return false }
        follow.connection = connection
        logFollows[sandboxId] = follow
        return true
    }

    func unregisterLogConnection(sandboxId: String, generation: UInt64) {
        guard var follow = logFollows[sandboxId], follow.generation == generation else { return }
        follow.connection = nil
        logFollows[sandboxId] = follow
    }

    /// Record one ring-buffer record: advance the resume seq, feed the line
    /// assembler, and hand every completed line to the log handler (in order —
    /// the follow loop awaits each record, so this runs sequentially).
    func recordLog(
        sandboxId: String, generation: UInt64, seq: UInt64, stream: String, data: Data
    ) {
        guard var follow = logFollows[sandboxId], follow.generation == generation else { return }
        follow.lastSeq = max(follow.lastSeq, seq)
        let lines = follow.assembler.append(stream: stream, data: data)
        logFollows[sandboxId] = follow
        for line in lines {
            logHandler?(sandboxId, line.stream, line.text)
        }
    }

    /// The guest reported log end-of-stream (`log_eof`): every workload stdio
    /// pipe hit EOF and every retained record was delivered. Flush a partial
    /// final line now (output that ended without a trailing newline would
    /// otherwise be held until delete), but keep the seq checkpoint — a later
    /// boot's follow reconnects, is told EOF again, and ends just as quietly,
    /// without replaying records as duplicates.
    func finishLogFollow(sandboxId: String, generation: UInt64) {
        guard var follow = logFollows[sandboxId], follow.generation == generation else { return }
        follow.task = nil
        follow.connection = nil
        let lines = follow.assembler.flush()
        logFollows[sandboxId] = follow
        for line in lines {
            logHandler?(sandboxId, line.stream, line.text)
        }
    }

    /// The long-lived follow loop for one sandbox: connect, send
    /// `stream_logs` resuming after the last recorded seq, and feed records to
    /// the actor until the connection dies; then reconnect with 1s..30s
    /// exponential backoff for as long as the loop generation stays current.
    /// A paused sandbox surfaces as connect timeouts, so the loop idles at the
    /// backoff cap instead of spinning. Runs detached: the follow read blocks
    /// indefinitely between records, which is fine off-actor.
    static func runLogFollowLoop(
        sandboxId: String,
        generation: UInt64,
        udsPath: String,
        runtime: FirecrackerSandboxRuntime?,
        logger: Logger
    ) async {
        var backoff: TimeInterval = 1

        while !Task.isCancelled {
            guard let runtime else { return }
            guard let sinceSeq = await runtime.logFollowSinceSeq(sandboxId: sandboxId, generation: generation)
            else { return }

            do {
                let connection = try await VsockConnection.connect(
                    udsPath: udsPath, port: SandboxConfigDrive.defaultVsockPort,
                    timeout: execConnectTimeout, logger: logger)
                guard
                    await runtime.registerLogConnection(
                        sandboxId: sandboxId, generation: generation, connection: connection)
                else {
                    await connection.close()
                    return
                }

                var streamComplete = false
                do {
                    try await connection.write(
                        GuestControlProtocol.Request.streamLogs(sinceSeq: sinceSeq).encodedLine())
                    streamComplete = try await Self.followLogStream(
                        sandboxId: sandboxId, generation: generation, connection: connection,
                        runtime: runtime, backoff: &backoff)
                } catch {
                    logger.debug(
                        "Sandbox log follow stream ended",
                        metadata: [
                            "sandboxId": .string(sandboxId),
                            "error": .string(error.localizedDescription),
                        ])
                }
                await runtime.unregisterLogConnection(sandboxId: sandboxId, generation: generation)
                await connection.close()
                if streamComplete {
                    // The guest declared end-of-stream: nothing will ever
                    // arrive again, so the loop ends instead of reconnecting.
                    return
                }
            } catch {
                logger.debug(
                    "Sandbox log follow connect failed",
                    metadata: [
                        "sandboxId": .string(sandboxId),
                        "error": .string(error.localizedDescription),
                    ])
            }

            if Task.isCancelled { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            } catch {
                return  // cancelled during backoff
            }
            backoff = min(backoff * 2, 30)
        }
    }

    /// Read one follow connection to exhaustion, decoding `log` records and
    /// recording each with the actor. Any delivered record resets the caller's
    /// reconnect backoff (the guest is demonstrably healthy). Returns true when
    /// the guest sent `log_eof` — the stream is complete and the caller must
    /// stop reconnecting — and false when the connection merely closed.
    static func followLogStream(
        sandboxId: String,
        generation: UInt64,
        connection: VsockConnection,
        runtime: FirecrackerSandboxRuntime,
        backoff: inout TimeInterval
    ) async throws -> Bool {
        while true {
            guard let line = try await connection.nextLine() else {
                return false  // guest closed; the loop reconnects
            }
            switch try GuestControlProtocol.Response.decode(line: line) {
            case .log(_, let seq, let stream, let data):
                await runtime.recordLog(
                    sandboxId: sandboxId, generation: generation, seq: seq, stream: stream, data: data)
                backoff = 1
            case .logEof:
                await runtime.finishLogFollow(sandboxId: sandboxId, generation: generation)
                return true
            default:
                // `.malformed` rather than the case directly: `line` is guest
                // bytes, and this error's text reaches the log.
                throw GuestControlError.malformed(line)
            }
        }
    }
}

#endif
