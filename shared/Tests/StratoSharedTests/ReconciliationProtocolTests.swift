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
                        architecture: .x86_64,
                        artifacts: [
                            ArtifactInfo(
                                kind: .diskImage, filename: "debian.qcow2",
                                checksum: String(repeating: "a", count: 64), size: 1024,
                                downloadURL: "https://example.test/dl?artifact=disk-image")
                        ]
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

        let decoded = try envelope.decode(as: DesiredStateMessage.self)
        #expect(decoded.syncId == message.syncId)
        #expect(decoded.vms.count == 1)
        #expect(decoded.vms[0].vmId == message.vms[0].vmId)
        #expect(decoded.vms[0].desiredStatus == .running)
        #expect(decoded.vms[0].generation == 7)
        #expect(decoded.vms[0].imageInfo?.artifact(ofKind: .diskImage)?.filename == "debian.qcow2")
    }

    @Test("A clone source carries the source VM serialization lane")
    func cloneSourceVMLaneRoundTrip() throws {
        let sourceVolumeId = UUID()
        let sourceVMId = UUID()
        let source = DesiredVolumeSource.clone(
            from: sourceVolumeId, sourceVMId: sourceVMId, format: "qcow2")
        let decoded = try roundTrip(source)

        #expect(decoded.kind == DesiredVolumeSource.clone)
        #expect(decoded.sourceVolumeId == sourceVolumeId)
        #expect(decoded.sourceVMId == sourceVMId)
        #expect(decoded.sourceFormat == "qcow2")
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
                    metadataEnabled: true,
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
        #expect(decoded.networks[0].metadataEnabled == true)
        // Same router key: both networks share one per-project logical router.
        #expect(decoded.networks[1].routerKey == projectKey)
        #expect(decoded.networks[1].gateway == nil)
        #expect(decoded.networks[1].subnet6 == nil)
        #expect(decoded.networks[1].gateway6 == nil)
        #expect(decoded.networks[1].dhcpEnabled == false)
        #expect(decoded.networks[1].metadataEnabled == false)
        #expect(!decoded.networks[1].externalAccess)
    }

    @Test("DesiredNetworkState requires authoritative service fields")
    func desiredNetworkStateRequiresServiceFields() throws {
        let legacy = """
            {"networkId":"\(UUID().uuidString)","name":"default","subnet":"192.168.1.0/24",
             "gateway":"192.168.1.1","routerKey":"project-x","externalAccess":true,"generation":1}
            """
        #expect(throws: DecodingError.self) {
            try decodeJSON(DesiredNetworkState.self, from: legacy)
        }
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

    @Test("The current desired schema requires every authoritative collection")
    func desiredStateRequiresCurrentCollections() throws {
        let encoded = try WireProtocol.makeEncoder().encode(DesiredStateMessage(syncId: "s", vms: []))
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        for key in [
            "sandboxes", "networks", "networksAuthoritative", "tombstones", "volumes", "snapshots",
        ] {
            var malformed = object
            malformed.removeValue(forKey: key)
            let data = try JSONSerialization.data(withJSONObject: malformed)
            #expect(throws: DecodingError.self, "missing required key: \(key)") {
                try WireProtocol.makeDecoder().decode(DesiredStateMessage.self, from: data)
            }
        }
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
                    failedGeneration: 3,
                    failureClassification: .blocked
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
        #expect(decoded.vms[1].failureClassification == .blocked)
        #expect(decoded.vms[0].failureClassification == nil)
        // No qga probe: guestInfo stays nil rather than a fabricated empty.
        #expect(decoded.vms[0].guestInfo == nil)
    }

    @Test("The current observed schema requires sandbox and unrecognized inventories")
    func observedStateRequiresCurrentCollections() throws {
        let report = ObservedStateReport(
            agentId: "agent-1", vms: [], resources: Fixtures.resources)
        let encoded = try WireProtocol.makeEncoder().encode(report)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        for key in ["sandboxes", "unrecognized"] {
            var malformed = object
            malformed.removeValue(forKey: key)
            let data = try JSONSerialization.data(withJSONObject: malformed)
            #expect(throws: DecodingError.self, "missing required key: \(key)") {
                try WireProtocol.makeDecoder().decode(ObservedStateReport.self, from: data)
            }
        }
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
            {"vmId":"\(UUID().uuidString)","status":"Running","observedGeneration":2,
             "appliedNetworkInterfaceIds":[]}
            """
        let decoded = try decodeJSON(ObservedVMState.self, from: legacy)
        #expect(decoded.guestInfo == nil)
        #expect(decoded.status == .running)
        #expect(decoded.observedGeneration == 2)
    }

    @Test("ObservedVMState carries balloon memoryStats through the envelope (issue #567)")
    func observedStateMemoryStatsRoundTrip() throws {
        let message = ObservedStateReport(
            agentId: "agent-1",
            vms: [
                ObservedVMState(
                    vmId: UUID(),
                    status: .running,
                    observedGeneration: 4,
                    memoryStats: VMMemoryStats(
                        totalBytes: 8_254_390_272,
                        availableBytes: 6_442_450_944
                    )
                ),
                // A guest without the virtio_balloon driver reports nothing:
                // nil survives, never a fabricated zero.
                ObservedVMState(vmId: UUID(), status: .running, observedGeneration: 4),
            ],
            resources: AgentResources(
                totalCPU: 8, availableCPU: 4,
                totalMemory: 16, availableMemory: 8,
                totalDisk: 100, availableDisk: 50
            )
        )
        let decoded = try MessageEnvelope(message: message).decode(as: ObservedStateReport.self)
        let stats = try #require(decoded.vms.first?.memoryStats)
        #expect(stats.totalBytes == 8_254_390_272)
        #expect(stats.availableBytes == 6_442_450_944)
        #expect(decoded.vms[1].memoryStats == nil)
    }

    @Test("ObservedVMState from a pre-v16 agent (no memoryStats key) decodes to nil")
    func observedStateMemoryStatsBackwardCompatible() throws {
        let legacy = """
            {"vmId":"\(UUID().uuidString)","status":"Running","observedGeneration":2,
             "appliedNetworkInterfaceIds":[]}
            """
        let decoded = try decodeJSON(ObservedVMState.self, from: legacy)
        #expect(decoded.memoryStats == nil)
        #expect(decoded.appliedNetworkInterfaceIds == [])
    }

    @Test("Observed workload resource telemetry preserves zero and unavailable signals")
    func observedStateResourceTelemetryRoundTrip() throws {
        let resourceTelemetry = WorkloadResourceTelemetry(
            sampledAt: Date(timeIntervalSince1970: 1_000),
            health: .healthy,
            cgroupV2: .available,
            memoryCurrentBytes: .available(0),
            memoryEvents: WorkloadMemoryEventsTelemetry(
                availability: .available, low: 0, high: 0, max: 0,
                oom: 0, oomKill: 0, oomGroupKill: 0),
            memoryPressure: .unavailable,
            cpuPressure: .unavailable,
            ioPressure: .unavailable,
            cpuUsageMicroseconds: .available(0),
            cpuThrottledMicroseconds: .available(0),
            cpuThrottledPeriodsTotal: .available(0),
            guestStealMicroseconds: .unavailable)
        let original = ObservedVMState(
            vmId: UUID(), status: .running, observedGeneration: 1,
            resourceTelemetry: resourceTelemetry)
        let decoded = try roundTrip(original)

        #expect(decoded.resourceTelemetry == resourceTelemetry)
        #expect(decoded.resourceTelemetry?.memoryCurrentBytes.value == 0)
        #expect(decoded.resourceTelemetry?.guestStealMicroseconds.availability == .unavailable)

        let legacy = """
            {"vmId":"\(UUID().uuidString)","status":"Running","observedGeneration":2,
             "appliedNetworkInterfaceIds":[]}
            """
        #expect(try decodeJSON(ObservedVMState.self, from: legacy).resourceTelemetry == nil)
    }

    @Test("ObservedVMState carries applied interface ids and preserves an authoritative empty list")
    func observedStateAppliedInterfaceIDsRoundTrip() throws {
        let first = UUID()
        let withNIC = try roundTrip(
            ObservedVMState(
                vmId: UUID(), status: .running, observedGeneration: 8,
                appliedNetworkInterfaceIds: [first]))
        #expect(withNIC.appliedNetworkInterfaceIds == [first])

        let networkless = try roundTrip(
            ObservedVMState(
                vmId: UUID(), status: .shutdown, observedGeneration: 9,
                appliedNetworkInterfaceIds: []))
        #expect(networkless.appliedNetworkInterfaceIds == [])

        let unknown = try roundTrip(
            ObservedVMState(vmId: UUID(), status: .unknown, observedGeneration: 0))
        #expect(unknown.appliedNetworkInterfaceIds == nil)
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

    @Test("DesiredStateMessage carries DNS zones through the envelope")
    func desiredDNSZonesRoundTrip() throws {
        let zoneID = UUID()
        let networkID = UUID()
        let message = DesiredStateMessage(
            vms: [],
            dnsZones: [
                DesiredDNSZone(
                    zoneId: zoneID,
                    zoneName: "acme.internal",
                    networkIds: [networkID],
                    records: [
                        DesiredDNSRecord(
                            name: "web.acme.internal", type: "A", values: ["10.0.0.5", "10.0.0.6"]),
                        DesiredDNSRecord(
                            name: "5.0.0.10.in-addr.arpa", type: "PTR", values: ["web.acme.internal"]),
                    ],
                    recordsHash: "abc123")
            ])
        let decoded = try MessageEnvelope(message: message).decode(as: DesiredStateMessage.self)
        let zone = try #require(decoded.dnsZones?.first)
        #expect(zone.zoneId == zoneID)
        #expect(zone.zoneName == "acme.internal")
        #expect(zone.networkIds == [networkID])
        #expect(zone.recordsHash == "abc123")
        #expect(zone.records.count == 2)
        #expect(zone.records[0].values == ["10.0.0.5", "10.0.0.6"])
    }

    @Test("A non-authoritative sync without DNS zones decodes to nil")
    func desiredDNSZonesSemanticAbsence() throws {
        // Nil is what makes the agent leave every managed DNS row alone; `[]`
        // would have it sweep the site's rows.
        let nonAuthoritative = """
            {"requestId":"r","timestamp":0,"syncId":"s","vms":[],"sandboxes":[],
             "networks":[],"networksAuthoritative":false,"tombstones":[],"volumes":[],"snapshots":[],
             "cephCredentialRevocations":[]}
            """
        let decoded = try WireProtocol.makeDecoder().decode(
            DesiredStateMessage.self, from: Data(nonAuthoritative.utf8))
        #expect(decoded.dnsZones == nil)

        let empty = DesiredStateMessage(vms: [], dnsZones: [])
        let decodedEmpty = try MessageEnvelope(message: empty).decode(as: DesiredStateMessage.self)
        #expect(decodedEmpty.dnsZones?.isEmpty == true)
    }

    @Test("An unknown record type decodes rather than failing the whole sync")
    func desiredDNSRecordUnknownType() throws {
        // Types travel as strings precisely so a newer control plane's
        // vocabulary reaches an older agent as an entry it can skip.
        let payload = """
            {"name":"acme.internal","type":"CAA","ttl":300,"values":["0 issue \\"letsencrypt.org\\""]}
            """
        let decoded = try WireProtocol.makeDecoder().decode(
            DesiredDNSRecord.self, from: Data(payload.utf8))
        #expect(decoded.type == "CAA")
    }

    // MARK: - Per-network resolver (wire v37, STR-40)

    @Test("resolverEnabled rides the network carrier and survives a round trip")
    func desiredNetworkResolverRoundTrip() throws {
        let network = DesiredNetworkState(
            networkId: UUID(), name: "default", subnet: "10.0.0.0/24", gateway: "10.0.0.1",
            routerKey: "project-x", externalAccess: false, metadataEnabled: true,
            resolverEnabled: true, generation: 3)
        let message = DesiredStateMessage(vms: [], networks: [network])
        let decoded = try MessageEnvelope(message: message).decode(as: DesiredStateMessage.self)
        #expect(decoded.networks.first?.resolverEnabled == true)
    }

    @Test("A sync without resolverEnabled decodes to nil, never to off")
    func resolverEnabledAbsenceIsSilence() throws {
        // Reading a pre-v37 control plane's silence as "off" would strip the
        // resolver's addresses from every localport on the host during a
        // rollback — the teardown-on-omission failure the protocol's absence
        // rules exist to prevent.
        let legacy = """
            {"networkId":"\(UUID().uuidString)","name":"default","subnet":"10.0.0.0/24",\
            "routerKey":"k","externalAccess":false,"dhcpEnabled":false,"dnsServers":[],\
            "metadataEnabled":false,"floatingIPs":[],"loadBalancers":[],"generation":1}
            """
        let decoded = try WireProtocol.makeDecoder().decode(
            DesiredNetworkState.self, from: Data(legacy.utf8))
        #expect(decoded.resolverEnabled == nil)
        #expect(decoded.metadataEnabled == false)
    }

    @Test("NetworkSpec carries the per-NIC resolver flag, which is what reaches the chassis")
    func networkSpecResolverRoundTrip() throws {
        // A sited non-authority agent receives an empty `networks` list by
        // design, so its own workloads' specs are the only input it has.
        let spec = NetworkSpec(
            network: "default", networkId: UUID(), dhcpEnabled: true,
            dnsServers: ["1.1.1.1"], domainName: "corp.example.com",
            metadataEnabled: true, resolverEnabled: true)
        let data = try WireProtocol.makeEncoder().encode(spec)
        let decoded = try WireProtocol.makeDecoder().decode(NetworkSpec.self, from: data)
        #expect(decoded.resolverEnabled == true)
        // The resolver's upstreams and search domain ride fields that already
        // existed, so no other field was needed.
        #expect(decoded.dnsServers == ["1.1.1.1"])
        #expect(decoded.domainName == "corp.example.com")
    }

    @Test("A NetworkSpec with no resolver opinion decodes with a nil flag")
    func networkSpecResolverSemanticAbsence() throws {
        let noOpinion = """
            {"network":"default","networkId":"\(UUID().uuidString)",
             "dhcpEnabled":false,"dnsServers":[],"metadataEnabled":false}
            """
        let decoded = try WireProtocol.makeDecoder().decode(NetworkSpec.self, from: Data(noOpinion.utf8))
        #expect(decoded.resolverEnabled == nil)
    }

    @Test("A record's TTL travels, which is what a zone file needs and OVN never did")
    func desiredDNSRecordTTLRoundTrip() throws {
        let record = DesiredDNSRecord(name: "web.acme.internal", type: "A", values: ["10.0.0.5"], ttl: 60)
        let data = try WireProtocol.makeEncoder().encode(record)
        let decoded = try WireProtocol.makeDecoder().decode(DesiredDNSRecord.self, from: data)
        #expect(decoded.ttl == 60)
    }

    @Test("A record requires an explicit TTL")
    func desiredDNSRecordRequiresTTL() throws {
        let legacy = """
            {"name":"web.acme.internal","type":"A","values":["10.0.0.5"]}
            """
        #expect(throws: DecodingError.self) {
            try WireProtocol.makeDecoder().decode(
                DesiredDNSRecord.self, from: Data(legacy.utf8))
        }
    }

    @Test("resolverCapable rides registration and is required")
    func agentRegisterResolverCapable() throws {
        // Speaking v37 is not the same as having a CoreDNS; the two are folded
        // site-wide before the control plane enables any network's resolver.
        let message = AgentRegisterMessage(
            agentId: "a", hostname: "h", version: "1",
            resources: AgentResources(
                totalCPU: 1, availableCPU: 1, totalMemory: 1, availableMemory: 1, totalDisk: 1,
                availableDisk: 1),
            resolverCapable: true)
        let decoded = try MessageEnvelope(message: message).decode(as: AgentRegisterMessage.self)
        #expect(decoded.resolverCapable == true)

        let withoutCapability = """
            {"requestId":"r","timestamp":0,"agentId":"a","hostname":"h","version":"1",\
            "resources":{"totalCPU":1,"totalMemory":1,"totalDisk":1,\
            "availableCPU":1,"availableMemory":1,"availableDisk":1},\
            "protocolVersion":\(WireProtocol.currentVersion),"dependencyObservations":[]}
            """
        #expect(throws: DecodingError.self) {
            try WireProtocol.makeDecoder().decode(
                AgentRegisterMessage.self, from: Data(withoutCapability.utf8))
        }
    }

    @Test("Each network's resolver addresses are distinct and derive from one index")
    func resolverAddressesAreDistinctPerNetwork() {
        // The property the whole design rests on: distinct addresses are what
        // let every resolver on a host share the *host* namespace, which is what
        // lets them forward at all.
        let first = NetworkResolverEndpoint.firstIndex
        #expect(NetworkResolverEndpoint.address(forIndex: first) == "169.254.1.0")
        #expect(NetworkResolverEndpoint.address(forIndex: first + 1) == "169.254.1.1")
        #expect(NetworkResolverEndpoint.address(forIndex: 512) == "169.254.2.0")
        #expect(
            NetworkResolverEndpoint.address(forIndex: NetworkResolverEndpoint.lastIndex)
                == "169.254.254.255")
        #expect(NetworkResolverEndpoint.addressV6(forIndex: first) == "fd00:ec2:1::100")
        // Disjoint from the instance metadata ULA, while sharing the /32 the
        // security-group carve-out matches.
        #expect(!NetworkResolverEndpoint.addressV6(forIndex: first).hasPrefix("fd00:ec2::"))
    }

    @Test("The metadata address is never handed to a network")
    func metadataAddressIsReserved() {
        // 169.254.169.254 falls inside the allocatable range, so without the
        // reservation a network would eventually be given the metadata address
        // and its guests' DNS would arrive at a namespace serving HTTP.
        let metadata = (169 << 8) | 254
        #expect(NetworkResolverEndpoint.address(forIndex: metadata) == "169.254.169.254")
        #expect(!NetworkResolverEndpoint.isValidIndex(metadata))
        #expect(!NetworkResolverEndpoint.isValidIndex((169 << 8) | 253))
        #expect(NetworkResolverEndpoint.isValidIndex(NetworkResolverEndpoint.firstIndex))
        #expect(!NetworkResolverEndpoint.isValidIndex(NetworkResolverEndpoint.firstIndex - 1))
        #expect(!NetworkResolverEndpoint.isValidIndex(NetworkResolverEndpoint.lastIndex + 1))
    }

    @Test("Routing tables are per network and clear of the reserved ids")
    func routingTablesAreSafe() {
        // 253/254/255 are `default`/`main`/`local`; colliding would silently
        // merge a tenant network's routes into the host's own table.
        #expect(
            NetworkResolverEndpoint.routingTable(forIndex: NetworkResolverEndpoint.firstIndex) > 255)
        #expect(
            NetworkResolverEndpoint.routingTable(forIndex: 1)
                != NetworkResolverEndpoint.routingTable(forIndex: 2))
    }

    @Test("The resolver addresses ride both carriers")
    func resolverAddressesRoundTrip() throws {
        let addresses = ["169.254.1.0", "fd00:ec2:1::100"]
        let network = DesiredNetworkState(
            networkId: UUID(), name: "default", subnet: "10.0.0.0/24", gateway: "10.0.0.1",
            routerKey: "k", externalAccess: false, resolverEnabled: true,
            resolverAddresses: addresses, generation: 1)
        let decoded = try MessageEnvelope(message: DesiredStateMessage(vms: [], networks: [network]))
            .decode(as: DesiredStateMessage.self)
        #expect(decoded.networks.first?.resolverAddresses == addresses)

        let spec = NetworkSpec(
            network: "default", networkId: UUID(), resolverEnabled: true,
            resolverAddresses: addresses)
        let data = try WireProtocol.makeEncoder().encode(spec)
        #expect(
            try WireProtocol.makeDecoder().decode(NetworkSpec.self, from: data).resolverAddresses
                == addresses)
    }
}
