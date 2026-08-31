import Foundation

// MARK: - Guest Exec Messages (STR-78/STR-260; resource kind v44, session kind/state v54)
//
// Control plane ⟷ agent messages carrying an exec session inside a guest. The
// resource discriminator selects either a VM or a sandbox; the session-kind
// discriminator separates live interactive streams from recorded commands that
// survive a control-plane WebSocket reconnect while the agent process stays
// alive. The agent bridges both kinds to that guest's control protocol.
//
// Interactive frames are stream messages: correlated by `sessionId` (not
// `requestId`), ordered by the WebSocket, and never answered with
// `success`/`error`. A `guestExecStart` is answered by `guestExecStarted` on
// success or `guestExecClosed` (with a reason) on failure. Recorded reconnect
// state is instead a full level-triggered snapshot keyed by the same session.

/// A resource whose guest control channel can host an exec session.
public enum GuestResourceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case virtualMachine = "virtual_machine"
    case sandbox
}

/// Whether an exec session is tied to a live frontend or records a durable
/// command result for later retrieval.
public enum GuestExecSessionKind: String, Codable, CaseIterable, Hashable, Sendable {
    case interactive
    case recorded
}

/// Control plane → agent: start an exec session inside a running guest.
public struct GuestExecStartMessage: WebSocketMessage {
    public var type: MessageType { .guestExecStart }
    public let requestId: String
    public let timestamp: Date
    public let resourceKind: GuestResourceKind
    public let resourceId: String
    /// Interactive sessions end with their frontend connection. Recorded
    /// sessions survive a control-plane WebSocket reconnect while this agent
    /// process remains alive and replay their state until acknowledged.
    public let sessionKind: GuestExecSessionKind
    /// Control-plane-minted session identifier every subsequent message on
    /// this exec session carries.
    public let sessionId: String
    /// The argv to run in the guest context. Never empty.
    public let command: [String]
    /// Extra environment merged over the workload's resolved environment.
    public let env: [String: String]?
    /// Working directory; nil inherits the workload's resolved cwd.
    public let workingDir: String?
    /// Allocate a PTY. When true all output arrives as the `stdout` stream.
    public let tty: Bool
    public let rows: Int?
    public let cols: Int?

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        resourceKind: GuestResourceKind,
        resourceId: String,
        sessionKind: GuestExecSessionKind,
        sessionId: String,
        command: [String],
        env: [String: String]? = nil,
        workingDir: String? = nil,
        tty: Bool = false,
        rows: Int? = nil,
        cols: Int? = nil
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.resourceKind = resourceKind
        self.resourceId = resourceId
        self.sessionKind = sessionKind
        self.sessionId = sessionId
        self.command = command
        self.env = env
        self.workingDir = workingDir
        self.tty = tty
        self.rows = rows
        self.cols = cols
    }
}

/// The agent's current state for a recorded exec session.
public enum GuestExecRecordedStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case running
    case exited
    case closed

    public var isTerminal: Bool {
        self != .running
    }
}

/// Agent → control plane: the complete bounded state of a recorded exec
/// session. This is a level-triggered snapshot, not an output delta or a reply.
///
/// The agent re-offers running snapshots after registration and replays a
/// terminal snapshot until it receives ``GuestExecRecordedAckMessage``. The
/// status fields have these invariants:
///
/// - `running`: `exitCode` and `reason` are nil.
/// - `exited`: `exitCode` is non-nil and `reason` is nil.
/// - `closed`: `exitCode` is nil and `reason` is non-nil.
///
/// `revision` is a non-negative, per-session counter. The agent advances it
/// whenever the authoritative capture changes, so replicas can reject an older
/// snapshot after a reconnect without relying on socket arrival order.
///
/// `stdout` and `stderr` are authoritative base64-encoded snapshots. Their
/// combined decoded size never exceeds ``outputLimitBytes``. `truncated` says
/// the capture may be incomplete: either bytes exceeded that bound or the
/// channel closed without an authoritative `exec_exit` record.
public struct GuestExecRecordedStateMessage: WebSocketMessage {
    /// Maximum combined decoded stdout and stderr retained for one recorded
    /// session. Both peers use this value so the replay remains bounded.
    public static let outputLimitBytes = 1_048_576

    public var type: MessageType { .guestExecRecordedState }
    public let requestId: String
    public let timestamp: Date
    public let sessionId: String
    public let revision: Int64
    public let status: GuestExecRecordedStatus
    public let stdout: String
    public let stderr: String
    public let exitCode: Int?
    public let reason: String?
    public let truncated: Bool

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        sessionId: String,
        revision: Int64,
        status: GuestExecRecordedStatus,
        stdout: String,
        stderr: String,
        exitCode: Int? = nil,
        reason: String? = nil,
        truncated: Bool
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.sessionId = sessionId
        self.revision = revision
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.reason = reason
        self.truncated = truncated
    }

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        sessionId: String,
        revision: Int64,
        status: GuestExecRecordedStatus,
        rawStdout: Data,
        rawStderr: Data,
        exitCode: Int? = nil,
        reason: String? = nil,
        truncated: Bool
    ) {
        self.init(
            requestId: requestId,
            timestamp: timestamp,
            sessionId: sessionId,
            revision: revision,
            status: status,
            stdout: rawStdout.base64EncodedString(),
            stderr: rawStderr.base64EncodedString(),
            exitCode: exitCode,
            reason: reason,
            truncated: truncated
        )
    }

    public var rawStdout: Data? {
        Data(base64Encoded: stdout)
    }

    public var rawStderr: Data? {
        Data(base64Encoded: stderr)
    }
}

