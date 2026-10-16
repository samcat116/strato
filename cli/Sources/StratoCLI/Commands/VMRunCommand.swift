import ArgumentParser
import Foundation
import StratoAPIClient
import StratoCLICore

extension VMCommand {
    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run a recorded command across a confirmed VM selector.")
        @OptionGroup var global: GlobalOptions
        @Option(name: .long, help: "project=<uuid>[,environment=<name>][,tag:<key>=<value>] or ids=<uuid;uuid>.")
        var selector: String
        @Flag(name: .long, help: "Confirm the printed target list without prompting.") var yes = false
        @Flag(name: .long, help: "Return the saved run ID after confirmation; commands continue in the background.")
        var noWait = false
        @Argument(
            parsing: .postTerminator,
            help: "Executable and arguments after '--'. Use sh -c explicitly for shell syntax.")
        var command: [String]

        func run() async throws {
            var failed = false
            try await runHandlingCLIErrors {
                guard !command.isEmpty else { throw CLIError.config("Supply a command after '--'.") }
                let client = try CLIEnvironment.resolve(global).makeClient()
                var fleet = try await client.prepareVMFleetRun(body: .json(.init(selector: selector, command: command)))
                    .ok.body.json
                FileHandle.standardError.write(Data("Resolved fleet \(fleet.id): \(command)\n".utf8))
                for entry in fleet.entries {
                    FileHandle.standardError.write(
                        Data(
                            "\(entry.vmID)  \(entry.name ?? "inaccessible")  \(entry.state.rawValue)  \(entry.reason ?? "")\n"
                                .utf8))
                }
                if !yes {
                    guard standardInputIsTerminal() else {
                        throw CLIError.config(
                            "Confirmation requires terminal stdin; review the target list and use --yes for automation."
                        )
                    }
                    FileHandle.standardError.write(Data("Run this command on the resolved VMs? Type yes: ".utf8))
                    guard readLine() == "yes" else { throw CLIError.config("Fleet run cancelled before dispatch.") }
                }
                fleet = try await client.confirmVMFleetRun(
                    path: .init(runID: fleet.id),
                    body: .json(.init(vmIDs: fleet.entries.map(\.vmID)))
                ).accepted.body.json
                FileHandle.standardError.write(
                    Data("Fleet run \(fleet.id) accepted. Resume with strato vm run-results \(fleet.id).\n".utf8))
                if noWait {
                    try printFleet(fleet, format: global.output)
                    return
                }
                while !fleet.complete {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .seconds(2))
                    fleet = try await client.getVMFleetRun(path: .init(runID: fleet.id)).ok.body.json
                }
                try printFleet(fleet, format: global.output)
                failed =
                    fleet.entries.contains { $0.state == .skipped }
                    || fleet.operations.contains { $0.status != .succeeded || ($0.result?.exitCode ?? 1) != 0 }
            }
            if failed { throw ExitCode.failure }
        }
    }

    struct RunResults: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "run-results", abstract: "Read a saved fleet run without dispatching.")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Fleet run id.") var id: String
        func run() async throws {
            try await runHandlingCLIErrors {
                let client = try CLIEnvironment.resolve(global).makeClient()
                let fleet = try await client.getVMFleetRun(path: .init(runID: id)).ok.body.json
                try printFleet(fleet, format: global.output)
            }
        }
    }
}

private func printFleet(_ fleet: Components.Schemas.VMFleetRun, format: OutputFormat) throws {
    try printResult(fleet, format: format) {
        var table = TextTable(headers: ["VM", "name", "status", "exit", "operation", "detail"])
        for entry in fleet.entries {
            let operation = fleet.operations.first { $0.id == entry.operationID }
            table.addRow([
                entry.vmID, entry.name ?? "", operation?.status.rawValue ?? entry.state.rawValue,
                operation?.result?.exitCode.map(String.init) ?? "", entry.operationID ?? "",
                entry.reason ?? operation?.error ?? "",
            ])
        }
        return table
    }
    if format == .table {
        for operation in fleet.operations {
            guard let result = operation.result else { continue }
            print("\nVM \(operation.resourceId):\nstdout:\n\(result.stdout)\nstderr:\n\(result.stderr)")
            if result.truncated {
                print(
                    "Output excerpt truncated; use strato operation get \(operation.id ?? "") -o json for full captured output."
                )
            }
        }
    }
}
