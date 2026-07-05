import Foundation
import Testing
import StratoShared

@Suite("Network operation messages")
struct NetworkMessageTests {
    @Test func networkCreateRoundTrip() throws {
        let decoded = try throughEnvelope(
            NetworkCreateMessage(
                requestId: Fixtures.requestId,
                timestamp: Fixtures.timestamp,
                networkName: "tenant-net",
                subnet: "10.1.0.0/24",
                gateway: "10.1.0.1",
                vlanId: 42,
                dhcpEnabled: false,
                dnsServers: ["1.1.1.1", "9.9.9.9"]
            )
        )
        #expect(decoded.type == .networkCreate)
        #expect(decoded.networkName == "tenant-net")
        #expect(decoded.subnet == "10.1.0.0/24")
        #expect(decoded.gateway == "10.1.0.1")
        #expect(decoded.vlanId == 42)
        #expect(decoded.dhcpEnabled == false)
        #expect(decoded.dnsServers == ["1.1.1.1", "9.9.9.9"])
    }

    @Test func networkDeleteRoundTrip() throws {
        let decoded = try throughEnvelope(
            NetworkDeleteMessage(
                requestId: Fixtures.requestId, timestamp: Fixtures.timestamp, networkName: "tenant-net")
        )
        #expect(decoded.type == .networkDelete)
        #expect(decoded.networkName == "tenant-net")
    }

    @Test func networkListRoundTrip() throws {
        let decoded = try throughEnvelope(
            NetworkListMessage(requestId: Fixtures.requestId, timestamp: Fixtures.timestamp)
        )
        #expect(decoded.type == .networkList)
        #expect(decoded.requestId == Fixtures.requestId)
        #expect(decoded.timestamp == Fixtures.timestamp)
    }

    @Test func networkInfoRoundTrip() throws {
        let decoded = try throughEnvelope(
            NetworkInfoMessage(requestId: Fixtures.requestId, timestamp: Fixtures.timestamp, networkName: "tenant-net")
        )
        #expect(decoded.type == .networkInfo)
        #expect(decoded.networkName == "tenant-net")
    }

    @Test func networkAttachRoundTrip() throws {
        let config = VMNetworkConfig(
            networkName: "tenant-net",
            macAddress: "52:54:00:aa:bb:cc",
            ipAddress: "10.1.0.9",
            subnet: "10.1.0.0/24",
            gateway: "10.1.0.1",
            vlanId: 42,
            portSecurity: false,
            dhcp: false
        )
        let decoded = try throughEnvelope(
            NetworkAttachMessage(
                requestId: Fixtures.requestId,
                timestamp: Fixtures.timestamp,
                vmId: "vm-2",
                networkName: "tenant-net",
                config: config
            )
        )
        #expect(decoded.type == .networkAttach)
        #expect(decoded.vmId == "vm-2")
        #expect(decoded.networkName == "tenant-net")
        let decodedConfig = try #require(decoded.config)
        #expect(decodedConfig.networkName == "tenant-net")
        #expect(decodedConfig.macAddress == "52:54:00:aa:bb:cc")
        #expect(decodedConfig.ipAddress == "10.1.0.9")
        #expect(decodedConfig.subnet == "10.1.0.0/24")
        #expect(decodedConfig.gateway == "10.1.0.1")
        #expect(decodedConfig.vlanId == 42)
        #expect(decodedConfig.portSecurity == false)
        #expect(decodedConfig.dhcp == false)
    }

    @Test func networkDetachRoundTrip() throws {
        let decoded = try throughEnvelope(
            NetworkDetachMessage(requestId: Fixtures.requestId, timestamp: Fixtures.timestamp, vmId: "vm-2")
        )
        #expect(decoded.type == .networkDetach)
        #expect(decoded.vmId == "vm-2")
    }

    @Test func vmNetworkInfoRoundTrip() throws {
        let info = VMNetworkInfo(
            vmId: "vm-2",
            networkName: "tenant-net",
            portName: "port-vm-2",
            portUUID: Fixtures.uuidA.uuidString,
            tapInterface: "tap0",
            macAddress: "52:54:00:aa:bb:cc",
            ipAddress: "10.1.0.9",
            status: .pending,
            createdAt: Fixtures.timestamp
        )
        let decoded = try roundTrip(info)
        #expect(decoded.vmId == "vm-2")
        #expect(decoded.portName == "port-vm-2")
        #expect(decoded.portUUID == Fixtures.uuidA.uuidString)
        #expect(decoded.tapInterface == "tap0")
        #expect(decoded.status == .pending)
        #expect(decoded.createdAt == Fixtures.timestamp)
    }

    @Test func networkInfoModelRoundTrip() throws {
        let info = NetworkInfo(
            name: "tenant-net",
            uuid: Fixtures.uuidB.uuidString,
            subnet: "10.1.0.0/24",
            gateway: "10.1.0.1",
            vlanId: 42,
            dhcpEnabled: true,
            dnsServers: ["1.1.1.1"],
            status: .creating,
            portCount: 3,
            createdAt: Fixtures.timestamp,
            updatedAt: Fixtures.laterDate
        )
        let decoded = try roundTrip(info)
        #expect(decoded.name == "tenant-net")
        #expect(decoded.uuid == Fixtures.uuidB.uuidString)
        #expect(decoded.status == .creating)
        #expect(decoded.portCount == 3)
        #expect(decoded.dnsServers == ["1.1.1.1"])
        #expect(decoded.updatedAt == Fixtures.laterDate)
    }
}
