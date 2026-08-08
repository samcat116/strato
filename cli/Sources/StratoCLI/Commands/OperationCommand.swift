import ArgumentParser
import Foundation
import StratoAPIClient
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
                let operation = try await environment.makeClient()
                    .getOperation(path: .init(operationID: id)).ok.body.json
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
                let final = try await OperationWaiter(timeout: timeout)
                    .wait(for: AcceptedMutation(id: id), client: client)
                try printOperation(final, format: global.output)
            }
        }
    }
}

private func printOperation(_ operation: ResourceOperation, format: OutputFormat) throws {
    switch format {
    case .table:
        var table = TextTable(headers: ["field", "value"])
        table.addRow(["id", operation.id ?? ""])
        table.addRow(["kind", operation.kind.rawValue])
        table.addRow(["status", operation.status.rawValue])
        table.addRow(["resource", "\(operation.resourceKind.rawValue) \(operation.resourceId)"])
        table.addRow(["error", operation.error ?? ""])
        table.addRow(["created", formatDate(operation.createdAt)])
        table.addRow(["completed", formatDate(operation.completedAt)])
        print(table.render())
    case .json:
        print(try renderJSON(operation))
    }
}
