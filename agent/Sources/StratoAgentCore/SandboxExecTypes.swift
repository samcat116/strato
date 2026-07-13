import Foundation

/// The host-side description of an exec session to start inside a sandbox
/// (issue #423): the `SandboxRuntimeService.startExec` request, mirroring the
/// control plane's `SandboxExecStartMessage` fields.
public struct SandboxExecRequest: Equatable, Sendable {
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
        command: [String],
        env: [String: String]? = nil,
        workingDir: String? = nil,
        tty: Bool = false,
        rows: Int? = nil,
        cols: Int? = nil
    ) {
        self.command = command
        self.env = env
        self.workingDir = workingDir
        self.tty = tty
        self.rows = rows
        self.cols = cols
    }

    /// The guest control protocol request carrying this exec description.
    public var guestRequest: SandboxControlProtocol.ExecRequest {
        SandboxControlProtocol.ExecRequest(
            argv: command, env: env, cwd: workingDir, tty: tty, rows: rows, cols: cols)
    }
}

/// One event on a live exec session, delivered by the runtime to the Agent's
/// events callback in guest order.
public enum SandboxExecEvent: Equatable, Sendable {
    /// The exec process spawned (guest sent `exec_started`).
    case started
    /// Output bytes (`stream` is `stdout`/`stderr`; always `stdout` for tty).
    case output(stream: String, data: Data)
    /// Terminal: the process ended with `code` (signal N → 128 + N).
    case exited(code: Int)
    /// Terminal: the session ended without an exit code — the guest channel
    /// died, the guest reported an error, or the sandbox stopped.
    case closed(reason: String?)
}
