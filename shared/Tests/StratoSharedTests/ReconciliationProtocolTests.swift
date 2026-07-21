import Testing
import Foundation
@testable import StratoShared

@Suite("Reconciliation Protocol Tests")
struct ReconciliationProtocolTests {

    private func makeDesiredState() -> DesiredStateMessage {
        DesiredStateMessage(
            syncId: "sync-1",
            vms: [
                DesiredVMState(
                    vmId: UUID(),
                    hypervisorType: .qemu,
                    spec: VMSpec(cpus: 2, memoryBytes: 2 << 30, boot: .disk(firmware: nil)),
                    desiredStatus: .running,
                    generation: 7,
                    imageInfo: ImageInfo(
                        imageId: UUID(),
                        projectId: UUID(),
                        filename: "debian.qcow2",
                        checksum: "abc",
                        size: 1024,
                        downloadURL: "https://example.test/dl"
                    )
                )
            ]
        )
    }

    @Test("DesiredStateMessage round-trips through the envelope")
    func desiredStateRoundTrip() throws {
        let message = makeDesiredState()
        let envelope = try MessageEnvelope(message: message)
        #expect(envelope.type == .desiredState)
        #expect(envelope.senderVersion == WireProtocol.currentVersion)

        let decoded = try envelope.decode(as: DesiredStateMessage.self)
        #expect(decoded.syncId == message.syncId)
        #expect(decoded.vms.count == 1)
        #expect(decoded.vms[0].vmId == message.vms[0].vmId)
        #expect(decoded.vms[0].desiredStatus == .running)
        #expect(decoded.vms[0].generation == 7)
        #expect(decoded.vms[0].imageInfo?.filename == "debian.qcow2")
    }

    @Test("DesiredStateMessage carries networks through the envelope")
    func desiredStateNetworksRoundTrip() throws {
        let networkId = UUID()
        let projectKey = "project-\(UUID().uuidString)"
        let message = DesiredStateMessage(
            syncId: "sync-net",
            vms: [],
            networks: [
                DesiredNetworkState(
                    networkId: networkId,
                    name: "default",
                    subnet: "192.168.1.0/24",
                    gateway: "192.168.1.1",
                    subnet6: "fd12:3456:789a::/64",
                    gateway6: "fd12:3456:789a::1",
                    routerKey: projectKey,
                    externalAccess: true,
                    dhcpEnabled: true,
                    dnsServers: ["1.1.1.1", "fd00::53"],
                    domainName: "corp.example.com",
                    leaseTime: 7200,
                    generation: 4
                ),
                DesiredNetworkState(
                    networkId: UUID(),
                    name: "isolated",
                    subnet: "10.0.5.0/24",
                    gateway: nil,
                    routerKey: projectKey,
                    externalAccess: false,
                    generation: 1
                ),
            ]
        )
        let envelope = try MessageEnvelope(message: message)
        let decoded = try envelope.decode(as: DesiredStateMessage.self)

        #expect(decoded.networks.count == 2)
        #expect(decoded.networks[0].networkId == networkId)
        #expect(decoded.networks[0].subnet == "192.168.1.0/24")
        #expect(decoded.networks[0].gateway == "192.168.1.1")
        #expect(decoded.networks[0].routerKey == projectKey)
        #expect(decoded.networks[0].externalAccess)
        #expect(decoded.networks[0].generation == 4)
        #expect(decoded.networks[0].subnet6 == "fd12:3456:789a::/64")
        #expect(decoded.networks[0].gateway6 == "fd12:3456:789a::1")
        #expect(decoded.networks[0].dhcpEnabled == true)
        #expect(decoded.networks[0].dnsServers == ["1.1.1.1", "fd00::53"])
        #expect(decoded.networks[0].domainName == "corp.example.com")
        #expect(decoded.networks[0].leaseTime == 7200)
        // Same router key: both networks share one per-project logical router.
        #expect(decoded.networks[1].routerKey == projectKey)
        #expect(decoded.networks[1].gateway == nil)
        #expect(decoded.networks[1].subnet6 == nil)
        #expect(decoded.networks[1].gateway6 == nil)
        #expect(decoded.networks[1].dhcpEnabled == nil)
        #expect(!decoded.networks[1].externalAccess)
    }

