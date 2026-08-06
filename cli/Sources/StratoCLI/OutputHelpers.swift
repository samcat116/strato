import ArgumentParser
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

/// Handles a 202 mutation response: waits for the mutation to finish (default)
/// or prints its id and returns (`--no-wait`). A failed mutation throws
/// `CLIError.operationFailed`, which exits nonzero.
///
/// Both `202` shapes funnel through here (STR-147): the operation record the
/// imperative verbs still return, and the `mutationId` a lifecycle mutation
/// answers with alongside the resource. Waiting goes through the operations
/// endpoint either way — which is also what makes `strato vm delete --wait`
/// keep working, since a deleted VM has nothing left to poll.
func handleMutation(
    _ accepted: AcceptedMutation,
    client: any APIProtocol,
    noWait: Bool,
    format: OutputFormat,
    successMessage: String
) async throws {
    if noWait {
        switch format {
        case .table:
            print("Accepted: operation \(accepted.id).")
            print("Track it with 'strato operation wait \(accepted.id)'.")
        case .json:
            if let seed = accepted.seed {
                print(try renderJSON(seed))
            } else {
                print(try renderJSON(["operationId": accepted.id]))
            }
        }
        return
    }

    let final = try await OperationWaiter().wait(for: accepted, client: client)
    switch format {
    case .table:
        print(successMessage)
    case .json:
        print(try renderJSON(final))
    }
}

/// One lifecycle action on a resource, as the generated operation that
/// performs it. Each verb is its own operation in the spec, so the action is a
/// function rather than a path fragment.
typealias ResourceAction = @Sendable (any APIProtocol, String) async throws -> AcceptedMutation

/// One lifecycle action (start/stop/reboot/...) as a reusable command. A
/// conformer supplies the generated operation to call plus the wording of the
/// success message; the shared `run()` does the rest.
protocol ResourceActionCommand: AsyncParsableCommand {
    /// The resource as it appears in the success message, e.g. "VM".
    static var resourceLabel: String { get }
    static var action: ResourceAction { get }
    static var pastTense: String { get }
    var global: GlobalOptions { get }
    var id: String { get }
    var noWait: Bool { get }
}

extension ResourceActionCommand {
    func run() async throws {
        try await runHandlingCLIErrors {
            let env = try CLIEnvironment.resolve(global)
            let client = env.makeClient()
            let accepted = try await Self.action(client, id)
            try await handleMutation(
                accepted, client: client, noWait: noWait, format: global.output,
                successMessage: "\(Self.resourceLabel) \(id) \(Self.pastTense).")
        }
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
