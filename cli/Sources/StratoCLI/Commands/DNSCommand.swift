import ArgumentParser
import Foundation
import StratoCLICore

/// `strato dns` — zones, their attachment to networks, and authored records
/// (issue #770).
struct DNSCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dns",
        abstract: "Manage DNS zones and records.",
        subcommands: [Zone.self, Record.self],
        defaultSubcommand: Zone.self
    )

    // MARK: - Zones

    struct Zone: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "zone",
            abstract: "Manage DNS zones.",
            subcommands: [List.self, Get.self, Create.self, Delete.self, Attach.self, Detach.self, Records.self],
            defaultSubcommand: List.self
        )

        struct List: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "List DNS zones.")

            @OptionGroup var global: GlobalOptions

            @Option(name: .long, help: "Scope to one project id.")
            var project: String?

            func run() async throws {
                try await runHandlingCLIErrors {
                    let environment = try CLIEnvironment.resolve(global)
                    var query = [("limit", String(listPageLimit))]
                    if let project = project ?? environment.context.project {
                        query.append(("project_id", project))
                    }
                    let page: Page<DNSZone> = try await environment.makeClient()
                        .get("/api/dns-zones", query: query)
                    try printResult(page.items, format: global.output) {
                        var table = TextTable(headers: ["id", "name", "networks", "primary for", "records"])
                        for zone in page.items {
                            let attached = zone.networks ?? []
                            table.addRow([
                                formatUUID(zone.id), zone.name,
                                attached.map(\.networkName).joined(separator: ","),
                                attached.filter(\.isPrimary).map(\.networkName).joined(separator: ","),
                                zone.recordCount.map(String.init) ?? "",
                            ])
                        }
                        return table
                    }
                }
            }
        }

        struct Get: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Show one DNS zone.")

            @OptionGroup var global: GlobalOptions

            @Argument(help: "Zone id.")
            var id: String

            func run() async throws {
                try await runHandlingCLIErrors {
                    let environment = try CLIEnvironment.resolve(global)
                    let zone: DNSZone = try await environment.makeClient().get("/api/dns-zones/\(id)")
                    try printResult(zone, format: global.output) {
                        var table = TextTable(headers: ["field", "value"])
                        table.addRow(["id", formatUUID(zone.id)])
                        table.addRow(["name", zone.name])
                        table.addRow(["description", zone.description ?? ""])
                        table.addRow(["records", zone.recordCount.map(String.init) ?? ""])
                        for attachment in zone.networks ?? [] {
                            table.addRow([
                                attachment.isPrimary ? "network (primary)" : "network",
                                attachment.networkName,
                            ])
                        }
                        table.addRow(["created", formatDate(zone.createdAt)])
                        return table
                    }
                }
            }
        }

        struct Create: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Create a DNS zone.")

            @OptionGroup var global: GlobalOptions

            @Argument(help: "Fully-qualified zone name, e.g. acme.internal.")
            var name: String

            @Option(name: .long, help: "Free-form description.")
            var description: String?

            @Option(name: .long, help: "Project id (defaults to the context's project).")
            var project: String?

            func run() async throws {
                try await runHandlingCLIErrors {
                    let env = try CLIEnvironment.resolve(global)
                    let request = CreateDNSZoneRequest(
                        name: name, description: description,
                        projectId: project ?? env.context.project)
                    let zone: DNSZone = try await env.makeClient().post("/api/dns-zones", body: request)
                    switch global.output {
                    case .table:
                        print("DNS zone '\(zone.name)' created (\(formatUUID(zone.id))).")
                    case .json:
                        print(try renderJSON(zone))
                    }
                }
            }
        }

        struct Delete: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Delete a DNS zone.")

            @OptionGroup var global: GlobalOptions

            @Argument(help: "Zone id.")
            var id: String

            func run() async throws {
                try await runHandlingCLIErrors {
                    let environment = try CLIEnvironment.resolve(global)
                    try await environment.makeClient().deleteExpectingNoContent("/api/dns-zones/\(id)")
                    print("DNS zone \(id) deleted.")
                }
            }
        }

        struct Attach: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Attach a zone to a network so its VMs can resolve the zone.")

            @OptionGroup var global: GlobalOptions

            @Argument(help: "Zone id.")
            var id: String

            @Option(name: .long, help: "Network id to attach.")
            var network: String

            @Flag(name: .long, help: "Also make this the zone VMs on the network register into.")
            var primary = false

            func run() async throws {
                try await runHandlingCLIErrors {
                    let environment = try CLIEnvironment.resolve(global)
                    let request = AttachDNSZoneRequest(networkId: network, primary: primary ? true : nil)
                    let zone: DNSZone = try await environment.makeClient()
                        .post("/api/dns-zones/\(id)/networks", body: request)
                    switch global.output {
                    case .table:
                        let role = primary ? "attached as primary" : "attached"
                        print("Zone '\(zone.name)' \(role) to network \(network).")
                    case .json:
                        print(try renderJSON(zone))
                    }
                }
            }
        }

        struct Detach: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Detach a zone from a network.")

            @OptionGroup var global: GlobalOptions

            @Argument(help: "Zone id.")
            var id: String

            @Option(name: .long, help: "Network id to detach.")
            var network: String

            func run() async throws {
                try await runHandlingCLIErrors {
                    let environment = try CLIEnvironment.resolve(global)
                    try await environment.makeClient()
                        .deleteExpectingNoContent("/api/dns-zones/\(id)/networks/\(network)")
                    print("Zone \(id) detached from network \(network).")
                }
            }
        }

        struct Records: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "recordset",
                abstract: "Show a zone's effective records (derived VM names plus authored entries).")

            @OptionGroup var global: GlobalOptions

            @Argument(help: "Zone id.")
            var id: String

            func run() async throws {
                try await runHandlingCLIErrors {
                    let environment = try CLIEnvironment.resolve(global)
                    let assembled: AssembledDNSZone = try await environment.makeClient()
                        .get("/api/dns-zones/\(id)/recordset")
                    try printResult(assembled, format: global.output) {
                        var table = TextTable(headers: ["name", "type", "ttl", "origin", "values"])
                        for record in assembled.records {
                            table.addRow([
                                record.name, record.type, String(record.ttl), record.origin,
                                record.values.joined(separator: " "),
                            ])
                        }
                        return table
                    }
                }
            }
        }
    }

    // MARK: - Records

    struct Record: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "record",
            abstract: "Manage authored records in a DNS zone.",
            subcommands: [List.self, Create.self, Delete.self],
            defaultSubcommand: List.self
        )

        struct List: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "List a zone's authored records.")

            @OptionGroup var global: GlobalOptions

            @Argument(help: "Zone id.")
            var zone: String

            func run() async throws {
                try await runHandlingCLIErrors {
                    let environment = try CLIEnvironment.resolve(global)
                    let page: Page<DNSRecord> = try await environment.makeClient()
                        .get("/api/dns-zones/\(zone)/records", query: [("limit", String(listPageLimit))])
                    try printResult(page.items, format: global.output) {
                        var table = TextTable(headers: ["id", "name", "type", "ttl", "view", "value"])
                        for record in page.items {
                            table.addRow([
                                formatUUID(record.id), record.fqdn ?? record.name, record.type,
                                record.ttl.map(String.init) ?? "", record.view ?? "", record.value,
                            ])
                        }
                        return table
                    }
                }
            }
        }

        struct Create: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Author a record in a zone.")

            @OptionGroup var global: GlobalOptions

            @Argument(help: "Zone id.")
            var zone: String

            @Option(name: .long, help: "Owner name relative to the zone; omit for the apex.")
            var name: String?

            @Option(name: .long, help: "Record type: A, AAAA, CNAME, TXT, SRV, or PTR.")
            var type: String

            @Option(name: .long, help: "Record value (RDATA in zone-file form).")
            var value: String

            @Option(name: .long, help: "TTL in seconds (default 300).")
            var ttl: Int?

            @Option(name: .long, help: "Split-horizon view: internal, external, or both.")
            var view: String?

            func run() async throws {
                try await runHandlingCLIErrors {
                    let environment = try CLIEnvironment.resolve(global)
                    // Both enums are case-normalized here so `--type a` and
                    // `--view Internal` behave the same way; the wire format
                    // spells types upper and views lower.
                    let request = CreateDNSRecordRequest(
                        name: name, type: type.uppercased(), value: value, ttl: ttl,
                        view: view?.lowercased())
                    let record: DNSRecord = try await environment.makeClient()
                        .post("/api/dns-zones/\(zone)/records", body: request)
                    switch global.output {
                    case .table:
                        print(
                            "Record \(record.type) \(record.fqdn ?? record.name) → \(record.value) "
                                + "created (\(formatUUID(record.id))).")
                    case .json:
                        print(try renderJSON(record))
                    }
                }
            }
        }

        struct Delete: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Delete an authored record.")

            @OptionGroup var global: GlobalOptions

            @Argument(help: "Zone id.")
            var zone: String

            @Argument(help: "Record id.")
            var id: String

            func run() async throws {
                try await runHandlingCLIErrors {
                    let environment = try CLIEnvironment.resolve(global)
                    try await environment.makeClient()
                        .deleteExpectingNoContent("/api/dns-zones/\(zone)/records/\(id)")
                    print("Record \(id) deleted.")
                }
            }
        }
    }
}
