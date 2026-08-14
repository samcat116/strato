import ArgumentParser
import Foundation
import StratoAPIClient
import StratoCLICore

struct VMCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vm",
        abstract: "Manage virtual machines.",
        subcommands: [
            List.self, Get.self, Create.self, Delete.self,
            Start.self, Stop.self, Reboot.self, Pause.self, Resume.self,
        ],
        defaultSubcommand: List.self
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List virtual machines.")

        @OptionGroup var global: GlobalOptions

        func run() async throws {
            try await runHandlingCLIErrors {
                let environment = try CLIEnvironment.resolve(global)
                let vms = try await environment.makeClient()
                    .listVMs(query: .init(limit: listPageLimit)).ok.body.json.items
                try printResult(vms, format: global.output) {
                    var table = TextTable(headers: ["id", "name", "status", "cpu", "memory", "disk", "created"])
                    for vm in vms {
                        table.addRow([
                            vm.id ?? "", vm.name, vm.status.rawValue,
                            String(vm.cpu), vm.memoryFormatted, vm.diskFormatted,
                            formatDate(vm.createdAt),
                        ])
                    }
                    return table
                }
            }
        }
    }

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show one virtual machine.")

        @OptionGroup var global: GlobalOptions

        @Argument(help: "VM id.")
        var id: String

        func run() async throws {
            try await runHandlingCLIErrors {
                let environment = try CLIEnvironment.resolve(global)
                let vm = try await environment.makeClient().getVM(path: .init(vmID: id)).ok.body.json
                try printResult(vm, format: global.output) {
                    var table = TextTable(headers: ["field", "value"])
                    table.addRow(["id", vm.id ?? ""])
                    table.addRow(["name", vm.name])
                    table.addRow(["description", vm.description])
                    table.addRow(["status", vm.status.rawValue])
                    table.addRow(["image", vm.image])
                    table.addRow(["project", vm.projectId ?? ""])
                    table.addRow(["cpu", String(vm.cpu)])
                    table.addRow(["memory", vm.memoryFormatted])
                    table.addRow(["disk", vm.diskFormatted])
                    table.addRow(["metadata source", vm.metadataSource?.value1.rawValue ?? "iso"])
                    table.addRow(["created", formatDate(vm.createdAt)])
                    return table
                }
            }
        }
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a virtual machine.")

        @OptionGroup var global: GlobalOptions

        @Argument(help: "VM name.")
        var name: String

        @Option(name: .long, help: "Image id to boot from.")
        var image: String

        @Option(name: .long, help: "Project id (defaults to the context's project).")
        var project: String?

        @Option(name: .long, help: "Environment name.")
        var environment: String?

        @Option(name: .long, help: "Description.")
        var description: String?

        @Option(name: .long, help: "vCPU count.")
        var cpu: Int?

        @Option(name: .long, help: "Memory in bytes.")
        var memory: Int64?

        @Option(name: .long, help: "Disk in bytes.")
        var disk: Int64?

        @Option(name: .long, help: "Logical network id.")
        var network: String?

        @Option(name: .long, help: "Path to an SSH public key to authorize in the guest.")
        var sshKeyFile: String?

        @Option(name: .long, help: "Guest bootstrap source: iso or imds (x86 QEMU default: imds).")
        var metadataSource: String?

        @Flag(name: .long, help: "Return immediately instead of waiting for the operation.")
        var noWait = false

        func run() async throws {
            try await runHandlingCLIErrors {
                let env = try CLIEnvironment.resolve(global)
                let client = env.makeClient()

                var sshPublicKey: String?
                if let sshKeyFile {
                    sshPublicKey = try String(contentsOfFile: sshKeyFile, encoding: .utf8)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }

                let guestBootstrapSource: Components.Schemas.CreateVMRequest.MetadataSourcePayload?
                if let metadataSource {
                    guard
                        let source = Components.Schemas.MetadataSource(
                            rawValue: metadataSource.lowercased())
                    else {
                        throw CLIError.config(
                            "Invalid --metadata-source value '\(metadataSource)'. Accepted values: iso, imds.")
                    }
                    guestBootstrapSource = .init(value1: source)
                } else {
                    guestBootstrapSource = nil
                }

                let accepted = try await client.createVM(
                    body: .json(
                        .init(
                            name: name, description: description, imageId: image,
                            projectId: try resolveProject(project, environment: env),
                            environment: environment, cpu: cpu, memory: memory, disk: disk,
                            networkId: network, sshPublicKey: sshPublicKey,
                            metadataSource: guestBootstrapSource))
                ).accepted.body.json
                try await handleMutation(
                    AcceptedMutation(id: accepted.mutationId), client: client, noWait: noWait,
                    format: global.output, successMessage: "VM '\(name)' created.")
            }
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a virtual machine.")

        @OptionGroup var global: GlobalOptions

        @Argument(help: "VM id.")
        var id: String

        @Flag(name: .long, help: "Return immediately instead of waiting for the operation.")
        var noWait = false

        func run() async throws {
            try await runHandlingCLIErrors {
                let env = try CLIEnvironment.resolve(global)
                let client = env.makeClient()
                let accepted = try await client.deleteVM(path: .init(vmID: id)).accepted.body.json
                try await handleMutation(
                    AcceptedMutation(id: accepted.mutationId), client: client, noWait: noWait,
                    format: global.output, successMessage: "VM \(id) deleted.")
            }
        }
    }
}

