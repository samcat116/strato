import ArgumentParser
import Foundation
import StratoAPIClient
import StratoCLICore

struct VolumeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "volume",
        abstract: "Manage storage volumes.",
        subcommands: [List.self, Get.self, Create.self, Delete.self],
        defaultSubcommand: List.self
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List volumes.")

        @OptionGroup var global: GlobalOptions

        func run() async throws {
            try await runHandlingCLIErrors {
                let environment = try CLIEnvironment.resolve(global)
                let volumes = try await environment.makeClient()
                    .listVolumes(query: .init(limit: listPageLimit)).ok.body.json.items
                try printResult(volumes, format: global.output) {
                    var table = TextTable(headers: ["id", "name", "size", "type", "status", "attached vm"])
                    for volume in volumes {
                        table.addRow([
                            volume.id ?? "", volume.name,
                            volume.sizeFormatted, volume.volumeType.rawValue,
                            volume.status.rawValue, volume.vmId ?? "",
                        ])
                    }
                    return table
                }
            }
        }
    }

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show one volume.")

        @OptionGroup var global: GlobalOptions

        @Argument(help: "Volume id.")
        var id: String

        func run() async throws {
            try await runHandlingCLIErrors {
                let environment = try CLIEnvironment.resolve(global)
                let volume = try await environment.makeClient()
                    .getVolume(path: .init(volumeId: id)).ok.body.json
                try printResult(volume, format: global.output) {
                    var table = TextTable(headers: ["field", "value"])
                    table.addRow(["id", volume.id ?? ""])
                    table.addRow(["name", volume.name])
                    table.addRow(["description", volume.description])
                    table.addRow(["size", volume.sizeFormatted])
                    table.addRow(["format", volume.format.rawValue])
                    table.addRow(["type", volume.volumeType.rawValue])
                    table.addRow(["status", volume.status.rawValue])
                    table.addRow(["attached vm", volume.vmId ?? ""])
                    table.addRow(["created", formatDate(volume.createdAt)])
                    return table
                }
            }
        }
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a volume.")

        @OptionGroup var global: GlobalOptions

        @Argument(help: "Volume name.")
        var name: String

        @Option(name: .long, help: "Size in GB.")
        var size: Int

        @Option(name: .long, help: "Project id (defaults to the context's project).")
        var project: String?

        @Option(name: .long, help: "Description.")
        var description: String?

        @Flag(name: .long, help: "Return immediately instead of waiting for the volume to converge.")
        var noWait = false

        func run() async throws {
            try await runHandlingCLIErrors {
                let env = try CLIEnvironment.resolve(global)
                let client = env.makeClient()
                // Accepted, not created: the agent still has to place and
                // materialize it (backend STR-148).
                let accepted = try await client.createVolume(
                    body: .json(
                        .init(
                            name: name, description: description,
                            projectId: project ?? env.context.project, sizeGB: size))
                ).accepted.body.json
                try await handleMutation(
                    AcceptedMutation(id: accepted.mutationId), client: client, noWait: noWait,
                    format: global.output,
                    successMessage: "Volume '\(name)' created (\(accepted.resource.id ?? "")).")
            }
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a volume.")

        @OptionGroup var global: GlobalOptions

        @Argument(help: "Volume id.")
        var id: String

        @Flag(name: .long, help: "Return immediately instead of waiting for the volume to be removed.")
        var noWait = false

        func run() async throws {
            try await runHandlingCLIErrors {
                let env = try CLIEnvironment.resolve(global)
                let client = env.makeClient()
                // A delete's success is the row's absence, so it is followed
                // through the operations façade with the mutation id rather
                // than by refetching the volume (backend STR-148).
                let accepted = try await client.deleteVolume(path: .init(volumeId: id)).accepted.body.json
                try await handleMutation(
                    AcceptedMutation(id: accepted.mutationId), client: client, noWait: noWait,
                    format: global.output, successMessage: "Volume \(id) deleted.")
            }
        }
    }
}
