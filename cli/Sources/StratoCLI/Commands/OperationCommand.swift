import ArgumentParser
import Foundation
import StratoCLICore

struct OperationCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "operation",
        abstract: "Inspect and wait on async resource operations.",
        subcommands: [Get.self, Wait.self]
    )

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show an operation's current state.")

        @OptionGroup var global: GlobalOptions

        @Argument(help: "Operation id.")
        var id: String

        func run() async throws {
            try await runHandlingCLIErrors {
                let environment = try CLIEnvironment.resolve(global)
                let operation: ResourceOperation = try await environment.makeClient().get("/api/operations/\(id)")
                try printOperation(operation, format: global.output)
            }
        }
    }

    struct Wait: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Wait for an operation to reach a terminal state.")

        @OptionGroup var global: GlobalOptions

        @Argument(help: "Operation id.")
        var id: String

        @Option(name: .long, help: "Give up after this many seconds.")
        var timeout: Double = 600

        func run() async throws {
            try await runHandlingCLIErrors {
                let environment = try CLIEnvironment.resolve(global)
                let client = environment.makeClient()
                let operation: ResourceOperation = try await client.get("/api/operations/\(id)")
                let final = try await OperationWaiter(timeout: timeout).wait(for: operation, client: client)
                try printOperation(final, format: global.output)
            }
        }
    }
}

private func printOperation(_ operation: ResourceOperation, format: OutputFormat) throws {
    switch format {
    case .table:
        var table = TextTable(headers: ["field", "value"])
        table.addRow(["id", formatUUID(operation.id)])
        table.addRow(["kind", operation.kind])
        table.addRow(["status", operation.status])
        table.addRow(["resource", "\(operation.resourceKind ?? "") \(formatUUID(operation.resourceId))"])
        table.addRow(["error", operation.error ?? ""])
        table.addRow(["created", formatDate(operation.createdAt)])
        table.addRow(["completed", formatDate(operation.completedAt)])
        print(table.render())
    case .json:
        print(try renderJSON(operation))
    }
}
