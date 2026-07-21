import Fluent
import Testing
import Vapor

@testable import App

/// Backfill behavior of `CreateVMInterfaceAddresses`, exercised against a bare
/// empty database with hand-built prerequisite tables so legacy rows can exist
/// before the migration runs (the shared template harness has every migration
/// pre-applied, which makes before/after tests impossible).
@Suite("VMInterfaceAddress backfill migration")
struct VMInterfaceAddressMigrationTests {
    private final class LegacyInterface: Model, @unchecked Sendable {
        static let schema = "vm_network_interfaces"

        @ID(key: .id)
        var id: UUID?

        @Field(key: "network")
        var network: String

        @OptionalField(key: "ip_address")
        var ipAddress: String?

        @OptionalField(key: "netmask")
        var netmask: String?

        @OptionalField(key: "gateway")
        var gateway: String?

        init() {}

        convenience init(network: String, ipAddress: String?, netmask: String?, gateway: String?) {
            self.init()
            self.network = network
            self.ipAddress = ipAddress
            self.netmask = netmask
            self.gateway = gateway
        }
    }

    private final class NetworkRow: Model, @unchecked Sendable {
        static let schema = "logical_networks"

        @ID(key: .id)
        var id: UUID?

        @Field(key: "name")
        var name: String

        @Field(key: "subnet")
        var subnet: String

        init() {}

        convenience init(name: String, subnet: String) {
            self.init()
            self.name = name
            self.subnet = subnet
        }
    }

    private func withBareApp(_ body: (Application) async throws -> Void) async throws {
        let app = try await Application.makeForBareDatabaseTesting()
        app.logger.logLevel = .error
        do {
            try await app.db.schema("vm_network_interfaces")
                .id()
                .field("network", .string, .required)
                .field("ip_address", .string)
                .field("netmask", .string)
                .field("gateway", .string)
                .create()
            try await app.db.schema("logical_networks")
                .id()
                .field("name", .string, .required)
                .field("subnet", .string, .required)
                .create()
            try await body(app)
            try await app.shutdownForTesting()
        } catch {
            try? await app.shutdownForTesting()
            throw error
        }
    }

    @Test("legacy addressed interfaces gain one ipv4 row; prefix falls back netmask → subnet → 24")
    func backfillsLegacyRows() async throws {
        try await withBareApp { app in
            try await NetworkRow(name: "subnet-net", subnet: "10.7.0.0/26").save(on: app.db)

            let fromMask = LegacyInterface(
                network: "default", ipAddress: "192.168.1.10", netmask: "255.255.0.0",
                gateway: "192.168.1.1")
            let fromSubnet = LegacyInterface(
                network: "subnet-net", ipAddress: "10.7.0.9", netmask: "not-a-mask", gateway: nil)
            let fromDefault = LegacyInterface(
                network: "ghost-net", ipAddress: "10.8.0.9", netmask: nil, gateway: nil)
            let addressless = LegacyInterface(
                network: "default", ipAddress: nil, netmask: nil, gateway: nil)
            for row in [fromMask, fromSubnet, fromDefault, addressless] {
                try await row.save(on: app.db)
            }

            try await CreateVMInterfaceAddresses().prepare(on: app.db)

            let addresses = try await VMInterfaceAddress.query(on: app.db).all()
            #expect(addresses.count == 3)
            #expect(addresses.allSatisfy { $0.family == "ipv4" })

            let byAddress = Dictionary(uniqueKeysWithValues: addresses.map { ($0.address, $0) })
            #expect(byAddress["192.168.1.10"]?.prefixLength == 16)
            #expect(byAddress["192.168.1.10"]?.gateway == "192.168.1.1")
            #expect(byAddress["192.168.1.10"]?.network == "default")
            #expect(byAddress["192.168.1.10"]?.$interface.id == fromMask.id)
            #expect(byAddress["10.7.0.9"]?.prefixLength == 26)
            #expect(byAddress["10.8.0.9"]?.prefixLength == 24)

            // The uniqueness backstop exists: a duplicate (network, address)
            // insert must fail.
            let duplicate = VMInterfaceAddress(
                interfaceID: addressless.id!, network: "default", family: .ipv4,
                address: "192.168.1.10", prefixLength: 24)
            await #expect(throws: (any Error).self) {
                try await duplicate.save(on: app.db)
            }

            // Revert drops the table cleanly.
            try await CreateVMInterfaceAddresses().revert(on: app.db)
        }
    }
}
