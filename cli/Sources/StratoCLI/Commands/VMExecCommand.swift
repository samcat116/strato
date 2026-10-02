import ArgumentParser
import Foundation
import StratoCLICore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension VMCommand {
    struct Exec: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run a command or open a shell inside a virtual machine.")

        @OptionGroup var connection: ConnectionOptions
        @Argument(help: "VM id.") var id: String
        @Option(name: .long, help: "Environment override in KEY=VALUE form; repeatable.")
        var env: [String] = []
        @Option(name: .long, help: "Working directory inside the VM.") var workdir: String?
        @Flag(name: .long, help: "Require a PTY (stdin and stdout must be terminals).") var tty = false
        @Flag(name: .long, help: "Disable the PTY and keep stdout and stderr separate.") var noTTY = false
        @Argument(parsing: .postTerminator, help: "Command and arguments after '--'; defaults to /bin/sh.")
        var command: [String] = []

        private enum RunOutcome: Sendable {
            case exited(Int32)
            case terminated(Int32)
        }

        func run() async throws {
            var remoteExitCode: Int32 = 0
            var terminationSignal: Int32?
            try await runHandlingCLIErrors {
                let stdinIsTerminal = standardInputIsTerminal()
                let plan = try VMExecPlan(
                    command: command, environment: env, forceTTY: tty, noTTY: noTTY,
                    stdinIsTerminal: stdinIsTerminal, stdoutIsTerminal: standardOutputIsTerminal())
                let environment = try CLIEnvironment.resolve(connection)
                let authenticated = environment.makeAuthenticatedSession()
                let session = GuestExecSessionClient(
                    serverURL: environment.serverURL, client: authenticated.client,
                    credentials: authenticated.credentials)
                let terminal = plan.tty ? try RawTerminal() : nil
                let initialSize = try terminal?.size()
                // Raw mode disables ISIG, so typed Ctrl-C remains guest input.
                // External SIGINT still needs cleanup. Install the monitor before
                // entering raw mode so interruption cannot leave the terminal raw.
                let terminationMonitor = TerminalTerminationMonitor(
                    signalNumbers: [SIGINT, SIGTERM, SIGHUP])
                defer { withExtendedLifetime(terminationMonitor) {} }
                let operation = {
                    let resizeMonitor = terminal.map { TerminalResizeMonitor(terminal: $0) }
                    defer { withExtendedLifetime(resizeMonitor) {} }
                    let invocation = GuestExecInvocation(
                        resource: .virtualMachine(id), command: plan.command,
                        environment: plan.environment, workingDirectory: workdir,
                        tty: plan.tty, initialSize: initialSize,
                        outputMode: plan.tty ? .raw : .multiplexed,
                        input: fileHandleDataStream(.standardInput),
                        closeStdinWhenInputEnds: true, resizes: resizeMonitor?.sizes)
                    return try await withThrowingTaskGroup(of: RunOutcome.self) { group in
                        group.addTask {
                            let code = try await session.run(invocation) { output in
                                switch output {
                                case .stdout(let data): FileHandle.standardOutput.write(data)
                                case .stderr(let data): FileHandle.standardError.write(data)
                                }
                            }
                            return .exited(code)
                        }
                        group.addTask {
                            for await signalNumber in terminationMonitor.signals {
                                return .terminated(signalNumber)
                            }
                            return .terminated(0)
                        }
                        guard let result = try await group.next() else {
                            throw CLIError.guestExec("VM exec ended without a result.")
                        }
                        group.cancelAll()
                        return result
                    }
                }
                let outcome: RunOutcome
                if let terminal {
                    outcome = try await withRawTerminal(terminal, operation: operation)
                } else {
                    outcome = try await operation()
                }
                switch outcome {
                case .exited(let code): remoteExitCode = code
                case .terminated(let signalNumber): terminationSignal = signalNumber
                }
            }
            if let terminationSignal { reraiseTerminationSignal(terminationSignal) }
            if remoteExitCode != 0 { throw ExitCode(remoteExitCode) }
        }
    }
}
