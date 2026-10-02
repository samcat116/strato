import Foundation

/// Resolves terminal policy before creating streams or minting a session.
public struct VMExecPlan: Sendable {
    public let command: [String]
    public let tty: Bool
    public let environment: [String: String]?

    public init(
        command: [String], environment: [String],
        forceTTY: Bool, noTTY: Bool, stdinIsTerminal: Bool, stdoutIsTerminal: Bool
    ) throws {
        guard !(forceTTY && noTTY) else {
            throw CLIError.config("--tty and --no-tty cannot be used together.")
        }
        guard !forceTTY || (stdinIsTerminal && stdoutIsTerminal) else {
            throw CLIError.config("VM exec --tty requires terminal stdin and stdout.")
        }
        self.command = command.isEmpty ? ["/bin/sh"] : command
        self.tty = !noTTY && stdinIsTerminal && stdoutIsTerminal
        self.environment = try parseGuestExecEnvironment(environment)
    }
}
