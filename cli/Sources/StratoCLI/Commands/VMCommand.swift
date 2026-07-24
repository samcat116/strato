import ArgumentParser
import Foundation
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
                let page: Page<VM> = try await environment.makeClient()
                    .get("/api/vms", query: [("limit", String(listPageLimit))])
                let vms = page.items
                try printResult(vms, format: global.output) {
                    var table = TextTable(headers: ["id", "name", "status", "cpu", "memory", "disk", "created"])
                    for vm in vms {
                        table.addRow([
                            formatUUID(vm.id), vm.name, vm.status,
                            vm.cpu.map(String.init) ?? "",
                            vm.memoryFormatted ?? "",
                            vm.diskFormatted ?? "",
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
                let vm: VM = try await environment.makeClient().get("/api/vms/\(id)")
                try printResult(vm, format: global.output) {
                    var table = TextTable(headers: ["field", "value"])
                    table.addRow(["id", formatUUID(vm.id)])
                    table.addRow(["name", vm.name])
                    table.addRow(["description", vm.description ?? ""])
                    table.addRow(["status", vm.status])
                    table.addRow(["image", vm.image ?? ""])
                    table.addRow(["project", formatUUID(vm.projectId)])
                    table.addRow(["cpu", vm.cpu.map(String.init) ?? ""])
                    table.addRow(["memory", vm.memoryFormatted ?? ""])
                    table.addRow(["disk", vm.diskFormatted ?? ""])
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

                let request = CreateVMRequest(
                    name: name, description: description, imageId: image,
                    projectId: project ?? env.context.project,
                    environment: environment, cpu: cpu, memory: memory, disk: disk,
                    networkId: network, sshPublicKey: sshPublicKey, userData: nil
                )
                let operation: ResourceOperation = try await client.post("/api/vms", body: request)
                try await handleOperation(
                    operation, client: client, noWait: noWait, format: global.output,
                    successMessage: "VM '\(name)' created.")
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
                let operation: ResourceOperation = try await client.delete("/api/vms/\(id)")
                try await handleOperation(
                    operation, client: client, noWait: noWait, format: global.output,
                    successMessage: "VM \(id) deleted.")
            }
        }
    }
}

/// One lifecycle action (`POST /api/vms/:id/<verb>`) as a reusable command.
protocol VMActionCommand: AsyncParsableCommand {
    static var verb: String { get }
    static var pastTense: String { get }
    var global: GlobalOptions { get }
    var id: String { get }
    var noWait: Bool { get }
}

extension VMActionCommand {
    func run() async throws {
        try await runHandlingCLIErrors {
            let env = try CLIEnvironment.resolve(global)
            let client = env.makeClient()
            let operation: ResourceOperation = try await client.post("/api/vms/\(id)/\(Self.verb)")
            try await handleOperation(
                operation, client: client, noWait: noWait, format: global.output,
                successMessage: "VM \(id) \(Self.pastTense).")
        }
    }
}

extension VMCommand {
    struct Start: VMActionCommand {
        static let configuration = CommandConfiguration(abstract: "Start a virtual machine.")
        static let verb = "start"
        static let pastTense = "started"
        @OptionGroup var global: GlobalOptions
        @Argument(help: "VM id.") var id: String
        @Flag(name: .long, help: "Return immediately instead of waiting.") var noWait = false
    }

    struct Stop: VMActionCommand {
        static let configuration = CommandConfiguration(abstract: "Stop a virtual machine.")
        static let verb = "stop"
        static let pastTense = "stopped"
        @OptionGroup var global: GlobalOptions
        @Argument(help: "VM id.") var id: String
        @Flag(name: .long, help: "Return immediately instead of waiting.") var noWait = false
    }

    struct Reboot: VMActionCommand {
        static let configuration = CommandConfiguration(abstract: "Reboot a virtual machine.")
        static let verb = "restart"
        static let pastTense = "rebooted"
        @OptionGroup var global: GlobalOptions
        @Argument(help: "VM id.") var id: String
        @Flag(name: .long, help: "Return immediately instead of waiting.") var noWait = false
    }

    struct Pause: VMActionCommand {
        static let configuration = CommandConfiguration(abstract: "Pause a virtual machine.")
        static let verb = "pause"
        static let pastTense = "paused"
        @OptionGroup var global: GlobalOptions
        @Argument(help: "VM id.") var id: String
        @Flag(name: .long, help: "Return immediately instead of waiting.") var noWait = false
    }

    struct Resume: VMActionCommand {
        static let configuration = CommandConfiguration(abstract: "Resume a paused virtual machine.")
        static let verb = "resume"
        static let pastTense = "resumed"
        @OptionGroup var global: GlobalOptions
        @Argument(help: "VM id.") var id: String
        @Flag(name: .long, help: "Return immediately instead of waiting.") var noWait = false
    }
}