extension VMCommand {
    struct Start: ResourceActionCommand {
        static let configuration = CommandConfiguration(abstract: "Start a virtual machine.")
        static let resourceLabel = "VM"
        static let action: ResourceAction = {
            AcceptedMutation(id: try await $0.startVM(path: .init(vmID: $1)).accepted.body.json.mutationId)
        }
        static let pastTense = "started"
        @OptionGroup var global: GlobalOptions
        @Argument(help: "VM id.") var id: String
        @Flag(name: .long, help: "Return immediately instead of waiting.") var noWait = false
    }

    struct Stop: ResourceActionCommand {
        static let configuration = CommandConfiguration(abstract: "Stop a virtual machine.")
        static let resourceLabel = "VM"
        static let action: ResourceAction = {
            AcceptedMutation(id: try await $0.stopVM(path: .init(vmID: $1)).accepted.body.json.mutationId)
        }
        static let pastTense = "stopped"
        @OptionGroup var global: GlobalOptions
        @Argument(help: "VM id.") var id: String
        @Flag(name: .long, help: "Return immediately instead of waiting.") var noWait = false
    }

    struct Reboot: ResourceActionCommand {
        static let configuration = CommandConfiguration(abstract: "Reboot a virtual machine.")
        static let resourceLabel = "VM"
        static let action: ResourceAction = {
            AcceptedMutation(
                id: try await $0.restartVM(path: .init(vmID: $1)).accepted.body.json.mutationId)
        }
        static let pastTense = "rebooted"
        @OptionGroup var global: GlobalOptions
        @Argument(help: "VM id.") var id: String
        @Flag(name: .long, help: "Return immediately instead of waiting.") var noWait = false
    }

    struct Pause: ResourceActionCommand {
        static let configuration = CommandConfiguration(abstract: "Pause a virtual machine.")
        static let resourceLabel = "VM"
        static let action: ResourceAction = {
            AcceptedMutation(id: try await $0.pauseVM(path: .init(vmID: $1)).accepted.body.json.mutationId)
        }
        static let pastTense = "paused"
        @OptionGroup var global: GlobalOptions
        @Argument(help: "VM id.") var id: String
        @Flag(name: .long, help: "Return immediately instead of waiting.") var noWait = false
    }

    struct Resume: ResourceActionCommand {
        static let configuration = CommandConfiguration(abstract: "Resume a paused virtual machine.")
        static let resourceLabel = "VM"
        static let action: ResourceAction = {
            AcceptedMutation(id: try await $0.resumeVM(path: .init(vmID: $1)).accepted.body.json.mutationId)
        }
        static let pastTense = "resumed"
        @OptionGroup var global: GlobalOptions
        @Argument(help: "VM id.") var id: String
        @Flag(name: .long, help: "Return immediately instead of waiting.") var noWait = false
    }
}
