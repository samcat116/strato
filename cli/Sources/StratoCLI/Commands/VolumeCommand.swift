import ArgumentParser
import Foundation
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
                let page: Page<Volume> = try await environment.makeClient()
                    .get("/api/volumes", query: [("limit", String(listPageLimit))])
                let volumes = page.items
                try printResult(volumes, format: global.output) {
                    var table = TextTable(headers: ["id", "name", "size", "type", "status", "attached vm"])
                    for volume in volumes {
                        table.addRow([
                            formatUUID(volume.id), volume.name,
                            volume.sizeFormatted ?? "", volume.volumeType ?? "",
                            volume.status ?? "", formatUUID(volume.vmId),
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
                let volume: Volume = try await environment.makeClient().get("/api/volumes/\(id)")
                try printResult(volume, format: global.output) {
                    var table = TextTable(headers: ["field", "value"])
                    table.addRow(["id", formatUUID(volume.id)])
                    table.addRow(["name", volume.name])
                    table.addRow(["description", volume.description ?? ""])
                    table.addRow(["size", volume.sizeFormatted ?? ""])
                    table.addRow(["format", volume.format ?? ""])
                    table.addRow(["type", volume.volumeType ?? ""])
                    table.addRow(["status", volume.status ?? ""])
                    table.addRow(["attached vm", formatUUID(volume.vmId)])
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
                let request = CreateVolumeRequest(
                    name: name, description: description,
                    projectId: project ?? env.context.project,
                    sizeGB: size, format: nil, volumeType: nil
                )
                let volume: Volume = try await env.makeClient().post("/api/volumes", body: request)
                switch global.output {
                case .table:
                    print("Volume '\(volume.name)' created (\(formatUUID(volume.id))).")
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
                try await environment.makeClient().deleteExpectingNoContent("/api/volumes/\(id)")
                print("Volume \(id) deleted.")
            }
        }
    }
}
