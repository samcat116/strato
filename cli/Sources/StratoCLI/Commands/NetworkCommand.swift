import ArgumentParser
import Foundation
import StratoAPIClient
import StratoCLICore

struct NetworkCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "network",
        abstract: "Manage logical networks.",
        subcommands: [List.self, Get.self, Create.self, Update.self, Delete.self],
        defaultSubcommand: List.self
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List networks.")

        @OptionGroup var global: GlobalOptions

        func run() async throws {
            try await runHandlingCLIErrors {
                let environment = try CLIEnvironment.resolve(global)
                let networks = try await environment.makeClient()
                    .listNetworks(query: .init(limit: listPageLimit)).ok.body.json.items
                try printResult(networks, format: global.output) {
                    var table = TextTable(headers: ["id", "name", "subnet", "gateway", "dhcp", "attached"])
                    for network in networks {
                        table.addRow([
                            network.id ?? "", network.name, network.subnet,
                            network.gateway ?? "",
                            network.dhcpEnabled ? "yes" : "no",
                            String(network.attachedInterfaceCount),
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
                let network = try await environment.makeClient()
                    .getNetwork(path: .init(networkId: id)).ok.body.json
                try printResult(network, format: global.output) {
                    var table = TextTable(headers: ["field", "value"])
                    table.addRow(["id", network.id ?? ""])
                    table.addRow(["name", network.name])
                    table.addRow(["subnet", network.subnet])
                    table.addRow(["gateway", network.gateway ?? ""])
                    table.addRow(["ipv6 subnet", network.subnet6 ?? ""])
                    table.addRow(["dhcp", network.dhcpEnabled ? "enabled" : "disabled"])
                    table.addRow(["metadata service", network.metadataEnabled ? "enabled" : "disabled"])
                    table.addRow(["dns resolver", network.resolverEnabled ? "enabled" : "disabled"])
                    table.addRow(
                        [
                            network.resolverEnabled ? "upstream forwarders" : "dns servers",
                            network.dnsServers.joined(separator: ", "),
                        ])
                    table.addRow(["domain name", network.domainName ?? ""])
                    table.addRow(["primary dns zone", network.primaryDnsZoneId ?? ""])
                    // Only rendered when there is one: an empty row here would
                    // read as "checked, and fine", which is not what an absent
                    // warning means for a network with no zones at all.
                    if let warning = network.zoneResolutionWarning {
                        table.addRow(["zone resolution", warning])
                    }
                    table.addRow(["attached NICs", String(network.attachedInterfaceCount)])
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

        @Option(
            name: .customLong("dns-server"), parsing: .singleValue,
            help: """
                With --resolver (the default), an upstream the built-in resolver forwards to; \
                without it, a resolver advertised to guests over DHCP. Repeat for several.
                """)
        var dnsServers: [String] = []

        @Option(
            name: .long,
            help: "Search domain advertised over DHCP (the domain_name option), e.g. corp.example.com.")
        var domainName: String?

        @Flag(
            name: .long, inversion: .prefixedNo,
            help: "Publish the link-local instance metadata service to guests. Enabled by default.")
        var metadata: Bool?

        @Flag(
            name: .long, inversion: .prefixedNo,
            help: """
                Give guests a built-in DNS resolver at a link-local address of the network's \
                own, serving this network's zones in full — including the CNAME, TXT and SRV \
                records the datapath cannot express — and forwarding the rest through the \
                hypervisor's own egress. Enabled by default; --no-resolver hands guests the \
                --dns-server list directly instead.
                """)
        var resolver: Bool?

        func run() async throws {
            try await runHandlingCLIErrors {
                let env = try CLIEnvironment.resolve(global)
                let network = try await env.makeClient().createNetwork(
                    body: .json(
                        .init(
                            name: name, subnet: subnet, gateway: gateway,
                            projectId: project ?? env.context.project, dhcpEnabled: dhcp,
                            dnsServers: dnsServers.isEmpty ? nil : dnsServers, domainName: domainName,
                            metadataEnabled: metadata, resolverEnabled: resolver))
                ).ok.body.json
                switch global.output {
                case .table:
                    print("Network '\(network.name)' created (\(network.id ?? "")).")
                case .json:
                    print(try renderJSON(network))
                }
            }
        }
    }

    struct Update: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Update a network's DNS settings, primary DNS zone, resolver, or metadata service.")

        @OptionGroup var global: GlobalOptions

        @Argument(help: "Network id.")
        var id: String

        @Option(
            name: .customLong("dns-server"), parsing: .singleValue,
            help: """
                Replace the network's resolvers — upstream forwarders when --resolver is on. \
                Repeat for several.
                """)
        var dnsServers: [String] = []

        @Option(name: .long, help: "Search domain advertised over DHCP. Pass an empty string to clear it.")
        var domainName: String?

        @Option(
            name: .long,
            help: "Zone id VMs on this network register into. Must already be attached to the network.")
        var primaryDnsZone: String?

        @Flag(name: .long, help: "Unset the network's primary DNS zone.")
        var clearPrimaryDnsZone = false

        @Flag(
            name: .long, inversion: .prefixedNo,
            help: "Publish the link-local instance metadata service to guests.")
        var metadata: Bool?

        @Flag(
            name: .long, inversion: .prefixedNo,
            help: "Give guests a built-in DNS resolver at a link-local address of the network's own.")
        var resolver: Bool?

        func run() async throws {
            try await runHandlingCLIErrors {
                let environment = try CLIEnvironment.resolve(global)
                let network = try await environment.makeClient().updateNetwork(
                    path: .init(networkId: id),
                    body: .json(
                        .init(
                            dnsServers: dnsServers.isEmpty ? nil : dnsServers,
                            domainName: domainName,
                            metadataEnabled: metadata,
                            resolverEnabled: resolver,
                            primaryDnsZoneId: primaryDnsZone,
                            clearPrimaryDnsZone: clearPrimaryDnsZone ? true : nil))
                ).ok.body.json
                switch global.output {
                case .table:
                    print("Network '\(network.name)' updated.")
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
                _ = try await environment.makeClient().deleteNetwork(path: .init(networkId: id)).noContent
                print("Network \(id) deleted.")
            }
        }
    }
}
