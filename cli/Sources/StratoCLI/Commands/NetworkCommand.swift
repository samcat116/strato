import ArgumentParser
import Foundation
import StratoCLICore

struct NetworkCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "network",
        abstract: "Manage logical networks.",
        subcommands: [List.self, Get.self, Create.self, Delete.self],
        defaultSubcommand: List.self
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List networks.")

        @OptionGroup var global: GlobalOptions

        func run() async throws {
            try await runHandlingCLIErrors {
                let environment = try CLIEnvironment.resolve(global)
                let networks: [Network] = try await environment.makeClient().get("/api/networks")
                try printResult(networks, format: global.output) {
                    var table = TextTable(
                        headers: ["id", "name", "subnet", "gateway", "dhcp", "attached", "default"])
                    for network in networks {
                        table.addRow([
                            formatUUID(network.id), network.name, network.subnet,
                            network.gateway ?? "",
                            (network.dhcpEnabled ?? false) ? "yes" : "no",
                            network.attachedInterfaceCount.map(String.init) ?? "",
                            (network.isDefault ?? false) ? "yes" : "",
                        ])
                    }
                    return table
                }
            }
        }
    }

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show one network.")

        @OptionGroup var global: GlobalOptions

        @Argument(help: "Network id.")
        var id: String

        func run() async throws {
            try await runHandlingCLIErrors {
                let environment = try CLIEnvironment.resolve(global)
                let network: Network = try await environment.makeClient().get("/api/networks/\(id)")
                try printResult(network, format: global.output) {
                    var table = TextTable(headers: ["field", "value"])
                    table.addRow(["id", formatUUID(network.id)])
                    table.addRow(["name", network.name])
                    table.addRow(["subnet", network.subnet])
                    table.addRow(["gateway", network.gateway ?? ""])
                    table.addRow(["ipv6 subnet", network.subnet6 ?? ""])
                    table.addRow(["dhcp", (network.dhcpEnabled ?? false) ? "enabled" : "disabled"])
                    table.addRow(["attached NICs", network.attachedInterfaceCount.map(String.init) ?? ""])
                    table.addRow(["default", (network.isDefault ?? false) ? "yes" : "no"])
                    table.addRow(["created", formatDate(network.createdAt)])
                    return table
                }
            }
        }
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a network.")

        @OptionGroup var global: GlobalOptions

        @Argument(help: "Network name.")
        var name: String

        @Option(name: .long, help: "IPv4 subnet in CIDR form, e.g. 10.1.0.0/24.")
        var subnet: String

        @Option(name: .long, help: "Gateway address (defaults to the subnet's first host).")
        var gateway: String?

        @Option(name: .long, help: "Project id (defaults to the context's project).")
        var project: String?

        @Flag(name: .long, inversion: .prefixedNo, help: "Program OVN's DHCP responder for guests.")
        var dhcp = true

        func run() async throws {
            try await runHandlingCLIErrors {
                let env = try CLIEnvironment.resolve(global)
                let request = CreateNetworkRequest(
                    name: name, subnet: subnet, gateway: gateway,
                    projectId: project ?? env.context.project, dhcpEnabled: dhcp
                )
                let network: Network = try await env.makeClient().post("/api/networks", body: request)
                switch global.output {
                case .table:
                    print("Network '\(network.name)' created (\(formatUUID(network.id))).")
                case .json:
                    print(try renderJSON(network))
                }
            }
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a network.")

        @OptionGroup var global: GlobalOptions

        @Argument(help: "Network id.")
        var id: String

        func run() async throws {
            try await runHandlingCLIErrors {
                let environment = try CLIEnvironment.resolve(global)
                try await environment.makeClient().deleteExpectingNoContent("/api/networks/\(id)")
                print("Network \(id) deleted.")
            }
        }
    }
}
