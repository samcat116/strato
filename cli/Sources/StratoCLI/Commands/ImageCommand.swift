import ArgumentParser
import Foundation
import StratoAPIClient
import StratoCLICore

struct ImageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "image",
        abstract: "Manage VM images (project-scoped).",
        subcommands: [List.self, Get.self, Delete.self],
        defaultSubcommand: List.self
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List images in a project.")

        @OptionGroup var global: GlobalOptions

        @Option(name: .long, help: "Project id (defaults to the context's project).")
        var project: String?

        func run() async throws {
            try await runHandlingCLIErrors {
                let environment = try CLIEnvironment.resolve(global)
                let projectID = try resolveProject(project, environment: environment)
                let images = try await environment.makeClient()
                    .listImages(path: .init(projectID: projectID), query: .init(limit: listPageLimit))
                    .ok.body.json.items
                try printResult(images, format: global.output) {
                    var table = TextTable(
                        headers: ["id", "name", "format", "arch", "size", "status", "created"])
                    for image in images {
                        table.addRow([
                            image.id ?? "", image.name, image.format?.rawValue ?? "—",
                            image.architecture.rawValue, image.sizeFormatted ?? "—",
                            image.status.rawValue, formatDate(image.createdAt),
                        ])
                    }
                    return table
                }
            }
        }
    }

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show one image.")

        @OptionGroup var global: GlobalOptions

        @Argument(help: "Image id.")
        var id: String

        @Option(name: .long, help: "Project id (defaults to the context's project).")
        var project: String?

        func run() async throws {
            try await runHandlingCLIErrors {
                let environment = try CLIEnvironment.resolve(global)
                let projectID = try resolveProject(project, environment: environment)
                let image = try await environment.makeClient()
                    .getImage(path: .init(projectID: projectID, imageID: id)).ok.body.json
                try printResult(image, format: global.output) {
                    var table = TextTable(headers: ["field", "value"])
                    table.addRow(["id", image.id ?? ""])
                    table.addRow(["name", image.name])
                    table.addRow(["description", image.description])
                    table.addRow(["format", image.format?.rawValue ?? "—"])
                    table.addRow(["architecture", image.architecture.rawValue])
                    table.addRow(["size", image.sizeFormatted ?? "—"])
                    table.addRow(["status", image.status.rawValue])
                    table.addRow(["created", formatDate(image.createdAt)])
                    return table
                }
            }
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete an image.")

        @OptionGroup var global: GlobalOptions

        @Argument(help: "Image id.")
        var id: String

        @Option(name: .long, help: "Project id (defaults to the context's project).")
        var project: String?

        func run() async throws {
            try await runHandlingCLIErrors {
                let environment = try CLIEnvironment.resolve(global)
                let projectID = try resolveProject(project, environment: environment)
                _ = try await environment.makeClient()
                    .deleteImage(path: .init(projectID: projectID, imageID: id)).noContent
                print("Image \(id) deleted.")
            }
        }
    }
}
