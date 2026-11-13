import Foundation
import Testing
@testable import StratoShared

@Suite("VMSpec wire format")
struct VMSpecTests {
    @Test func diskBootRoundTrip() throws {
        let spec = VMSpec(cpus: 1, memoryBytes: 536_870_912, boot: .disk(firmware: "/fw/OVMF.fd"))
        let decoded = try roundTrip(spec)
        guard case .disk(let disk) = decoded.boot.value else {
            Issue.record("expected .disk, got \(decoded.boot)")
            return
        }
        #expect(disk.firmware == "/fw/OVMF.fd")
    }

    @Test func diskBootWithDefaultFirmwareRoundTrip() throws {
        let spec = VMSpec(cpus: 1, memoryBytes: 536_870_912, boot: .disk(firmware: nil))
        let decoded = try roundTrip(spec)
        guard case .disk(let disk) = decoded.boot.value else {
            Issue.record("expected .disk, got \(decoded.boot)")
            return
        }
        #expect(!disk.hasFirmware)
    }

    @Test func directKernelBootRoundTrip() throws {
        let spec = VMSpec(
            cpus: 1,
            memoryBytes: 536_870_912,
            boot: .directKernel(
                kernel: "/boot/vmlinux", initramfs: "/boot/initrd", cmdline: "console=ttyS0 root=/dev/vda")
        )
        let decoded = try roundTrip(spec)
        guard case .directKernel(let kernel) = decoded.boot.value else {
            Issue.record("expected .directKernel, got \(decoded.boot)")
            return
        }
        #expect(kernel.kernel == "/boot/vmlinux")
        #expect(kernel.initramfs == "/boot/initrd")
        #expect(kernel.cmdline == "console=ttyS0 root=/dev/vda")
    }

    @Test func fullSpecRoundTrip() throws {
        let spec = VMSpec(
            cpus: 4,
            maxCpus: 8,
            memoryBytes: 8_589_934_592,
            sharedMemory: true,
            hugepages: true,
            boot: .disk(firmware: nil),
            volumes: [
                VolumeSpec(
                    volumeId: Fixtures.uuidA, deviceName: .disk(0),
                    attachment: .file(path: "/v/disk0.qcow2", format: .qcow2), readonly: false,
                    bootOrder: 0),
                VolumeSpec(
                    volumeId: Fixtures.uuidB, deviceName: .disk(1), attachment: nil, readonly: true, bootOrder: 1),
            ],
            networks: [
                NetworkSpec(
                    network: "default", networkId: UUID(), macAddress: "52:54:00:00:00:01", ipAddress: "10.0.0.5",
                    netmask: "255.255.255.0", mtu: 9000),
                NetworkSpec(network: "storage", networkId: UUID()),
            ],
            console: ConsoleSpec()
        )
        let decoded = try roundTrip(spec)
        #expect(decoded._jsonCpus == 4)
        #expect(decoded._jsonMaxCpus == 8)
        #expect(decoded._jsonMemoryBytes == 8_589_934_592)
        #expect(decoded._jsonSharedMemory)
        #expect(decoded._jsonHugepages)

        #expect(decoded._jsonVolumes.count == 2)
        #expect(decoded._jsonVolumes[0]._jsonVolumeId == Fixtures.uuidA)
        #expect(decoded._jsonVolumes[0]._jsonDeviceName.rawValue == "disk0")
        #expect(decoded._jsonVolumes[0]._jsonAttachment == .file(path: "/v/disk0.qcow2", format: .qcow2))
        #expect(decoded._jsonVolumes[0]._jsonBootOrder == 0)
        #expect(decoded._jsonVolumes[1]._jsonVolumeId == Fixtures.uuidB)
        #expect(decoded._jsonVolumes[1]._jsonReadonly)
        #expect(decoded._jsonVolumes[1]._jsonAttachment == nil)

        #expect(decoded._jsonNetworks.count == 2)
        #expect(decoded._jsonNetworks[0]._jsonNetwork == "default")
        #expect(decoded._jsonNetworks[0]._jsonMtu == 9000)
        #expect(decoded._jsonNetworks[1]._jsonNetwork == "storage")
        #expect(decoded._jsonNetworks[1]._jsonMacAddress == nil)

        #expect(decoded._jsonConsole != nil)
    }

