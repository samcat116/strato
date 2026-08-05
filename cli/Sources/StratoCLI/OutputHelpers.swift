import Foundation
import StratoAPIClient
import StratoCLICore

/// Prints a decoded API value as a table (built by `table`) or JSON,
/// depending on `-o`.
func printResult(_ value: some Encodable, format: OutputFormat, table: () -> TextTable) throws {
    switch format {
    case .table:
        print(table().render())
    case .json:
        print(try renderJSON(value))
    }
}

func formatDate(_ date: Date?) -> String {
    guard let date else { return "" }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    formatter.timeZone = .current
    return formatter.string(from: date)
}

/// Handles a 202 mutation response: waits for the operation to finish
/// (default) or prints its id and returns (`--no-wait`). A failed operation
/// throws `CLIError.operationFailed`, which exits nonzero.
func handleOperation(
    _ operation: ResourceOperation,
    client: any APIProtocol,
    noWait: Bool,
    format: OutputFormat,
    successMessage: String
) async throws {
    if noWait {
        switch format {
        case .table:
            let id = operation.id ?? "unknown"
            print("Accepted: operation \(id) (\(operation.kind.rawValue)) is \(operation.status.rawValue).")
            print("Track it with 'strato operation wait \(id)'.")
        case .json:
            print(try renderJSON(operation))
        }
        return
    }

    let final = try await OperationWaiter().wait(for: operation, client: client)
    switch format {
    case .table:
        print(successMessage)
    case .json:
        print(try renderJSON(final))
    }
}

/// Resolves the project for project-scoped commands: explicit flag first,
/// then the context's default.
func resolveProject(_ flag: String?, environment: CLIEnvironment) throws -> String {
    if let flag { return flag }
    if let project = environment.context.project { return project }
    throw CLIError.config(
        "No project specified. Pass --project <id> or set one on the context with "
            + "'strato context set \(environment.contextName) --project <id>'.")
}
