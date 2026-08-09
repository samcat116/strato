import ArgumentParser
import Foundation
import StratoAPIClient
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
                    let zones = try await environment.makeClient().listDNSZones(
                        query: .init(
                            projectId: project ?? environment.context.project, limit: listPageLimit)
                    ).ok.body.json.items
                    try printResult(zones, format: global.output) {
                        var table = TextTable(headers: ["id", "name", "networks", "primary for", "records"])
                        for zone in zones {
                            table.addRow([
                                zone.id, zone.name,
                                zone.networks.map(\.networkName).joined(separator: ","),
                                zone.networks.filter(\.isPrimary).map(\.networkName).joined(separator: ","),
                                String(zone.recordCount),
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
                    let zone = try await environment.makeClient()
                        .getDNSZone(path: .init(zoneId: id)).ok.body.json
                    try printResult(zone, format: global.output) {
                        var table = TextTable(headers: ["field", "value"])
                        table.addRow(["id", zone.id])
                        table.addRow(["name", zone.name])
                        table.addRow(["description", zone.description ?? ""])
                        table.addRow(["records", String(zone.recordCount)])
                        for attachment in zone.networks {
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
                    let zone = try await env.makeClient().createDNSZone(
                        body: .json(
                            .init(
                                name: name, description: description,
                                projectId: try resolveProject(project, environment: env)))
                    ).ok.body.json
                    switch global.output {
                    case .table:
                        print("DNS zone '\(zone.name)' created (\(zone.id)).")
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
                    _ = try await environment.makeClient().deleteDNSZone(path: .init(zoneId: id)).noContent
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
                    let zone = try await environment.makeClient().attachDNSZoneToNetwork(
                        path: .init(zoneId: id),
                        body: .json(.init(networkId: network, primary: primary ? true : nil))
                    ).ok.body.json
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
                    _ = try await environment.makeClient()
                        .detachDNSZoneFromNetwork(path: .init(zoneId: id, networkId: network)).noContent
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
                    let assembled = try await environment.makeClient()
                        .getDNSZoneRecordSet(path: .init(zoneId: id)).ok.body.json
                    try printResult(assembled, format: global.output) {
                        var table = TextTable(headers: ["name", "type", "ttl", "origin", "values"])
                        for record in assembled.records {
                            table.addRow([
                                record.name, record._type.rawValue, String(record.ttl),
                                record.origin.rawValue, record.values.joined(separator: " "),
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
                    let records = try await environment.makeClient()
                        .listDNSRecords(path: .init(zoneId: zone), query: .init(limit: listPageLimit))
                        .ok.body.json.items
                    try printResult(records, format: global.output) {
                        var table = TextTable(headers: ["id", "name", "type", "ttl", "view", "value"])
                        for record in records {
                            table.addRow([
                                record.id, record.fqdn, record._type.rawValue,
                                String(record.ttl), record.view.rawValue, record.value,
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
                    let recordType = try specEnum(
                        Components.Schemas.DNSRecordType.self, from: type.uppercased(), flag: "--type")
                    let recordView = try view.map {
                        try specEnum(
                            Components.Schemas.DNSRecordView.self, from: $0.lowercased(), flag: "--view")
                    }
                    let record = try await environment.makeClient().createDNSRecord(
                        path: .init(zoneId: zone),
                        body: .json(
                            .init(name: name, _type: recordType, value: value, ttl: ttl, view: recordView))
                    ).ok.body.json
                    switch global.output {
                    case .table:
                        print(
                            "Record \(record._type.rawValue) \(record.fqdn) → \(record.value) "
                                + "created (\(record.id)).")
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
                    _ = try await environment.makeClient()
                        .deleteDNSRecord(path: .init(zoneId: zone, recordId: id)).noContent
                    print("Record \(id) deleted.")
                }
            }
        }
    }
}

/// Turns a free-form flag value into one of the spec's enum cases, failing
/// with the accepted values rather than letting the server reject it.
private func specEnum<Value: RawRepresentable & CaseIterable>(
    _ type: Value.Type, from raw: String, flag: String
) throws -> Value where Value.RawValue == String {
    guard let value = Value(rawValue: raw) else {
        let accepted = Value.allCases.map(\.rawValue).joined(separator: ", ")
        throw CLIError.config("Invalid \(flag) value '\(raw)'. Accepted values: \(accepted).")
    }
    return value
}