    @Test func minimalSpecRoundTrip() throws {
        let decoded = try roundTrip(VMSpec(cpus: 1, memoryBytes: 268_435_456, boot: .disk(firmware: nil)))
        #expect(decoded._jsonMaxCpus == 1)
        #expect(!decoded._jsonSharedMemory)
        #expect(!decoded._jsonHugepages)
        #expect(decoded._jsonVolumes.isEmpty)
        #expect(decoded._jsonNetworks.isEmpty)
        #expect(decoded._jsonConsole == nil)
        #expect(decoded._jsonDiskBytes == nil)
        #expect(!decoded._jsonGuestAgentEnabled)
        #expect(decoded._jsonMetadataSource == .iso)
    }

    @Test func guestAgentOptInRoundTrips() throws {
        let spec = VMSpec(
            cpus: 1, memoryBytes: 268_435_456, boot: .disk(firmware: nil),
            guestAgentEnabled: true)
        #expect(try roundTrip(spec)._jsonGuestAgentEnabled)
    }

    @Test func specWithoutGuestAgentFlagDefaultsOff() throws {
        let json = """
            {"cpus":2,"maxCpus":2,"memoryBytes":1073741824,"maxMemoryBytes":1073741824,
             "sharedMemory":false,"hugepages":false,"boot":{"disk":{}},"volumes":[],"networks":[],
             "sshAuthorizedKeys":[]}
            """
        #expect(try decodeJSON(VMSpec.self, from: json)._jsonGuestAgentEnabled == false)
    }

    @Test func metadataSourceRoundTrips() throws {
        let spec = VMSpec(
            cpus: 1, memoryBytes: 268_435_456, boot: .disk(firmware: nil),
            metadataSource: .imds)
        #expect(try roundTrip(spec)._jsonMetadataSource == .imds)
    }

    @Test func specWithoutMetadataSourceDefaultsToISO() throws {
        let json = """
            {"cpus":2,"maxCpus":2,"memoryBytes":1073741824,"maxMemoryBytes":1073741824,
             "sharedMemory":false,"hugepages":false,"boot":{"disk":{}},"volumes":[],"networks":[],
             "sshAuthorizedKeys":[]}
            """
        #expect(try decodeJSON(VMSpec.self, from: json)._jsonMetadataSource == .iso)
    }

    @Test func copyHelpersReplaceOnlyTheirOwnedFields() {
        let volume = VolumeSpec(volumeId: Fixtures.uuidA, deviceName: .disk(0))
        let network = NetworkSpec(network: "realized", networkId: Fixtures.uuidB)
        let spec = VMSpec(
            cpus: 1, maxCpus: 2, memoryBytes: 1_024, maxMemoryBytes: 2_048,
            balloonTargetBytes: 512, diskBytes: 10, boot: .disk(firmware: nil),
            guestAgentEnabled: true, volumes: [volume], networks: [network], metadataSource: .imds)

        let withoutVolumes = spec.withVolumes([])
        #expect(withoutVolumes._jsonVolumes.isEmpty)
        #expect(withoutVolumes._jsonNetworks == [network])
        #expect(withoutVolumes._jsonGuestAgentEnabled)

        let withoutNetworks = spec.withNetworks([])
        #expect(withoutNetworks._jsonNetworks.isEmpty)
        #expect(withoutNetworks._jsonVolumes.first?._jsonVolumeId == Fixtures.uuidA)
        #expect(withoutNetworks._jsonMetadataSource == .imds)

        let desired = VMSpec(
            cpus: 2, maxCpus: 4, memoryBytes: 2_048, maxMemoryBytes: 4_096,
            balloonTargetBytes: 1_024, diskBytes: 20, sharedMemory: true,
            boot: .directKernel(kernel: "/different", initramfs: nil, cmdline: nil))
        let resized = spec.withSizing(from: desired)
        #expect(resized._jsonCpus == 2)
        #expect(resized._jsonMaxCpus == 4)
        #expect(resized._jsonMemoryBytes == 2_048)
        #expect(resized._jsonMaxMemoryBytes == 4_096)
        #expect(resized._jsonBalloonTargetBytes == 1_024)
        #expect(resized._jsonDiskBytes == 20)
        #expect(!resized._jsonSharedMemory)
        #expect(resized._jsonVolumes.first?._jsonVolumeId == Fixtures.uuidA)
        #expect(resized._jsonNetworks == [network])
        #expect(resized._jsonGuestAgentEnabled)
        #expect(resized._jsonMetadataSource == .imds)
    }

