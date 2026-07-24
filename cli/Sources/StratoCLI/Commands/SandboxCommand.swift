import ArgumentParser
import Foundation
import StratoCLICore

struct SandboxCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sandbox",
        abstract: "Manage sandboxes (OCI-image microVMs).",
        subcommands: [List.self, Get.self, Create.self, Delete.self, Start.self, Stop.self, Restart.self],
        defaultSubcommand: List.self
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List sandboxes.")

        @OptionGroup var global: GlobalOptions

        func run() async throws {
            try await runHandlingCLIErrors {
                let environment = try CLIEnvironment.resolve(global)
                let page: Page<Sandbox> = try await environment.makeClient()
                    .get("/api/sandboxes", query: [("limit", String(listPageLimit))])
                let sandboxes = page.items
                try printResult(sandboxes, format: global.output) {
                    var table = TextTable(headers: ["id", "name", "image", "status", "expires", "created"])
                    for sandbox in sandboxes {
                        table.addRow([
                            formatUUID(sandbox.id), sandbox.name, sandbox.image, sandbox.status,
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
                let sandbox: Sandbox = try await environment.makeClient().get("/api/sandboxes/\(id)")
                try printResult(sandbox, format: global.output) {
                    var table = TextTable(headers: ["field", "value"])
                    table.addRow(["id", formatUUID(sandbox.id)])
                    table.addRow(["name", sandbox.name])
                    table.addRow(["image", sandbox.image])
                    table.addRow(["status", sandbox.status])
                    table.addRow(["environment", sandbox.environment ?? ""])
                    table.addRow(["cpus", sandbox.cpus.map(String.init) ?? ""])
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
                let request = CreateSandboxRequest(
                    name: name, image: image, projectId: project ?? env.context.project,
                    environment: environment, cpus: cpus, memory: memory, ttlSeconds: ttl
                )
                let operation: ResourceOperation = try await client.post("/api/sandboxes", body: request)
                try await handleOperation(
                    operation, client: client, noWait: noWait, format: global.output,
                    successMessage: "Sandbox '\(name)' created.")
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
                let operation: ResourceOperation = try await client.delete("/api/sandboxes/\(id)")
                try await handleOperation(
                    operation, client: client, noWait: noWait, format: global.output,
                    successMessage: "Sandbox \(id) deleted.")
            }
        }
    }

    struct Start: SandboxActionCommand {
        static let configuration = CommandConfiguration(abstract: "Start a sandbox.")
        static let verb = "start"
        static let pastTense = "started"
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Sandbox id.") var id: String
        @Flag(name: .long, help: "Return immediately instead of waiting.") var noWait = false
    }

    struct Stop: SandboxActionCommand {
        static let configuration = CommandConfiguration(abstract: "Stop a sandbox.")
        static let verb = "stop"
        static let pastTense = "stopped"
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Sandbox id.") var id: String
        @Flag(name: .long, help: "Return immediately instead of waiting.") var noWait = false
    }

    struct Restart: SandboxActionCommand {
        static let configuration = CommandConfiguration(abstract: "Restart a sandbox.")
        static let verb = "restart"
        static let pastTense = "restarted"
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Sandbox id.") var id: String
        @Flag(name: .long, help: "Return immediately instead of waiting.") var noWait = false
    }
}

protocol SandboxActionCommand: AsyncParsableCommand {
    static var verb: String { get }
    static var pastTense: String { get }
    var global: GlobalOptions { get }
    var id: String { get }
    var noWait: Bool { get }
}

extension SandboxActionCommand {
    func run() async throws {
        try await runHandlingCLIErrors {
            let env = try CLIEnvironment.resolve(global)
            let client = env.makeClient()
            let operation: ResourceOperation = try await client.post("/api/sandboxes/\(id)/\(Self.verb)")
            try await handleOperation(
                operation, client: client, noWait: noWait, format: global.output,
                successMessage: "Sandbox \(id) \(Self.pastTense).")
        }
    }
}
