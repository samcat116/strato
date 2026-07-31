import Foundation

/// A command to run inside a guest via the QEMU guest agent (STR-74).
///
/// `path` is executed directly — qga does no shell interpretation, so pipes,
/// globs, redirection, and `&&` require an explicit shell (`path: "/bin/sh"`,
/// `arguments: ["-c", ...]`). Note that qga also does not fill in `argv[0]`:
/// `arguments` *is* the argument list after the program name.
public struct GuestCommand: Sendable, Equatable {
    /// Absolute path to the executable in the guest.
    public var path: String
    /// Arguments after the program name.
    public var arguments: [String]
    /// `KEY=VALUE` entries. Empty means the agent's own environment, which for
    /// a systemd-launched qga is a bare service environment, not a login shell's.
    public var environment: [String]
    /// Bytes written to the process's stdin, which qga then closes. There is no
    /// way to write more once the process is running.
    public var input: Data?
    /// Whether stdout/stderr are captured for retrieval. With this off the
    /// result carries only the exit status.
    public var captureOutput: Bool

    public init(
        path: String,
        arguments: [String] = [],
        environment: [String] = [],
        input: Data? = nil,
        captureOutput: Bool = true
    ) {
        self.path = path
        self.arguments = arguments
        self.environment = environment
        self.input = input
        self.captureOutput = captureOutput
    }
}

/// The outcome of a `GuestCommand` that ran to completion in the guest.
public struct GuestCommandResult: Sendable, Equatable {
    /// The process's exit status, or nil when it was killed by a signal.
    public let exitCode: Int?
    /// The signal that killed the process, or nil when it exited normally.
    public let signal: Int?
    public let stdout: Data
    public let stderr: Data
    /// Whether qga's in-guest capture cap cut the stream short. The exit status
    /// is still accurate; only the captured bytes are incomplete.
    public let stdoutTruncated: Bool
    public let stderrTruncated: Bool

    public init(
        exitCode: Int?,
        signal: Int?,
        stdout: Data,
        stderr: Data,
        stdoutTruncated: Bool = false,
        stderrTruncated: Bool = false
    ) {
        self.exitCode = exitCode
        self.signal = signal
        self.stdout = stdout
        self.stderr = stderr
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
    }
}

/// What a guest's agent reports about itself and which RPCs it will answer
/// (`guest-info`).
///
/// Worth querying before an exec: distros filter the RPC set, and the RHEL
/// family ships an `--allow-rpcs` allowlist with `guest-exec` left out, so
/// exec-capability is a property of the image, not of Strato (issue #803).
/// Attempting it anyway is not harmful — it comes back as
/// `QGAClient.QGAError.commandUnavailable` — but asking first lets a caller
/// report "this guest can't run commands" instead of failing an operation.
public struct GuestAgentCapabilities: Sendable, Equatable {
    /// The guest agent's version string (e.g. `10.2.1`).
    public let version: String
    /// Commands the agent will answer.
    public let enabledCommands: Set<String>
    /// Commands the agent knows but has been configured to refuse.
    public let disabledCommands: Set<String>

    public init(version: String, enabledCommands: Set<String>, disabledCommands: Set<String>) {
        self.version = version
        self.enabledCommands = enabledCommands
        self.disabledCommands = disabledCommands
    }

    /// Whether this guest can run commands. Both halves of the spawn-and-poll
    /// pair are required: an agent that spawned a process it then refused to
    /// report on would leak guest processes with no way to collect a result.
    public var supportsCommandExecution: Bool {
        enabledCommands.contains("guest-exec") && enabledCommands.contains("guest-exec-status")
    }
}