/// Control plane → agent: retire a terminal recorded-session snapshot after
/// the control plane durably committed or deliberately discarded its outcome.
///
/// This typed acknowledgement is keyed by `sessionId`. Its independently
/// minted `requestId` is only a log-correlation handle; it does not correlate
/// this message as a generic RPC reply. An acknowledgement is meaningful only
/// for an `exited` or `closed` snapshot.
public struct GuestExecRecordedAckMessage: WebSocketMessage {
    public var type: MessageType { .guestExecRecordedAck }
    public let requestId: String
    public let timestamp: Date
    public let sessionId: String

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        sessionId: String
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.sessionId = sessionId
    }
}

/// Agent → control plane: the exec process spawned; output may follow.
public struct GuestExecStartedMessage: WebSocketMessage {
    public var type: MessageType { .guestExecStarted }
    public let requestId: String
    public let timestamp: Date
    public let sessionId: String

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        sessionId: String
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.sessionId = sessionId
    }
}

/// Control plane → agent: stdin bytes for the exec process, and/or stdin EOF.
public struct GuestExecInputMessage: WebSocketMessage {
    public var type: MessageType { .guestExecInput }
    public let requestId: String
    public let timestamp: Date
    public let sessionId: String
    /// Base64-encoded stdin bytes; nil for an EOF-only message.
    public let data: String?
    /// Close the exec process's stdin after writing `data` (if any).
    public let eof: Bool

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        sessionId: String,
        data: String? = nil,
        eof: Bool = false
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.sessionId = sessionId
        self.data = data
        self.eof = eof
    }

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        sessionId: String,
        rawData: Data,
        eof: Bool = false
    ) {
        self.init(
            requestId: requestId, timestamp: timestamp, sessionId: sessionId,
            data: rawData.base64EncodedString(), eof: eof)
    }

    public var rawData: Data? {
        data.flatMap { Data(base64Encoded: $0) }
    }
}

/// Agent → control plane: output bytes from the exec process.
public struct GuestExecOutputMessage: WebSocketMessage {
    public var type: MessageType { .guestExecOutput }
    public let requestId: String
    public let timestamp: Date
    public let sessionId: String
    /// `stdout` or `stderr`; PTY sessions always use `stdout`.
    public let stream: String
    /// Base64-encoded output bytes.
    public let data: String

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        sessionId: String,
        stream: String,
        data: String
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.sessionId = sessionId
        self.stream = stream
        self.data = data
    }

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        sessionId: String,
        stream: String,
        rawData: Data
    ) {
        self.init(
            requestId: requestId, timestamp: timestamp, sessionId: sessionId, stream: stream,
            data: rawData.base64EncodedString())
    }

    public var rawData: Data? {
        Data(base64Encoded: data)
    }
}

/// Control plane → agent: resize the exec session's PTY.
public struct GuestExecResizeMessage: WebSocketMessage {
    public var type: MessageType { .guestExecResize }
    public let requestId: String
    public let timestamp: Date
    public let sessionId: String
    public let rows: Int
    public let cols: Int

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        sessionId: String,
        rows: Int,
        cols: Int
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.sessionId = sessionId
        self.rows = rows
        self.cols = cols
    }
}

/// Agent → control plane: the exec process ended. Terminal for the session;
/// all output was sent before this message.
public struct GuestExecExitMessage: WebSocketMessage {
    public var type: MessageType { .guestExecExit }
    public let requestId: String
    public let timestamp: Date
    public let sessionId: String
    /// Shell convention: a process killed by signal N reports 128 + N.
    public let exitCode: Int

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        sessionId: String,
        exitCode: Int
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.sessionId = sessionId
        self.exitCode = exitCode
    }
}

/// Control plane → agent: tear down an exec session (the browser went away).
public struct GuestExecCloseMessage: WebSocketMessage {
    public var type: MessageType { .guestExecClose }
    public let requestId: String
    public let timestamp: Date
    public let sessionId: String
    public let reason: String?

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        sessionId: String,
        reason: String? = nil
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.sessionId = sessionId
        self.reason = reason
    }
}

/// Agent → control plane: the exec session ended without an exit code — the
/// spawn failed, the guest channel died, or the resource stopped. Terminal for
/// the session.
public struct GuestExecClosedMessage: WebSocketMessage {
    public var type: MessageType { .guestExecClosed }
    public let requestId: String
    public let timestamp: Date
    public let sessionId: String
    public let reason: String?

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        sessionId: String,
        reason: String? = nil
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.sessionId = sessionId
        self.reason = reason
    }
}

// MARK: - Sandbox Workload Logs

/// Agent → control plane: one line of the sandbox workload's stdout/stderr,
/// destined for Loki (the sandbox counterpart of `VMLogMessage`).
public struct SandboxLogMessage: WebSocketMessage {
    public var type: MessageType { .sandboxLog }
    public let requestId: String
    public let timestamp: Date
    public let sandboxId: String
    /// "stdout" or "stderr".
    public let stream: String
    /// One output line, decoded as UTF-8 (lossily) with the newline stripped.
    public let message: String

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        sandboxId: String,
        stream: String,
        message: String
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.sandboxId = sandboxId
        self.stream = stream
        self.message = message
    }
}
