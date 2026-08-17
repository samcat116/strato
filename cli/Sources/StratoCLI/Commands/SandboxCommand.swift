import ArgumentParser
import Foundation
import StratoAPIClient
import StratoCLICore

struct SandboxCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sandbox",
        abstract: "Manage sandboxes (OCI-image microVMs).",
        subcommands: [
            List.self, Get.self, Create.self, Delete.self, Start.self, Stop.self, Restart.self,
            Exec.self, Attach.self,
        ],
        defaultSubcommand: List.self
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List sandboxes.")

        @OptionGroup var global: GlobalOptions

        func run() async throws {
            try await runHandlingCLIErrors {
                let environment = try CLIEnvironment.resolve(global)
                let sandboxes = try await environment.makeClient()
                    .listSandboxes(query: .init(limit: listPageLimit)).ok.body.json.items
                try printResult(sandboxes, format: global.output) {
                    var table = TextTable(headers: ["id", "name", "image", "status", "expires", "created"])
                    for sandbox in sandboxes {
                        table.addRow([
                            sandbox.id ?? "", sandbox.name, sandbox.image, sandbox.status.rawValue,
                            formatDate(sandbox.expiresAt), formatDate(sandbox.createdAt),
                        ])
                    }
                    return table
                }
            }
        }
    }

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show one sandbox.")

        @OptionGroup var global: GlobalOptions

        @Argument(help: "Sandbox id.")
        var id: String

        func run() async throws {
            try await runHandlingCLIErrors {
                let environment = try CLIEnvironment.resolve(global)
                let sandbox = try await environment.makeClient()
                    .getSandbox(path: .init(sandboxID: id)).ok.body.json
                try printResult(sandbox, format: global.output) {
                    var table = TextTable(headers: ["field", "value"])
                    table.addRow(["id", sandbox.id ?? ""])
                    table.addRow(["name", sandbox.name])
                    table.addRow(["image", sandbox.image])
                    table.addRow(["status", sandbox.status.rawValue])
                    table.addRow(["environment", sandbox.environment])
                    table.addRow(["cpus", String(sandbox.cpus)])
                    table.addRow(["exit code", sandbox.exitCode.map(String.init) ?? ""])
                    table.addRow(["expires", formatDate(sandbox.expiresAt)])
                    table.addRow(["created", formatDate(sandbox.createdAt)])
                    return table
                }
            }
        }
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a sandbox from an OCI image.")

        @OptionGroup var global: GlobalOptions

        @Argument(help: "Sandbox name.")
        var name: String

        @Option(name: .long, help: "OCI image reference, e.g. ghcr.io/acme/worker:v3.")
        var image: String

        @Option(name: .long, help: "Project id (defaults to the context's project).")
        var project: String?

        @Option(name: .long, help: "Environment name.")
        var environment: String?

        @Option(name: .long, help: "vCPU count.")
        var cpus: Int?

        @Option(name: .long, help: "Guest memory in bytes.")
        var memory: Int64?

        @Option(name: .long, help: "Lifetime budget in seconds (auto-delete).")
        var ttl: Int?

        @Flag(name: .long, help: "Return immediately instead of waiting for the operation.")
        var noWait = false

        func run() async throws {
            try await runHandlingCLIErrors {
                let env = try CLIEnvironment.resolve(global)
                let client = env.makeClient()
                let accepted = try await client.createSandbox(
                    body: .json(
                        .init(
                            name: name, image: image,
                            projectId: try resolveProject(project, environment: env),
                            environment: environment, cpus: cpus, memory: memory, ttlSeconds: ttl))
                ).accepted.body.json
                try await handleMutation(
                    AcceptedMutation(id: accepted.mutationId), client: client, noWait: noWait,
                    format: global.output, successMessage: "Sandbox '\(name)' created.")
            }
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a sandbox.")

        @OptionGroup var global: GlobalOptions

        @Argument(help: "Sandbox id.")
        var id: String

        @Flag(name: .long, help: "Return immediately instead of waiting for the operation.")
        var noWait = false

        func run() async throws {
            try await runHandlingCLIErrors {
                let env = try CLIEnvironment.resolve(global)
                let client = env.makeClient()
                let accepted = try await client.deleteSandbox(path: .init(sandboxID: id))
                    .accepted.body.json
                try await handleMutation(
                    AcceptedMutation(id: accepted.mutationId), client: client, noWait: noWait,
                    format: global.output, successMessage: "Sandbox \(id) deleted.")
            }
        }
    }

    struct Start: ResourceActionCommand {
        static let configuration = CommandConfiguration(abstract: "Start a sandbox.")
        static let resourceLabel = "Sandbox"
        static let action: ResourceAction = {
            AcceptedMutation(
                id: try await $0.startSandbox(path: .init(sandboxID: $1)).accepted.body.json.mutationId)
        }
        static let pastTense = "started"
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Sandbox id.") var id: String
        @Flag(name: .long, help: "Return immediately instead of waiting.") var noWait = false
    }

    struct Stop: ResourceActionCommand {
        static let configuration = CommandConfiguration(abstract: "Stop a sandbox.")
        static let resourceLabel = "Sandbox"
        static let action: ResourceAction = {
            AcceptedMutation(
                id: try await $0.stopSandbox(path: .init(sandboxID: $1)).accepted.body.json.mutationId)
        }
        static let pastTense = "stopped"
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Sandbox id.") var id: String
        @Flag(name: .long, help: "Return immediately instead of waiting.") var noWait = false
    }

    struct Restart: ResourceActionCommand {
        static let configuration = CommandConfiguration(abstract: "Restart a sandbox.")
        static let resourceLabel = "Sandbox"
        static let action: ResourceAction = {
            AcceptedMutation(
                id: try await $0.restartSandbox(path: .init(sandboxID: $1)).accepted.body.json.mutationId)
        }
        static let pastTense = "restarted"
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Sandbox id.") var id: String
        @Flag(name: .long, help: "Return immediately instead of waiting.") var noWait = false
    }

    struct Exec: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run a non-interactive command inside a sandbox.")

        @OptionGroup var connection: ConnectionOptions

        @Argument(help: "Sandbox id.")
        var id: String

        @Option(name: .long, help: "Environment override in KEY=VALUE form; repeatable.")
        var env: [String] = []

        @Option(name: .long, help: "Working directory inside the sandbox.")
        var workdir: String?

        @Argument(parsing: .postTerminator, help: "Command and arguments to execute after '--'.")
        var command: [String] = []

        func run() async throws {
            var remoteExitCode: Int32 = 0
            try await runHandlingCLIErrors {
                guard !command.isEmpty else {
                    throw CLIError.config(
                        "Missing command. Usage: strato sandbox exec <sandbox-id> -- <command> [args...]")
                }
                let environmentOverrides = try parseGuestExecEnvironment(env)
                let environment = try CLIEnvironment.resolve(connection)
                let authenticated = environment.makeAuthenticatedSession()
                let input =
                    standardInputIsTerminal()
                    ? nil
                    : fileHandleDataStream(.standardInput)
                let invocation = GuestExecInvocation(
                    sandboxID: id,
                    command: command,
                    environment: environmentOverrides,
                    workingDirectory: workdir,
                    tty: false,
                    outputMode: .multiplexed,
                    input: input,
                    closeStdinWhenInputEnds: true
                )
                let session = GuestExecSessionClient(
                    serverURL: environment.serverURL,
                    client: authenticated.client,
                    credentials: authenticated.credentials)
                remoteExitCode = try await session.run(invocation) { output in
                    switch output {
                    case .stdout(let data): FileHandle.standardOutput.write(data)
                    case .stderr(let data): FileHandle.standardError.write(data)
                    }
                }
            }
            if remoteExitCode != 0 {
                throw ExitCode(remoteExitCode)
            }
        }
    }

    struct Attach: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Open a fresh interactive shell inside a sandbox.")

        @OptionGroup var connection: ConnectionOptions

        @Argument(help: "Sandbox id.")
        var id: String

        @Option(name: .long, help: "Shell executable inside the sandbox.")
        var shell = "/bin/sh"

        @Option(name: .long, help: "Environment override in KEY=VALUE form; repeatable.")
        var env: [String] = []

        @Option(name: .long, help: "Working directory inside the sandbox.")
        var workdir: String?

        private enum RunOutcome: Sendable {
            case exited(Int32)
            case terminated(Int32)
        }

        func run() async throws {
            var remoteExitCode: Int32 = 0
            var terminationSignal: Int32?
            try await runHandlingCLIErrors {
                guard !shell.isEmpty else {
                    throw CLIError.config("Sandbox attach requires a non-empty --shell value.")
                }
                let environmentOverrides = try parseGuestExecEnvironment(env)
                let terminal = try RawTerminal()
                let initialSize = try terminal.size()
                let environment = try CLIEnvironment.resolve(connection)
                let authenticated = environment.makeAuthenticatedSession()
                let outcome = try await withRawTerminal(terminal) {
                    let resizeMonitor = TerminalResizeMonitor(terminal: terminal)
                    let terminationMonitor = TerminalTerminationMonitor()
                    defer {
                        withExtendedLifetime(resizeMonitor) {}
                        withExtendedLifetime(terminationMonitor) {}
                    }

                    let invocation = GuestExecInvocation(
                        sandboxID: id,
                        command: [shell],
                        environment: environmentOverrides,
                        workingDirectory: workdir,
                        tty: true,
                        initialSize: initialSize,
                        outputMode: .raw,
                        input: fileHandleDataStream(.standardInput),
                        resizes: resizeMonitor.sizes
                    )
                    let session = GuestExecSessionClient(
                        serverURL: environment.serverURL,
                        client: authenticated.client,
                        credentials: authenticated.credentials)
                    return try await withThrowingTaskGroup(of: RunOutcome.self) { group in
                        group.addTask {
                            let exitCode = try await session.run(invocation) { output in
                                switch output {
                                case .stdout(let data), .stderr(let data):
                                    FileHandle.standardOutput.write(data)
                                }
                            }
                            return .exited(exitCode)
                        }
                        group.addTask {
                            for await signalNumber in terminationMonitor.signals {
                                return .terminated(signalNumber)
                            }
                            return .terminated(0)
                        }
                        guard let first = try await group.next() else {
                            throw CLIError.guestExec("Sandbox attach ended without a result.")
                        }
                        group.cancelAll()
                        return first
                    }
                }
                switch outcome {
                case .exited(let code): remoteExitCode = code
                case .terminated(let signalNumber): terminationSignal = signalNumber
                }
            }
            if let terminationSignal { reraiseTerminationSignal(terminationSignal) }
            if remoteExitCode != 0 {
                throw ExitCode(remoteExitCode)
            }
        }
    }
}