    @Test("DesiredNetworkState without v6/DHCP keys (older control plane) decodes to nils")
    func desiredNetworkStateBackwardCompatibleIPv6() throws {
        let legacy = """
            {"networkId":"\(UUID().uuidString)","name":"default","subnet":"192.168.1.0/24",
             "gateway":"192.168.1.1","routerKey":"project-x","externalAccess":true,"generation":1}
            """
        let decoded = try decodeJSON(DesiredNetworkState.self, from: legacy)
        #expect(decoded.subnet6 == nil)
        #expect(decoded.gateway6 == nil)
        // Nil (not false): the agent must leave DHCP rows alone rather than
        // delete them when a pre-field control plane says nothing.
        #expect(decoded.dhcpEnabled == nil)
        #expect(decoded.dnsServers == nil)
        #expect(decoded.subnet == "192.168.1.0/24")
    }

    @Test("DesiredStateMessage carries topology authority through the envelope")
    func desiredStateAuthorityRoundTrip() throws {
        let peer = DesiredStateMessage(syncId: "sync-peer", vms: [], networksAuthoritative: false)
        let decodedPeer = try MessageEnvelope(message: peer).decode(as: DesiredStateMessage.self)
        #expect(!decodedPeer.networksAuthoritative)

        // Default: an agent that owns its NB (site-less) is authoritative.
        let solo = DesiredStateMessage(syncId: "sync-solo", vms: [])
        let decodedSolo = try MessageEnvelope(message: solo).decode(as: DesiredStateMessage.self)
        #expect(decodedSolo.networksAuthoritative)
    }

    @Test("DesiredStateMessage from an older control plane decodes networks to []")
    func desiredStateNetworksBackwardCompatible() throws {
        // A pre-v3 control plane emits no `networks` key at all; the agent must
        // tolerate its absence rather than fail the whole sync.
        let legacy = """
            {"requestId":"r","timestamp":0,"syncId":"s","vms":[]}
            """
        let decoded = try WireProtocol.makeDecoder().decode(
            DesiredStateMessage.self, from: Data(legacy.utf8))
        #expect(decoded.networks.isEmpty)
        #expect(decoded.syncId == "s")
        // Every control plane predating the site/shared-NB protocol implies the
        // agent owns its local NB, so absence must decode to authoritative.
        #expect(decoded.networksAuthoritative)
    }

    @Test("ObservedStateReport round-trips through the envelope")
    func observedStateRoundTrip() throws {
        let message = ObservedStateReport(
            agentId: "agent-1",
            vms: [
                ObservedVMState(
                    vmId: UUID(),
                    status: .running,
                    observedGeneration: 7,
                    convergencePhase: nil,
                    lastError: nil
                ),
                ObservedVMState(
                    vmId: UUID(),
                    status: .unknown,
                    observedGeneration: 0,
                    convergencePhase: "downloading image",
                    lastError: "previous attempt: disk full",
                    failedGeneration: 3
                ),
            ],
            resources: AgentResources(
                totalCPU: 8, availableCPU: 4,
                totalMemory: 16, availableMemory: 8,
                totalDisk: 100, availableDisk: 50
            )
        )
        let envelope = try MessageEnvelope(message: message)
        #expect(envelope.type == .observedState)

        let decoded = try envelope.decode(as: ObservedStateReport.self)
        #expect(decoded.agentId == "agent-1")
        #expect(decoded.vms.count == 2)
        #expect(decoded.vms[0].observedGeneration == 7)
        #expect(decoded.vms[1].convergencePhase == "downloading image")
        #expect(decoded.vms[1].lastError == "previous attempt: disk full")
        #expect(decoded.vms[1].failedGeneration == 3)
        // No qga probe: guestInfo stays nil rather than a fabricated empty.
        #expect(decoded.vms[0].guestInfo == nil)
    }

