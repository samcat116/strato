import ArgumentParser
import Foundation
import StratoAPIClient
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
}
