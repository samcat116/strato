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

        func run() async throws {
            try await runHandlingCLIErrors {
                let env = try CLIEnvironment.resolve(global)
                let volume = try await env.makeClient().createVolume(
                    body: .json(
                        .init(
                            name: name, description: description,
                            projectId: project ?? env.context.project, sizeGB: size))
                ).ok.body.json
                switch global.output {
                case .table:
                    print("Volume '\(volume.name)' created (\(volume.id ?? "")).")
                case .json:
                    print(try renderJSON(volume))
                }
            }
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a volume.")

        @OptionGroup var global: GlobalOptions

        @Argument(help: "Volume id.")
        var id: String

        func run() async throws {
            try await runHandlingCLIErrors {
                let environment = try CLIEnvironment.resolve(global)
                _ = try await environment.makeClient().deleteVolume(path: .init(volumeId: id)).noContent
                print("Volume \(id) deleted.")
            }
        }
    }
}