    @Test("ObservedVMState carries qga guestInfo through the envelope (issue #563)")
    func observedStateGuestInfoRoundTrip() throws {
        let vmId = UUID()
        let message = ObservedStateReport(
            agentId: "agent-1",
            vms: [
                ObservedVMState(
                    vmId: vmId,
                    status: .running,
                    observedGeneration: 4,
                    guestInfo: GuestInfo(
                        qgaAvailable: true,
                        hostname: "web-01",
                        interfaces: [
                            GuestNetworkInterface(
                                name: "enp0s3",
                                hardwareAddress: "52:54:00:12:34:56",
                                addresses: [
                                    GuestIPAddress(family: .ipv4, address: "10.0.0.5", prefixLength: 24),
                                    GuestIPAddress(
                                        family: .ipv6, address: "fe80::5054:ff:fe12:3456", prefixLength: 64),
                                ]
                            ),
                            GuestNetworkInterface(name: "lo", hardwareAddress: nil, addresses: []),
                        ]
                    )
                )
            ],
            resources: AgentResources(
                totalCPU: 8, availableCPU: 4,
                totalMemory: 16, availableMemory: 8,
                totalDisk: 100, availableDisk: 50
            )
        )
        let decoded = try MessageEnvelope(message: message).decode(as: ObservedStateReport.self)
        let guest = try #require(decoded.vms.first?.guestInfo)
        #expect(guest.qgaAvailable)
        #expect(guest.hostname == "web-01")
        #expect(guest.interfaces.count == 2)
        let eth = try #require(guest.interfaces.first { $0.name == "enp0s3" })
        #expect(eth.hardwareAddress == "52:54:00:12:34:56")
        #expect(eth.addresses.count == 2)
        #expect(eth.addresses[0].family == .ipv4)
        #expect(eth.addresses[0].address == "10.0.0.5")
        #expect(eth.addresses[0].prefixLength == 24)
        #expect(eth.addresses[1].family == .ipv6)
        // The MAC-less loopback interface survives the round trip.
        let lo = try #require(guest.interfaces.first { $0.name == "lo" })
        #expect(lo.hardwareAddress == nil)
        #expect(lo.addresses.isEmpty)
    }

    @Test("ObservedVMState from an older agent (no guestInfo key) decodes to nil")
    func observedStateGuestInfoBackwardCompatible() throws {
        // A pre-v15 agent emits no `guestInfo` key at all; the control plane
        // must tolerate its absence rather than fail to decode the report.
        let legacy = """
            {"vmId":"\(UUID().uuidString)","status":"Running","observedGeneration":2}
            """
        let decoded = try decodeJSON(ObservedVMState.self, from: legacy)
        #expect(decoded.guestInfo == nil)
        #expect(decoded.status == .running)
        #expect(decoded.observedGeneration == 2)
    }

    @Test("DesiredVMStatus decoding is strict: unknown values fail the sync")
    func desiredStatusStrictDecoding() throws {
        let decoder = WireProtocol.makeDecoder()
        // Misinterpreting a desired status could stop or delete a running VM,
        // so — unlike VMStatus — there is deliberately no tolerant fallback.
        #expect(throws: (any Error).self) {
            _ = try decoder.decode(DesiredVMStatus.self, from: Data("\"Hibernated\"".utf8))
        }
    }

    @Test("Desired status satisfaction mapping")
    func desiredStatusSatisfaction() {
        #expect(DesiredVMStatus.running.isSatisfied(by: .running))
        #expect(!DesiredVMStatus.running.isSatisfied(by: .paused))
        #expect(DesiredVMStatus.paused.isSatisfied(by: .paused))
        // A defined-but-never-booted VM satisfies "shutdown" — same resting state.
        #expect(DesiredVMStatus.shutdown.isSatisfied(by: .created))
        #expect(DesiredVMStatus.shutdown.isSatisfied(by: .shutdown))
        #expect(!DesiredVMStatus.shutdown.isSatisfied(by: .running))
        // Absence is confirmed by omission from the observed set, never by a status.
        for status in VMStatus.allCases {
            #expect(!DesiredVMStatus.absent.isSatisfied(by: status))
        }
    }

    @Test("State-sync support rejects peers that can emit imperative VM messages")
    func stateSyncVersionGate() {
        #expect(!WireProtocol.supportsStateSync(0))
        #expect(!WireProtocol.supportsStateSync(1))
        #expect(WireProtocol.supportsStateSync(2))
        #expect(WireProtocol.supportsStateSync(3))
        #expect(WireProtocol.supportsStateSync(WireProtocol.currentVersion))
    }

    @Test("Network-sync support is keyed on protocol version 3")
    func networkSyncVersionGate() {
        // A v2 control plane omits `networks`; the agent must not treat the
        // decoded-empty list as an authoritative teardown of all L3.
        #expect(!WireProtocol.supportsNetworkSync(2))
        #expect(WireProtocol.supportsNetworkSync(3))
        #expect(WireProtocol.supportsNetworkSync(WireProtocol.currentVersion))
    }

    @Test("Site-authority support is keyed on protocol version 4")
    func siteAuthorityVersionGate() {
        // A v3 agent ignores `networksAuthoritative`, so a non-authoritative
        // empty sync would read as an authoritative teardown of all its L3 —
        // the control plane must never send that shape to pre-v4 agents.
        #expect(!WireProtocol.supportsSiteAuthority(3))
        #expect(WireProtocol.supportsSiteAuthority(4))
        #expect(WireProtocol.supportsSiteAuthority(WireProtocol.currentVersion))
    }
}
