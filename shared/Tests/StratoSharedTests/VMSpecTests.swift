import Foundation
import Testing
import StratoShared

@Suite("VMSpec wire format")
struct VMSpecTests {
    @Test func diskBootRoundTrip() throws {
        let spec = VMSpec(cpus: 1, memoryBytes: 536_870_912, boot: .disk(firmware: "/fw/OVMF.fd"))
        let decoded = try roundTrip(spec)
        guard case .disk(let firmware) = decoded.boot else {
            Issue.record("expected .disk, got \(decoded.boot)")
            return
        }
        #expect(firmware == "/fw/OVMF.fd")
    }

    @Test func diskBootWithDefaultFirmwareRoundTrip() throws {
        let spec = VMSpec(cpus: 1, memoryBytes: 536_870_912, boot: .disk(firmware: nil))
        let decoded = try roundTrip(spec)
        guard case .disk(let firmware) = decoded.boot else {
            Issue.record("expected .disk, got \(decoded.boot)")
            return
        }
        #expect(firmware == nil)
    }

    @Test func directKernelBootRoundTrip() throws {
        let spec = VMSpec(
            cpus: 1,
            memoryBytes: 536_870_912,
            boot: .directKernel(
                kernel: "/boot/vmlinux", initramfs: "/boot/initrd", cmdline: "console=ttyS0 root=/dev/vda")
        )
        let decoded = try roundTrip(spec)
        guard case .directKernel(let kernel, let initramfs, let cmdline) = decoded.boot else {
            Issue.record("expected .directKernel, got \(decoded.boot)")
            return
        }
        #expect(kernel == "/boot/vmlinux")
        #expect(initramfs == "/boot/initrd")
        #expect(cmdline == "console=ttyS0 root=/dev/vda")
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
                    volumeId: Fixtures.uuidA, deviceName: "disk0", storagePath: "/v/disk0.qcow2", readonly: false,
                    bootOrder: 0),
                VolumeSpec(volumeId: nil, deviceName: "disk1", storagePath: nil, readonly: true, bootOrder: 1),
            ],
            networks: [
                NetworkSpec(
                    network: "default", networkId: UUID(), macAddress: "52:54:00:00:00:01", ipAddress: "10.0.0.5",
                    netmask: "255.255.255.0", mtu: 9000),
                NetworkSpec(network: "storage", networkId: UUID()),
            ],
            console: ConsoleSpec(console: .off, serial: .null)
        )
        let decoded = try roundTrip(spec)
        #expect(decoded.cpus == 4)
        #expect(decoded.maxCpus == 8)
        #expect(decoded.memoryBytes == 8_589_934_592)
        #expect(decoded.sharedMemory)
        #expect(decoded.hugepages)

        #expect(decoded.volumes.count == 2)
        #expect(decoded.volumes[0].volumeId == Fixtures.uuidA)
        #expect(decoded.volumes[0].deviceName == "disk0")
        #expect(decoded.volumes[0].storagePath == "/v/disk0.qcow2")
        #expect(decoded.volumes[0].bootOrder == 0)
        #expect(decoded.volumes[1].volumeId == nil)
        #expect(decoded.volumes[1].readonly)
        #expect(decoded.volumes[1].storagePath == nil)

        #expect(decoded.networks.count == 2)
        #expect(decoded.networks[0].network == "default")
        #expect(decoded.networks[0].mtu == 9000)
        #expect(decoded.networks[1].network == "storage")
        #expect(decoded.networks[1].macAddress == nil)

        #expect(decoded.console?.console == .off)
        #expect(decoded.console?.serial == .null)
    }

    @Test func minimalSpecRoundTrip() throws {
        let decoded = try roundTrip(VMSpec(cpus: 1, memoryBytes: 268_435_456, boot: .disk(firmware: nil)))
        #expect(decoded.maxCpus == 1)
        #expect(!decoded.sharedMemory)
        #expect(!decoded.hugepages)
        #expect(decoded.volumes.isEmpty)
        #expect(decoded.networks.isEmpty)
        #expect(decoded.console == nil)
        #expect(decoded.diskBytes == nil)
    }

    @Test func diskBytesRoundTrip() throws {
        let spec = VMSpec(
            cpus: 1, memoryBytes: 268_435_456, diskBytes: 10_737_418_240, boot: .disk(firmware: nil))
        let decoded = try roundTrip(spec)
        #expect(decoded.diskBytes == 10_737_418_240)
    }

    /// A spec from a control plane that predates `diskBytes` (issue #473) has
    /// no such key; a new agent must decode it to nil (rolling-upgrade skew).
    @Test func specWithoutDiskBytesKeyDecodesToNil() throws {
        let json = """
            {"cpus":2,"maxCpus":2,"memoryBytes":1073741824,"sharedMemory":false,"hugepages":false,
             "boot":{"disk":{}},"volumes":[],"networks":[]}
            """
        let decoded = try decodeJSON(VMSpec.self, from: json)
        #expect(decoded.diskBytes == nil)
        #expect(decoded.cpus == 2)
    }

    @Test func maxMemoryBytesRoundTrip() throws {
        let spec = VMSpec(
            cpus: 2, maxCpus: 8, memoryBytes: 1_073_741_824, maxMemoryBytes: 8_589_934_592,
            boot: .disk(firmware: nil))
        let decoded = try roundTrip(spec)
        #expect(decoded.maxMemoryBytes == 8_589_934_592)
        #expect(decoded.memoryBytes == 1_073_741_824)
    }

    /// No headroom requested: the ceiling is the boot size, which is what
    /// tells the agent not to realize a hot-pluggable memory device at all.
    @Test func maxMemoryBytesDefaultsToMemory() throws {
        let spec = VMSpec(cpus: 1, memoryBytes: 268_435_456, boot: .disk(firmware: nil))
        #expect(spec.maxMemoryBytes == 268_435_456)
    }

    /// A ceiling below the boot size is meaningless; it clamps rather than
    /// producing a spec that claims memory can shrink below what it booted.
    @Test func maxMemoryBytesBelowMemoryClamps() throws {
        let spec = VMSpec(
            cpus: 1, memoryBytes: 268_435_456, maxMemoryBytes: 1024, boot: .disk(firmware: nil))
        #expect(spec.maxMemoryBytes == 268_435_456)
    }

    /// A spec from a control plane that predates `maxMemoryBytes` (issue
    /// #568) has no such key; a new agent must read it as "no headroom"
    /// rather than failing the sync (rolling-upgrade skew).
    @Test func specWithoutMaxMemoryKeyDecodesToMemory() throws {
        let json = """
            {"cpus":2,"maxCpus":2,"memoryBytes":1073741824,"sharedMemory":false,"hugepages":false,
             "boot":{"disk":{}},"volumes":[],"networks":[]}
            """
        let decoded = try decodeJSON(VMSpec.self, from: json)
        #expect(decoded.maxMemoryBytes == 1_073_741_824)
    }

    // MARK: - Balloon targets (issue #567 phase 2)

    @Test func balloonTargetRoundTrip() throws {
        let spec = VMSpec(
            cpus: 2, memoryBytes: 4_294_967_296, balloonTargetBytes: 2_147_483_648,
            boot: .disk(firmware: nil))
        let decoded = try roundTrip(spec)
        #expect(decoded.balloonTargetBytes == 2_147_483_648)
    }

    /// No target is the default and means "guest keeps its whole grant" — the
    /// state every VM was in before the field existed.
    @Test func balloonTargetDefaultsToNil() throws {
        let spec = VMSpec(cpus: 1, memoryBytes: 268_435_456, boot: .disk(firmware: nil))
        #expect(spec.balloonTargetBytes == nil)
    }

    /// A balloon can only take memory away, never hand out more than the
    /// grant, so a target above `memoryBytes` clamps rather than encoding an
    /// instruction the agent could not carry out.
    @Test func balloonTargetAboveMemoryClamps() throws {
        let spec = VMSpec(
            cpus: 1, memoryBytes: 268_435_456, balloonTargetBytes: 1_073_741_824,
            boot: .disk(firmware: nil))
        #expect(spec.balloonTargetBytes == 268_435_456)
        let json = """
            {"cpus":1,"maxCpus":1,"memoryBytes":268435456,"balloonTargetBytes":1073741824,
             "sharedMemory":false,"hugepages":false,"boot":{"disk":{}},"volumes":[],"networks":[]}
            """
        #expect(try decodeJSON(VMSpec.self, from: json).balloonTargetBytes == 268_435_456)
    }

    /// A spec from a control plane that predates `balloonTargetBytes` has no
    /// such key; a new agent must read it as "no target" rather than failing
    /// the sync (rolling-upgrade skew).
    @Test func specWithoutBalloonTargetKeyDecodesToNil() throws {
        let json = """
            {"cpus":2,"maxCpus":2,"memoryBytes":1073741824,"sharedMemory":false,"hugepages":false,
             "boot":{"disk":{}},"volumes":[],"networks":[]}
            """
        let decoded = try decodeJSON(VMSpec.self, from: json)
        #expect(decoded.balloonTargetBytes == nil)
    }

    @Test func userDataRoundTrip() throws {
        let payload = "#cloud-config\npackages:\n  - nginx\n"
        let spec = VMSpec(
            cpus: 1, memoryBytes: 268_435_456, boot: .disk(firmware: nil), userData: payload)
        let decoded = try roundTrip(spec)
        #expect(decoded.userData == payload)
    }

    /// A spec from a control plane that predates `userData` has no such key; a
    /// new agent must decode it to nil (rolling-upgrade skew).
    @Test func specWithoutUserDataKeyDecodesToNil() throws {
        let json = """
            {"cpus":2,"maxCpus":2,"memoryBytes":1073741824,"sharedMemory":false,"hugepages":false,
             "boot":{"disk":{}},"volumes":[],"networks":[]}
            """
        let decoded = try decodeJSON(VMSpec.self, from: json)
        #expect(decoded.userData == nil)
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
        #expect(decoded.ipv6Address == "fd12:3456:789a::100")
        #expect(decoded.ipv6PrefixLength == 64)
        #expect(decoded.gateway6 == "fd12:3456:789a::1")
        #expect(decoded.ipAddress == "10.0.0.5")
    }

    /// A spec from a control plane that predates IPv6 has no v6 keys; a new
    /// agent must decode it to nils (rolling-upgrade skew).
    @Test func networkSpecWithoutIPv6KeysDecodesToNil() throws {
        let json = """
            {"network":"default","networkId":"\(UUID().uuidString)",
             "macAddress":"52:54:00:00:00:01",
             "ipAddress":"10.0.0.5","netmask":"255.255.255.0","gateway":"10.0.0.1"}
            """
        let decoded = try decodeJSON(NetworkSpec.self, from: json)
        #expect(decoded.ipv6Address == nil)
        #expect(decoded.ipv6PrefixLength == nil)
        #expect(decoded.gateway6 == nil)
        #expect(decoded.ipAddress == "10.0.0.5")
        #expect(!decoded.dhcpEnabled)
        #expect(decoded.metadataEnabled == nil)
    }

    /// `NetworkSpec` hand-writes `init(from:)`, so a new field needs both a
    /// coding key and a `decodeIfPresent` line — miss either and it silently
    /// decodes as nil forever, which for `metadataEnabled` (STR-49) means a
    /// chassis that never materializes the metadata address and reports no
    /// error. Round-tripping alone would not catch it; this decodes the key
    /// from raw JSON.
    @Test func networkSpecCarriesMetadataEnabled() throws {
        let json = """
            {"network":"default","networkId":"\(UUID().uuidString)",
             "ipAddress":"10.0.0.5","metadataEnabled":true}
            """
        #expect(try decodeJSON(NetworkSpec.self, from: json).metadataEnabled == true)

        let spec = NetworkSpec(network: "default", networkId: UUID(), metadataEnabled: false)
        #expect(try roundTrip(spec).metadataEnabled == false)
    }

    // MARK: - Machine profile (issue #565)

    @Test func machineProfileRoundTrip() throws {
        let spec = VMSpec(
            cpus: 2, memoryBytes: 1 << 32, boot: .disk(firmware: nil),
            machine: MachineProfile(secureBoot: true, tpm: true))
        let decoded = try roundTrip(spec)
        #expect(decoded.machine?.secureBoot == true)
        #expect(decoded.machine?.tpm == true)
        #expect(decoded.effectiveMachine == MachineProfile(secureBoot: true, tpm: true))
    }

    /// A spec from a control plane that predates the machine profile has no
    /// `machine` key. It must decode to today's behavior — both features off —
    /// rather than throwing, or a rolling upgrade would break every sync.
    @Test func specWithoutMachineProfileDecodesToDefaults() throws {
        let json = """
            {"cpus":1,"maxCpus":1,"memoryBytes":1,"sharedMemory":false,"hugepages":false,
             "boot":{"disk":{}},"volumes":[],"networks":[]}
            """
        let decoded = try decodeJSON(VMSpec.self, from: json)
        #expect(decoded.machine == nil)
        #expect(decoded.effectiveMachine == .default)
        #expect(decoded.effectiveMachine.secureBoot == false)
        #expect(decoded.effectiveMachine.tpm == false)
    }

    /// A partial profile (a peer that carries only one of the flags) decodes
    /// with the absent flag off, not as a failure.
    @Test func partialMachineProfileDecodes() throws {
        let decoded = try decodeJSON(MachineProfile.self, from: #"{"tpm":true}"#)
        #expect(decoded.tpm)
        #expect(!decoded.secureBoot)
    }

    // MARK: - Graphics console (issue #566)

    @Test func graphicsConsoleRoundTrip() throws {
        let spec = VMSpec(
            cpus: 2, memoryBytes: 1 << 32, boot: .disk(firmware: nil),
            console: ConsoleSpec(console: .pty, serial: .pty, graphics: .vnc))
        let decoded = try roundTrip(spec)
        #expect(decoded.console?.graphics == .vnc)
        #expect(decoded.console?.effectiveGraphics == .vnc)
    }

    /// A console spec from a control plane that predates the graphics console
    /// has no `graphics` key, and must read as headless rather than throwing.
    @Test func consoleSpecWithoutGraphicsDecodesToHeadless() throws {
        let decoded = try decodeJSON(ConsoleSpec.self, from: #"{"console":"Pty","serial":"Pty"}"#)
        #expect(decoded.graphics == nil)
        #expect(decoded.effectiveGraphics == .headless)
    }

    /// The other direction, and the reason `graphics` is Optional rather than a
    /// defaulted `GraphicsMode`: a headless VM's spec must stay byte-identical
    /// to what a pre-v23 agent already receives, so the key is absent — not
    /// present as `"None"`.
    @Test func headlessConsoleSpecOmitsGraphicsKey() throws {
        let json = String(decoding: try encodeJSON(ConsoleSpec(console: .pty, serial: .pty)), as: UTF8.self)
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
        #expect(decoded.networks.map(\.network) == ["default", "default"])
        #expect(decoded.networks.map(\.networkId) == [first, second])
    }

    /// An unknown boot-source case from a newer peer must fail loudly (there
    /// is no tolerant fallback for BootSource) — pin that so a change here is
    /// a deliberate decision, not an accident.
    @Test func unknownBootSourceCaseThrows() {
        let json = """
            {"cpus":1,"maxCpus":1,"memoryBytes":1,"sharedMemory":false,"hugepages":false,
             "boot":{"pxe":{}},"volumes":[],"networks":[]}
            """
        #expect(throws: DecodingError.self) {
            try decodeJSON(VMSpec.self, from: json)
        }
    }
}
