import ArgumentParser
import Foundation
import StratoAPIClient
import StratoCLICore

extension VMCommand {
    struct GuestConfiguration: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "guest-config", abstract: "Read or replace desired in-guest configuration.",
            subcommands: [Get.self, Set.self, Clear.self], defaultSubcommand: Get.self)

        struct Get: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Read desired guest configuration (privileged).")
            @OptionGroup var global: GlobalOptions
            @Argument(help: "VM id.") var id: String
            func run() async throws {
                try await runHandlingCLIErrors {
                    let env = try CLIEnvironment.resolve(global)
                    let value = try await env.makeClient().getVMGuestConfiguration(path: .init(vmID: id)).ok.body.json
                    try printResult(value, format: global.output) {
                        GuestConfigurationOutput.table(value)
                    }
                }
            }
        }

        struct Set: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Replace desired guest configuration from a JSON file.")
            @OptionGroup var global: GlobalOptions
            @Argument(help: "VM id.") var id: String
            @Option(name: .long, help: "Path to a STR-90 guest configuration JSON document.") var file: String
            @Flag(name: .long, help: "Return the mutation id without waiting.") var noWait = false
            @Flag(name: .long, help: "Retry a failed generation even when intent is unchanged.") var retry = false
            func run() async throws {
                try await runHandlingCLIErrors {
                    var request = try GuestConfigurationInput.read(file: file)
                    request.retry = retry
                    try await GuestConfiguration.replace(id: id, request: request, global: global, noWait: noWait)
                }
            }
        }

        struct Clear: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Withdraw management; existing guest changes are not reversed.")
            @OptionGroup var global: GlobalOptions
            @Argument(help: "VM id.") var id: String
            @Flag(name: .long, help: "Return the mutation id without waiting.") var noWait = false
            func run() async throws {
                try await runHandlingCLIErrors {
                    try await GuestConfiguration.replace(
                        id: id, request: try GuestConfigurationInput.withdrawal(), global: global, noWait: noWait)
                }
            }
        }

        static func replace(
            id: String, request: Components.Schemas.ReplaceVMGuestConfigurationRequest,
            global: GlobalOptions, noWait: Bool
        ) async throws {
            let env = try CLIEnvironment.resolve(global)
            let client = env.makeClient()
            let response = try await client.replaceVMGuestConfiguration(path: .init(vmID: id), body: .json(request))
            switch response {
            case .ok(let response):
                switch global.output {
                case .json: print(try renderJSON(response.body.json))
                case .table: print("Desired configuration is unchanged; this is not proof of convergence.")
                }
            case .accepted(let response):
                let accepted = try response.body.json
                try await handleMutation(
                    AcceptedMutation(id: accepted.mutationId), client: client, noWait: noWait,
                    format: global.output, successMessage: "Guest configuration mutation completed.")
            case .badRequest(let response):
                throw CLIError.api(status: 400, message: try response.body.json.reason)
            case .unauthorized(let response):
                throw CLIError.api(status: 401, message: try response.body.json.reason)
            case .forbidden(let response):
                throw CLIError.api(status: 403, message: try response.body.json.reason)
            case .notFound(let response):
                throw CLIError.api(status: 404, message: try response.body.json.reason)
            case .conflict(let response):
                throw CLIError.api(status: 409, message: try response.body.json.reason)
            case .unprocessableContent(let response):
                throw CLIError.api(status: 422, message: try response.body.json.reason)
            default:
                throw CLIError.api(status: 0, message: "Guest configuration request was rejected")
            }
        }
    }
}
