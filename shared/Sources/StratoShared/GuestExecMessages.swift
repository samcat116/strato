import Foundation

// MARK: - Guest Exec Messages (STR-78, protocol version >= 43)
//
// Control plane ⟷ agent messages carrying an interactive exec session inside a
// guest. The resource discriminator selects either a VM or a sandbox; the agent
// bridges the stream to that guest's control protocol.
//
// Unlike the imperative volume/reboot exchanges these are stream messages:
// correlated by `sessionId` (not `requestId`), ordered by the WebSocket, and
// never answered with `success`/`error`. A `guestExecStart` is answered by
// `guestExecStarted` on success or `guestExecClosed` (with a reason) on
// failure.

/// A resource whose guest control channel can host an exec session.
public enum GuestResourceKind: String, Codable, CaseIterable, Sendable {
    case virtualMachine = "virtual_machine"
    case sandbox
}

/// Control plane → agent: start an exec session inside a running guest.
public struct GuestExecStartMessage: WebSocketMessage {
    public var type: MessageType { .guestExecStart }
    public let requestId: String
    public let timestamp: Date
    public let resourceKind: GuestResourceKind
    public let resourceId: String
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
    /// Base64-encoded output bytes (stdout and stderr interleaved; the
    /// receiving side renders one stream).
    public let data: String

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        sessionId: String,
        data: String
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.sessionId = sessionId
        self.data = data
    }

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        sessionId: String,
        rawData: Data
    ) {
        self.init(
            requestId: requestId, timestamp: timestamp, sessionId: sessionId,
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

// MARK: - One-release legacy decode (wire v42)

/// The only legacy exec payload whose shape differs from its `guest_exec_*`
/// replacement. The v42 message types stay routable for one release so an
/// upgraded agent can translate an old sandbox start into `.sandbox`.
public struct LegacySandboxExecStartMessage: WebSocketMessage {
    public var type: MessageType { .sandboxExecStart }
    public let requestId: String
    public let timestamp: Date
    public let sandboxId: String
    public let sessionId: String
    public let command: [String]
    public let env: [String: String]?
    public let workingDir: String?
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

    public var guestMessage: GuestExecStartMessage {
        GuestExecStartMessage(
            requestId: requestId,
            timestamp: timestamp,
            resourceKind: .sandbox,
            resourceId: sandboxId,
            sessionId: sessionId,
            command: command,
            env: env,
            workingDir: workingDir,
            tty: tty,
            rows: rows,
            cols: cols)
    }
}

/// Wire v42 response payloads. Their fields are identical to the guest forms,
/// but their envelope types must remain sandbox-prefixed when a v42 start
/// initiated the session.
public struct LegacySandboxExecStartedMessage: WebSocketMessage {
    public var type: MessageType { .sandboxExecStarted }
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

public struct LegacySandboxExecOutputMessage: WebSocketMessage {
    public var type: MessageType { .sandboxExecOutput }
    public let requestId: String
    public let timestamp: Date
    public let sessionId: String
    public let data: String

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        sessionId: String,
        rawData: Data
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.sessionId = sessionId
        self.data = rawData.base64EncodedString()
    }
}

public struct LegacySandboxExecExitMessage: WebSocketMessage {
    public var type: MessageType { .sandboxExecExit }
    public let requestId: String
    public let timestamp: Date
    public let sessionId: String
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

public struct LegacySandboxExecClosedMessage: WebSocketMessage {
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