    @Test func unknownMetadataSourceFailsDecode() {
        let json = """
            {"cpus":2,"maxCpus":2,"memoryBytes":1073741824,"maxMemoryBytes":1073741824,
             "sharedMemory":false,"hugepages":false,"boot":{"disk":{}},"volumes":[],"networks":[],
             "sshAuthorizedKeys":[],"metadataSource":"future"}
            """
        #expect(throws: DecodingError.self) {
            try decodeJSON(VMSpec.self, from: json)
        }
    }

    @Test func diskBytesRoundTrip() throws {
        let spec = VMSpec(
            cpus: 1, memoryBytes: 268_435_456, diskBytes: 10_737_418_240, boot: .disk(firmware: nil))
        let decoded = try roundTrip(spec)
        #expect(decoded._jsonDiskBytes == 10_737_418_240)
    }

    /// `diskBytes` remains semantic optionality: nil means the caller has no
    /// disk reservation to report.
    @Test func specWithoutDiskBytesKeyDecodesToNil() throws {
        let json = """
            {"cpus":2,"maxCpus":2,"memoryBytes":1073741824,"maxMemoryBytes":1073741824,
             "sharedMemory":false,"hugepages":false,"boot":{"disk":{}},"volumes":[],"networks":[],
             "sshAuthorizedKeys":[]}
            """
        let decoded = try decodeJSON(VMSpec.self, from: json)
        #expect(decoded._jsonDiskBytes == nil)
        #expect(decoded._jsonCpus == 2)
    }

    @Test func maxMemoryBytesRoundTrip() throws {
        let spec = VMSpec(
            cpus: 2, maxCpus: 8, memoryBytes: 1_073_741_824, maxMemoryBytes: 8_589_934_592,
            boot: .disk(firmware: nil))
        let decoded = try roundTrip(spec)
        #expect(decoded._jsonMaxMemoryBytes == 8_589_934_592)
        #expect(decoded._jsonMemoryBytes == 1_073_741_824)
    }

    /// No headroom requested: the ceiling is the boot size, which is what
    /// tells the agent not to realize a hot-pluggable memory device at all.
    @Test func maxMemoryBytesDefaultsToMemory() throws {
        let spec = VMSpec(cpus: 1, memoryBytes: 268_435_456, boot: .disk(firmware: nil))
        #expect(spec._jsonMaxMemoryBytes == 268_435_456)
    }

    /// A ceiling below the boot size is meaningless; it clamps rather than
    /// producing a spec that claims memory can shrink below what it booted.
    @Test func maxMemoryBytesBelowMemoryClamps() throws {
        let spec = VMSpec(
            cpus: 1, memoryBytes: 268_435_456, maxMemoryBytes: 1024, boot: .disk(firmware: nil))
        #expect(spec._jsonMaxMemoryBytes == 268_435_456)
    }

    @Test func currentSpecRequiresMaxMemoryBytes() throws {
        let json = """
            {"cpus":2,"maxCpus":2,"memoryBytes":1073741824,"sharedMemory":false,"hugepages":false,
             "boot":{"disk":{}},"volumes":[],"networks":[],"sshAuthorizedKeys":[]}
            """
        #expect(throws: DecodingError.self) {
            try decodeJSON(VMSpec.self, from: json)
        }
    }

    // MARK: - Balloon targets (issue #567 phase 2)

    @Test func balloonTargetRoundTrip() throws {
        let spec = VMSpec(
            cpus: 2, memoryBytes: 4_294_967_296, balloonTargetBytes: 2_147_483_648,
            boot: .disk(firmware: nil))
        let decoded = try roundTrip(spec)
        #expect(decoded._jsonBalloonTargetBytes == 2_147_483_648)
    }

    /// No target is the default and means "guest keeps its whole grant" — the
    /// state every VM was in before the field existed.
    @Test func balloonTargetDefaultsToNil() throws {
        let spec = VMSpec(cpus: 1, memoryBytes: 268_435_456, boot: .disk(firmware: nil))
        #expect(spec._jsonBalloonTargetBytes == nil)
    }

    /// A balloon can only take memory away, never hand out more than the
    /// grant, so a target above `memoryBytes` clamps rather than encoding an
    /// instruction the agent could not carry out.
    @Test func balloonTargetAboveMemoryClamps() throws {
        let spec = VMSpec(
            cpus: 1, memoryBytes: 268_435_456, balloonTargetBytes: 1_073_741_824,
            boot: .disk(firmware: nil))
        #expect(spec._jsonBalloonTargetBytes == 268_435_456)
    }

    /// No balloon target is a current semantic choice, not a compatibility
    /// fallback.
    @Test func specWithoutBalloonTargetKeyDecodesToNil() throws {
        let json = """
            {"cpus":2,"maxCpus":2,"memoryBytes":1073741824,"maxMemoryBytes":1073741824,
             "sharedMemory":false,"hugepages":false,"boot":{"disk":{}},"volumes":[],"networks":[],
             "sshAuthorizedKeys":[]}
            """
        let decoded = try decodeJSON(VMSpec.self, from: json)
        #expect(decoded._jsonBalloonTargetBytes == nil)
    }

    @Test func userDataRoundTrip() throws {
        let payload = "#cloud-config\npackages:\n  - nginx\n"
        let spec = VMSpec(
            cpus: 1, memoryBytes: 268_435_456, boot: .disk(firmware: nil), userData: payload)
        let decoded = try roundTrip(spec)
        #expect(decoded._jsonUserData == payload)
    }

    /// No user data is a current semantic choice.
    @Test func specWithoutUserDataKeyDecodesToNil() throws {
        let json = """
            {"cpus":2,"maxCpus":2,"memoryBytes":1073741824,"maxMemoryBytes":1073741824,
             "sharedMemory":false,"hugepages":false,"boot":{"disk":{}},"volumes":[],"networks":[],
             "sshAuthorizedKeys":[]}
            """
        let decoded = try decodeJSON(VMSpec.self, from: json)
        #expect(decoded._jsonUserData == nil)
    }

    @Test func dualStackNetworkSpecRoundTrip() throws {
        let spec = NetworkSpec(
            network: "default",
            networkId: UUID(),
            macAddress: "52:54:00:00:00:01",
            ipAddress: "10.0.0.5",
            netmask: "255.255.255.0",
            gateway: "10.0.0.1",
            ipv6Address: "fd12:3456:789a::100",
            ipv6PrefixLength: 64,
            gateway6: "fd12:3456:789a::1"
        )
        let decoded = try roundTrip(spec)
        #expect(decoded._jsonIpv6Address == "fd12:3456:789a::100")
        #expect(decoded._jsonIpv6PrefixLength == 64)
        #expect(decoded._jsonGateway6 == "fd12:3456:789a::1")
        #expect(decoded._jsonIpAddress == "10.0.0.5")
    }

    /// A current IPv4-only NIC has no IPv6 values.
    @Test func networkSpecWithoutIPv6KeysDecodesToNil() throws {
        let json = """
            {"network":"default","networkId":"\(UUID().uuidString)",
             "macAddress":"52:54:00:00:00:01",
             "ipAddress":"10.0.0.5","netmask":"255.255.255.0","gateway":"10.0.0.1",
             "dhcpEnabled":false,"dnsServers":[],"metadataEnabled":false}
            """
        let decoded = try decodeJSON(NetworkSpec.self, from: json)
        #expect(decoded._jsonIpv6Address == nil)
        #expect(decoded._jsonIpv6PrefixLength == nil)
        #expect(decoded._jsonGateway6 == nil)
        #expect(decoded._jsonIpAddress == "10.0.0.5")
        #expect(!decoded._jsonDhcpEnabled)
        #expect(!decoded._jsonMetadataEnabled)
        #expect(decoded._jsonInterfaceId == nil)
        #expect(decoded._jsonDeviceName == nil)
        #expect(decoded._jsonOrderIndex == nil)
    }

    @Test func networkSpecCarriesStableInterfaceIdentity() throws {
        let interfaceID = UUID()
        let spec = NetworkSpec(
            interfaceId: interfaceID,
            deviceName: "net5",
            orderIndex: 5,
            network: "storage",
            networkId: UUID(),
            macAddress: "52:54:00:00:00:05")
        let decoded = try roundTrip(spec)
        #expect(decoded._jsonInterfaceId == interfaceID)
        #expect(decoded._jsonDeviceName == "net5")
        #expect(decoded._jsonOrderIndex == 5)
    }

    @Test func networkSpecCarriesMetadataEnabled() throws {
        let json = """
            {"network":"default","networkId":"\(UUID().uuidString)",
             "ipAddress":"10.0.0.5","dhcpEnabled":false,"dnsServers":[],"metadataEnabled":true}
            """
        #expect(try decodeJSON(NetworkSpec.self, from: json)._jsonMetadataEnabled == true)

        let spec = NetworkSpec(network: "default", networkId: UUID(), metadataEnabled: false)
        #expect(try roundTrip(spec)._jsonMetadataEnabled == false)
    }

    // MARK: - Machine profile (issue #565)

    @Test func machineProfileRoundTrip() throws {
        let spec = VMSpec(
            cpus: 2, memoryBytes: 1 << 32, boot: .disk(firmware: nil),
            machine: MachineProfile(secureBoot: true, tpm: true))
        let decoded = try roundTrip(spec)
        #expect(decoded._jsonMachine?._jsonSecureBoot == true)
        #expect(decoded._jsonMachine?._jsonTpm == true)
        #expect(decoded.effectiveMachine == MachineProfile(secureBoot: true, tpm: true))
    }

    /// An omitted machine profile is the current representation of the default
    /// feature set.
    @Test func specWithoutMachineProfileDecodesToDefaults() throws {
        let json = """
            {"cpus":1,"maxCpus":1,"memoryBytes":1,"maxMemoryBytes":1,"sharedMemory":false,
             "hugepages":false,"boot":{"disk":{}},"volumes":[],"networks":[],"sshAuthorizedKeys":[]}
            """
        let decoded = try decodeJSON(VMSpec.self, from: json)
        #expect(decoded._jsonMachine == nil)
        #expect(decoded.effectiveMachine == .default)
        #expect(decoded.effectiveMachine._jsonSecureBoot == false)
        #expect(decoded.effectiveMachine._jsonTpm == false)
    }

    @Test func currentMachineProfileRequiresBothFlags() {
        #expect(throws: DecodingError.self) {
            try decodeJSON(MachineProfile.self, from: #"{"tpm":true}"#)
        }
    }

    // MARK: - Graphics console (issue #566)

    @Test func graphicsConsoleRoundTrip() throws {
        let spec = VMSpec(
            cpus: 2, memoryBytes: 1 << 32, boot: .disk(firmware: nil),
            console: ConsoleSpec(graphics: .vnc))
        let decoded = try roundTrip(spec)
        #expect(decoded._jsonConsole?._jsonGraphics == .vnc)
        #expect(decoded._jsonConsole?.effectiveGraphics == .vnc)
    }

    /// A console spec with no `graphics` key must read as headless rather
    /// than throwing.
    @Test func consoleSpecWithoutGraphicsDecodesToHeadless() throws {
        let decoded = try decodeJSON(ConsoleSpec.self, from: #"{}"#)
        #expect(decoded._jsonGraphics == nil)
        #expect(decoded.effectiveGraphics == .headless)
    }

    /// The reason `graphics` is Optional rather than a defaulted
    /// `GraphicsMode`: a headless VM's spec omits the key entirely, keeping it
    /// out of the sync digest.
    @Test func headlessConsoleSpecOmitsGraphicsKey() throws {
        let json = String(decoding: try encodeJSON(ConsoleSpec()), as: UTF8.self)
        #expect(!json.contains("graphics"))
    }

    /// Graphics decoding is strict, like `DesiredVMStatus` and unlike
    /// `VMStatus`: a mode this build does not know must not degrade to "no
    /// display" on a VM the API describes as having one.
    @Test func unknownGraphicsModeFailsDecode() {
        #expect(throws: DecodingError.self) {
            try decodeJSON(ConsoleSpec.self, from: #"{"console":"Pty","serial":"Pty","graphics":"Spice"}"#)
        }
    }

    /// `networkId` is the one NIC field with no tolerant fallback (wire v21,
    /// issue #765): without it the agent cannot tell which switch the port
    /// belongs on, and the name — unique only within a project — cannot stand
    /// in. A spec that omits it must fail rather than land on a guess.
    @Test func networkSpecRequiresNetworkId() {
        let json = #"{"network":"default","dhcpEnabled":false,"dnsServers":[]}"#
        #expect(throws: DecodingError.self) {
            try decodeJSON(NetworkSpec.self, from: json)
        }
    }

    @Test func currentNetworkSpecRequiresDHCPAndDNSFields() {
        let id = UUID().uuidString
        #expect(throws: DecodingError.self) {
            try decodeJSON(
                NetworkSpec.self,
                from: """
                    {"network":"default","networkId":"\(id)","dnsServers":[],"metadataEnabled":false}
                    """)
        }
        #expect(throws: DecodingError.self) {
            try decodeJSON(
                NetworkSpec.self,
                from: """
                    {"network":"default","networkId":"\(id)","dhcpEnabled":false,"metadataEnabled":false}
                    """)
        }
    }

    @Test func currentVMSpecRequiresSSHAuthorizedKeys() {
        let json = """
            {"cpus":2,"maxCpus":2,"memoryBytes":1073741824,"maxMemoryBytes":1073741824,
             "sharedMemory":false,"hugepages":false,"boot":{"disk":{}},"volumes":[],"networks":[]}
            """
        #expect(throws: DecodingError.self) {
            try decodeJSON(VMSpec.self, from: json)
        }
    }

    /// Two NICs on same-named networks in different projects stay distinct on
    /// the wire, because the id is what carries the identity.
    @Test func sameNamedNetworksKeepDistinctIds() throws {
        let first = UUID()
        let second = UUID()
        let spec = VMSpec(
            cpus: 1, memoryBytes: 1024, boot: .disk(firmware: nil),
            volumes: [],
            networks: [
                NetworkSpec(network: "default", networkId: first),
                NetworkSpec(network: "default", networkId: second),
            ])

        let decoded = try roundTrip(spec)
        #expect(decoded._jsonNetworks.map(\._jsonNetwork) == ["default", "default"])
        #expect(decoded._jsonNetworks.map(\._jsonNetworkId) == [first, second])
    }

    /// An unknown boot-source case from a newer peer must fail loudly (there
    /// is no tolerant fallback for BootSource) — pin that so a change here is
    /// a deliberate decision, not an accident.
    @Test func unknownBootSourceCaseThrows() throws {
        let spec = VMSpec(cpus: 1, memoryBytes: 1, boot: .disk(firmware: nil))
        var object = try #require(JSONSerialization.jsonObject(with: encodeJSON(spec)) as? [String: Any])
        object["boot"] = ["pxe": [String: String]()]
        let invalid = try JSONSerialization.data(withJSONObject: object)
        do {
            _ = try decodeJSON(VMSpec.self, from: invalid)
            Issue.record("An unknown boot source must fail decoding")
        } catch DecodingError.typeMismatch(_, let context) {
            #expect(context.codingPath.map(\.stringValue) == ["boot"])
        } catch DecodingError.dataCorrupted(let context) {
            #expect(context.codingPath.map(\.stringValue) == ["boot"])
        }
    }
}
