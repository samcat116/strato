import Foundation

// MARK: - Sandbox Exec Messages (issue #423, protocol version >= 8)
//
// Control plane ⟷ agent messages carrying an interactive exec session inside a
// sandbox, plus the sandbox workload's stdout/stderr as log lines. The agent
// bridges these to the guest control protocol over vsock (see
// `docs/architecture/sandboxes.md`).
//
// Unlike the imperative volume/reboot exchanges these are stream messages:
// correlated by `sessionId` (not `requestId`), ordered by the WebSocket, and
// never answered with `success`/`error`. A `sandboxExecStart` is answered by
// `sandboxExecStarted` on success or `sandboxExecClosed` (with a reason) on
// failure.

/// Control plane → agent: start an exec session inside a running sandbox.
public struct SandboxExecStartMessage: WebSocketMessage {
    public var type: MessageType { .sandboxExecStart }
    public let requestId: String
    public let timestamp: Date
    public let sandboxId: String
    /// Control-plane-minted session identifier every subsequent message on
    /// this exec session carries.
    public let sessionId: String
    /// The argv to run in the container context. Never empty.
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
        sandboxId: String,
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
        self.sandboxId = sandboxId
        self.sessionId = sessionId
        self.command = command
        self.env = env
        self.workingDir = workingDir
        self.tty = tty
        self.rows = rows
        self.cols = cols
    }
}

/// Agent → control plane: the exec process spawned; output may follow.
public struct SandboxExecStartedMessage: WebSocketMessage {
    public var type: MessageType { .sandboxExecStarted }
    public let requestId: String
    public let timestamp: Date
    public let sandboxId: String
    public let sessionId: String

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        sandboxId: String,
        sessionId: String
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.sandboxId = sandboxId
        self.sessionId = sessionId
    }
}

/// Control plane → agent: stdin bytes for the exec process, and/or stdin EOF.
public struct SandboxExecInputMessage: WebSocketMessage {
    public var type: MessageType { .sandboxExecInput }
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
public struct SandboxExecOutputMessage: WebSocketMessage {
    public var type: MessageType { .sandboxExecOutput }
    public let requestId: String
    public let timestamp: Date
    public let sessionId: String
    /// "stdout" or "stderr" (always "stdout" for a tty session).
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
            requestId: requestId, timestamp: timestamp, sessionId: sessionId,
            stream: stream, data: rawData.base64EncodedString())
    }

    public var rawData: Data? {
        Data(base64Encoded: data)
    }
}

/// Control plane → agent: resize the exec session's PTY.
public struct SandboxExecResizeMessage: WebSocketMessage {
    public var type: MessageType { .sandboxExecResize }
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
public struct SandboxExecExitMessage: WebSocketMessage {
    public var type: MessageType { .sandboxExecExit }
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
public struct SandboxExecCloseMessage: WebSocketMessage {
    public var type: MessageType { .sandboxExecClose }
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
/// spawn failed, the guest channel died, or the sandbox stopped. Terminal for
/// the session.
public struct SandboxExecClosedMessage: WebSocketMessage {
    public var type: MessageType { .sandboxExecClosed }
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
