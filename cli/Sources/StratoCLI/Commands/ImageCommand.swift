import ArgumentParser
import Foundation
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
                let page: Page<Image> = try await environment.makeClient()
                    .get("/api/projects/\(projectID)/images", query: [("limit", String(listPageLimit))])
                let images = page.items
                try printResult(images, format: global.output) {
                    var table = TextTable(
                        headers: ["id", "name", "format", "arch", "size", "status", "created"])
                    for image in images {
                        table.addRow([
                            formatUUID(image.id), image.name, image.format ?? "",
                            image.architecture ?? "", image.sizeFormatted ?? "",
                            image.status ?? "", formatDate(image.createdAt),
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
                let image: Image = try await environment.makeClient()
                    .get("/api/projects/\(projectID)/images/\(id)")
                try printResult(image, format: global.output) {
                    var table = TextTable(headers: ["field", "value"])
                    table.addRow(["id", formatUUID(image.id)])
                    table.addRow(["name", image.name])
                    table.addRow(["description", image.description ?? ""])
                    table.addRow(["format", image.format ?? ""])
                    table.addRow(["architecture", image.architecture ?? ""])
                    table.addRow(["size", image.sizeFormatted ?? ""])
                    table.addRow(["status", image.status ?? ""])
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
                try await environment.makeClient()
                    .deleteExpectingNoContent("/api/projects/\(projectID)/images/\(id)")
                print("Image \(id) deleted.")
            }
        }
    }
}
