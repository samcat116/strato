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
            NetworkDeleteMessage(requestId: Fixtures.requestId, timestamp: Fixtures.timestamp, networkName: "tenant-net")
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

    @Test func securityGroupRoundTrip() throws {
        let rule = SecurityRule(
            id: Fixtures.uuidA,
            direction: .ingress,
            action: .allow,
            networkProtocol: .tcp,
            sourceAddress: "0.0.0.0/0",
            destinationAddress: "10.1.0.9/32",
            sourcePort: PortRange(start: 1024, end: 65535),
            destinationPort: PortRange(start: 443),
            priority: 100,
            description: "allow https"
        )
        let group = NetworkSecurityGroup(
            id: Fixtures.uuidB,
            name: "web",
            description: "web tier",
            rules: [rule],
            appliedPorts: ["port-1"],
            organizationId: "org-1",
            createdAt: Fixtures.timestamp,
            updatedAt: Fixtures.laterDate
        )
        let decoded = try roundTrip(group)
        #expect(decoded.id == Fixtures.uuidB)
        #expect(decoded.name == "web")
        #expect(decoded.appliedPorts == ["port-1"])
        let decodedRule = try #require(decoded.rules.first)
        #expect(decodedRule.id == Fixtures.uuidA)
        #expect(decodedRule.direction == .ingress)
        #expect(decodedRule.action == .allow)
        #expect(decodedRule.networkProtocol == .tcp)
        #expect(decodedRule.sourcePort?.start == 1024)
        #expect(decodedRule.sourcePort?.end == 65535)
        // Single-port ranges collapse end to start at init time.
        #expect(decodedRule.destinationPort?.start == 443)
        #expect(decodedRule.destinationPort?.end == 443)
        #expect(decodedRule.priority == 100)
    }

    @Test func loadBalancerConfigRoundTrip() throws {
        let config = LoadBalancerConfig(
            id: Fixtures.uuidA,
            name: "lb-web",
            algorithm: .leastConnections,
            frontendIPs: ["203.0.113.1"],
            frontendPort: 443,
            backendIPs: ["10.1.0.9", "10.1.0.10"],
            backendPort: 8443,
            networkProtocol: .tcp,
            healthCheck: HealthCheckConfig(networkProtocol: .tcp, port: 8443, path: "/healthz", interval: 10, timeout: 2, retries: 5),
            stickySession: true
        )
        let decoded = try roundTrip(config)
        #expect(decoded.algorithm == .leastConnections)
        #expect(decoded.backendIPs == ["10.1.0.9", "10.1.0.10"])
        #expect(decoded.healthCheck?.path == "/healthz")
        #expect(decoded.healthCheck?.interval == 10)
        #expect(decoded.healthCheck?.retries == 5)
        #expect(decoded.stickySession)
    }

    @Test func networkStatisticsRoundTrip() throws {
        let stats = NetworkStatistics(
            portName: "port-1",
            bytesReceived: 18_446_744_073_709_551_615, // UInt64.max must survive JSON
            bytesSent: 42,
            packetsReceived: 7,
            packetsSent: 8,
            droppedPackets: 1,
            errors: 0,
            timestamp: Fixtures.timestamp
        )
        let decoded = try roundTrip(stats)
        #expect(decoded.bytesReceived == UInt64.max)
        #expect(decoded.bytesSent == 42)
        #expect(decoded.droppedPackets == 1)
        #expect(decoded.timestamp == Fixtures.timestamp)
    }
}
