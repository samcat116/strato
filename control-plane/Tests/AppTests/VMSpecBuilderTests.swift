import Testing
import Vapor
import StratoShared
@testable import App

@Suite("VMSpecBuilder Tests", .serialized)
struct VMSpecBuilderTests {

    // MARK: - Test Data Helpers

    func createTestImage(
        defaultCpu: Int? = nil,
        defaultMemory: Int64? = nil,
        defaultCmdline: String? = nil
    ) -> Image {
        return Image(
            name: "test-image",
            description: "Test image",
            projectID: UUID(),
            filename: "test.qcow2",
            uploadedByID: UUID(),
            defaultCpu: defaultCpu,
            defaultMemory: defaultMemory,
            defaultCmdline: defaultCmdline
        )
    }

    func createTestVM(
        cpu: Int = 2,
        maxCpu: Int = 4,
        memory: Int64 = 2048,
        disk: Int64 = 20000,
        hugepages: Bool = false,
        sharedMemory: Bool = false,
        diskPath: String? = "/var/lib/strato/disks/test.qcow2",
        readonlyDisk: Bool = false,
        consoleSocket: String? = "/var/run/console.sock",
        serialSocket: String? = "/var/run/serial.sock",
        consoleMode: ConsoleMode = .pty,
        serialMode: ConsoleMode = .pty,
        kernelPath: String? = nil,
        initramfsPath: String? = nil,
        firmwarePath: String? = nil,
        cmdline: String? = nil
    ) -> VM {
        let vm = VM(
            name: "test-vm",
            description: "Test VM",
            image: "test-image",
            projectID: UUID(),
            environment: "test",
            cpu: cpu,
            memory: memory,
            disk: disk,
            maxCpu: maxCpu
        )
        vm.hugepages = hugepages
        vm.sharedMemory = sharedMemory
        vm.diskPath = diskPath
        vm.readonlyDisk = readonlyDisk
        vm.consoleSocket = consoleSocket
        vm.serialSocket = serialSocket
        vm.consoleMode = consoleMode
        vm.serialMode = serialMode
        vm.kernelPath = kernelPath
        vm.initramfsPath = initramfsPath
        vm.firmwarePath = firmwarePath
        vm.cmdline = cmdline
        return vm
    }

    func createTestInterface(
        network: String = "default",
        macAddress: String = "52:54:00:12:34:56",
        ipAddress: String? = "192.168.1.10",
        netmask: String? = "255.255.255.0",
        gateway: String? = nil,
        mtu: Int? = nil,
        deviceName: String = "net0",
        orderIndex: Int = 0
    ) -> VMNetworkInterface {
        let interface = VMNetworkInterface(
            id: UUID(),
            vmID: UUID(),
            network: network,
            macAddress: macAddress,
            mtu: mtu,
            deviceName: deviceName,
            orderIndex: orderIndex
        )
        // Addressing lives in per-family child rows now; mirror what the
        // create path persists (an ipv4 row when IPAM allocated one).
        if let ipAddress {
            let prefix = netmask.flatMap { StratoShared.IPv4Address($0)?.prefixLength } ?? 24
            interface.$addresses.value = [
                VMInterfaceAddress(
                    interfaceID: interface.id!,
                    network: network,
                    family: .ipv4,
                    address: ipAddress,
                    prefixLength: prefix,
                    gateway: gateway
                )
            ]
        } else {
            interface.$addresses.value = []
        }
        return interface
    }

    struct TestAbort: Error {}

    /// Unwraps a direct-kernel boot source or fails the test.
    func directKernel(
        _ spec: VMSpec,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> (kernel: String, initramfs: String?, cmdline: String?) {
        guard case .directKernel(let kernel, let initramfs, let cmdline) = spec.boot else {
            Issue.record("Expected direct kernel boot, got \(spec.boot)", sourceLocation: sourceLocation)
            throw TestAbort()
        }
        return (kernel, initramfs, cmdline)
    }

    // MARK: - Resource Configuration Tests

    @Test("VMSpecBuilder creates spec with VM defaults")
    func testBasicSpecCreation() throws {
        let image = createTestImage()
        let vm = createTestVM()

        let spec = VMSpecBuilder.buildVMSpec(from: vm, image: image, networkInterfaces: [])

        #expect(spec.cpus == 2)
        #expect(spec.maxCpus == 4)
        #expect(spec.memoryBytes == 2048)
        #expect(spec.sharedMemory == false)
        #expect(spec.hugepages == false)
    }

    @Test("VMSpecBuilder sets CPU counts correctly")
    func testCPUConfiguration() throws {
        let image = createTestImage()
        let vm = createTestVM(cpu: 8, maxCpu: 16)

        let spec = VMSpecBuilder.buildVMSpec(from: vm, image: image, networkInterfaces: [])

        #expect(spec.cpus == 8)
        #expect(spec.maxCpus == 16)
    }

    @Test("VMSpecBuilder sets memory size from VM")
    func testMemorySize() throws {
        let image = createTestImage()
        let vm = createTestVM(memory: 4096)

        let spec = VMSpecBuilder.buildVMSpec(from: vm, image: image, networkInterfaces: [])

        #expect(spec.memoryBytes == 4096)
    }

    @Test("VMSpecBuilder carries the VM's disk requirement on both build paths")
    func testDiskBytes() throws {
        let image = createTestImage()
        let vm = createTestVM(disk: 10_737_418_240)

        let spec = VMSpecBuilder.buildVMSpec(from: vm, image: image, networkInterfaces: [])
        #expect(spec.diskBytes == 10_737_418_240)

        let specWithVolumes = VMSpecBuilder.buildVMSpecWithVolumes(
            from: vm, image: image, volumes: [], networkInterfaces: [])
        #expect(specWithVolumes.diskBytes == 10_737_418_240)
    }

    @Test("VMSpecBuilder configures hugepages correctly")
    func testHugepagesConfiguration() throws {
        let image = createTestImage()
        let vm = createTestVM(hugepages: true)

        let spec = VMSpecBuilder.buildVMSpec(from: vm, image: image, networkInterfaces: [])

        #expect(spec.hugepages == true)
    }

    @Test("VMSpecBuilder configures shared memory correctly")
    func testSharedMemoryConfiguration() throws {
        let image = createTestImage()
        let vm = createTestVM(sharedMemory: true)

        let spec = VMSpecBuilder.buildVMSpec(from: vm, image: image, networkInterfaces: [])

        #expect(spec.sharedMemory == true)
    }

    // MARK: - Boot Source Tests

    @Test("VMSpecBuilder uses VM boot paths")
    func testVMBootPaths() throws {
        let image = createTestImage()
        let vm = createTestVM(
            kernelPath: "/vm/kernel",
            initramfsPath: "/vm/initramfs",
            firmwarePath: "/vm/firmware",
            cmdline: "vm cmdline"
        )

        let spec = VMSpecBuilder.buildVMSpec(from: vm, image: image, networkInterfaces: [])
        let boot = try directKernel(spec)

        #expect(boot.kernel == "/vm/kernel")
        #expect(boot.initramfs == "/vm/initramfs")
        #expect(boot.cmdline == "vm cmdline console=tty0 console=ttyS0,115200 console=ttyAMA0,115200 console=hvc0")
    }

    @Test("VMSpecBuilder falls back to image cmdline when the VM has none")
    func testImageCmdlineFallback() throws {
        let image = createTestImage(defaultCmdline: "image cmdline")
        let vm = createTestVM(kernelPath: "/vm/kernel", cmdline: nil)

        let spec = VMSpecBuilder.buildVMSpec(from: vm, image: image, networkInterfaces: [])
        let boot = try directKernel(spec)

        #expect(boot.kernel == "/vm/kernel")
        #expect(
            boot.cmdline == "image cmdline console=tty0 console=ttyS0,115200 console=ttyAMA0,115200 console=hvc0")
    }

    @Test("VMSpecBuilder handles missing optional boot paths")
    func testMissingOptionalPaths() throws {
        let image = createTestImage()
        let vm = createTestVM(
            kernelPath: "/vm/kernel",
            initramfsPath: nil,
            firmwarePath: nil,
            cmdline: "cmdline"
        )

        let spec = VMSpecBuilder.buildVMSpec(from: vm, image: image, networkInterfaces: [])
        let boot = try directKernel(spec)

        #expect(boot.kernel == "/vm/kernel")
        #expect(boot.initramfs == nil)
        #expect(boot.cmdline == "cmdline console=tty0 console=ttyS0,115200 console=ttyAMA0,115200 console=hvc0")
    }

    @Test("VMSpecBuilder falls back to firmware boot when no kernel is specified")
    func testFirmwareBootWithoutKernel() throws {
        let image = createTestImage()
        let vm = createTestVM(kernelPath: nil, firmwarePath: "/vm/firmware")

        let spec = VMSpecBuilder.buildVMSpec(from: vm, image: image, networkInterfaces: [])

        guard case .disk(let firmware) = spec.boot else {
            Issue.record("Expected disk (firmware) boot, got \(spec.boot)")
            return
        }
        #expect(firmware == "/vm/firmware")
    }

    // MARK: - Volume Tests

    @Test("VMSpecBuilder creates a volume when disk path is set")
    func testVolumeConfiguration() throws {
        let image = createTestImage()
        let vm = createTestVM(diskPath: "/var/lib/strato/disks/vm.qcow2", readonlyDisk: false)

        let spec = VMSpecBuilder.buildVMSpec(from: vm, image: image, networkInterfaces: [])

        #expect(spec.volumes.count == 1)
        #expect(spec.volumes.first?.storagePath == "/var/lib/strato/disks/vm.qcow2")
        #expect(spec.volumes.first?.readonly == false)
        #expect(spec.volumes.first?.deviceName == "disk0")
        #expect(spec.volumes.first?.volumeId == nil)
    }

    @Test("VMSpecBuilder creates readonly volume when specified")
    func testReadonlyVolume() throws {
        let image = createTestImage()
        let vm = createTestVM(diskPath: "/var/lib/strato/disks/vm.qcow2", readonlyDisk: true)

        let spec = VMSpecBuilder.buildVMSpec(from: vm, image: image, networkInterfaces: [])

        #expect(spec.volumes.first?.readonly == true)
    }

    @Test("VMSpecBuilder omits volumes when no disk path is set")
    func testNoDiskPath() throws {
        let image = createTestImage()
        let vm = createTestVM(diskPath: nil)

        let spec = VMSpecBuilder.buildVMSpec(from: vm, image: image, networkInterfaces: [])

        #expect(spec.volumes.isEmpty)
    }

    // MARK: - Network Tests

    @Test("VMSpecBuilder maps a network interface to a network spec")
    func testNetworkConfiguration() throws {
        let image = createTestImage()
        let vm = createTestVM()
        let interface = createTestInterface(
            macAddress: "52:54:00:12:34:56",
            ipAddress: "192.168.1.10",
            netmask: "255.255.255.0"
        )

        let spec = VMSpecBuilder.buildVMSpec(from: vm, image: image, networkInterfaces: [interface])

        #expect(spec.networks.count == 1)
        #expect(spec.networks.first?.network == "default")
        #expect(spec.networks.first?.macAddress == "52:54:00:12:34:56")
        #expect(spec.networks.first?.ipAddress == "192.168.1.10")
        #expect(spec.networks.first?.netmask == "255.255.255.0")
    }

    @Test("VMSpecBuilder passes the NIC's gateway through to the network spec")
    func testGatewayPassthrough() throws {
        let image = createTestImage()
        let vm = createTestVM()
        let interface = createTestInterface(gateway: "192.168.1.1")

        let spec = VMSpecBuilder.buildVMSpec(from: vm, image: image, networkInterfaces: [interface])

        #expect(spec.networks.first?.gateway == "192.168.1.1")
    }

    @Test("networkSpecs populates DHCP/DNS from the matching logical network")
    func testDHCPConfigFromNetwork() throws {
        let interface = createTestInterface(network: "default")
        let network = LogicalNetwork(
            name: "default",
            subnet: "192.168.1.0/24",
            gateway: "192.168.1.1",
            dhcpEnabled: true,
            dnsServers: ["1.1.1.1", "8.8.8.8"],
            domainName: "corp.example.com",
            leaseTime: 7200
        )

        let specs = VMSpecBuilder.networkSpecs(from: [interface], networks: ["default": network])

        #expect(specs.first?.dhcpEnabled == true)
        #expect(specs.first?.dnsServers == ["1.1.1.1", "8.8.8.8"])
        #expect(specs.first?.domainName == "corp.example.com")
        #expect(specs.first?.leaseTime == 7200)
    }

    @Test("networkSpecs defaults DHCP off when no network is supplied")
    func testDHCPDefaultsOffWithoutNetwork() throws {
        let interface = createTestInterface(network: "default")

        let specs = VMSpecBuilder.networkSpecs(from: [interface])

        #expect(specs.first?.dhcpEnabled == false)
        #expect(specs.first?.dnsServers == [])
        #expect(specs.first?.domainName == nil)
        #expect(specs.first?.leaseTime == nil)
    }

    @Test("VMSpecBuilder does not fabricate an IP when none is assigned")
    func testNoFabricatedIPAddress() throws {
        let image = createTestImage()
        let vm = createTestVM()
        let interface = createTestInterface(ipAddress: nil, netmask: nil)

        let spec = VMSpecBuilder.buildVMSpec(from: vm, image: image, networkInterfaces: [interface])

        #expect(spec.networks.first?.ipAddress == nil)
        #expect(spec.networks.first?.netmask == nil)
    }

    @Test("VMSpecBuilder omits networks when the VM has no interfaces")
    func testNoNetworkInterfaces() throws {
        let image = createTestImage()
        let vm = createTestVM()

        let spec = VMSpecBuilder.buildVMSpec(from: vm, image: image, networkInterfaces: [])

        #expect(spec.networks.isEmpty)
    }

    @Test("VMSpecBuilder orders multiple interfaces by order index, then device name")
    func testMultipleInterfaceOrdering() throws {
        let image = createTestImage()
        let vm = createTestVM()
        let second = createTestInterface(
            network: "backend",
            macAddress: "52:54:00:00:00:02",
            deviceName: "net1",
            orderIndex: 1
        )
        let first = createTestInterface(
            macAddress: "52:54:00:00:00:01",
            deviceName: "net0",
            orderIndex: 0
        )

        // Passed out of order; the builder must sort.
        let spec = VMSpecBuilder.buildVMSpec(from: vm, image: image, networkInterfaces: [second, first])

        #expect(spec.networks.count == 2)
        #expect(spec.networks.first?.macAddress == "52:54:00:00:00:01")
        #expect(spec.networks.first?.network == "default")
        #expect(spec.networks.last?.macAddress == "52:54:00:00:00:02")
        #expect(spec.networks.last?.network == "backend")
    }

    // MARK: - Console Tests

    @Test("VMSpecBuilder carries console and serial mode preferences")
    func testConsoleConfiguration() throws {
        let image = createTestImage()
        let vm = createTestVM(consoleMode: .pty, serialMode: .tty)

        let spec = VMSpecBuilder.buildVMSpec(from: vm, image: image, networkInterfaces: [])

        #expect(spec.console?.console == .pty)
        #expect(spec.console?.serial == .tty)
    }

    // MARK: - Image-Based Tests

    @Test("VMSpecBuilder builds firmware-boot spec from image without kernel")
    func testImageBasedSpec() throws {
        let image = createTestImage()
        let vm = createTestVM(diskPath: nil, kernelPath: nil, firmwarePath: nil)

        let spec = VMSpecBuilder.buildVMSpec(from: vm, image: image, networkInterfaces: [])

        #expect(spec.cpus == 2)
        #expect(spec.memoryBytes == 2048)
        // Boot volume is materialized agent-side from the cached image.
        #expect(spec.volumes.isEmpty)
        guard case .disk(let firmware) = spec.boot else {
            Issue.record("Expected disk (firmware) boot, got \(spec.boot)")
            return
        }
        #expect(firmware == nil)
    }

    @Test("VMSpecBuilder uses image defaults when VM resources are unset")
    func testImageDefaults() throws {
        let image = createTestImage(defaultCpu: 4, defaultMemory: 4096)
        let vm = createTestVM(cpu: 0, maxCpu: 0, memory: 0)

        let spec = VMSpecBuilder.buildVMSpec(from: vm, image: image, networkInterfaces: [])

        #expect(spec.cpus == 4)
        #expect(spec.maxCpus == 4)
        #expect(spec.memoryBytes == 4096)
    }

    // MARK: - Integration Tests

    @Test("VMSpecBuilder creates complete spec with all components")
    func testCompleteSpec() throws {
        let image = createTestImage()
        let vm = createTestVM(
            cpu: 4,
            maxCpu: 8,
            memory: 8192,
            disk: 50000,
            hugepages: true,
            sharedMemory: true,
            diskPath: "/var/lib/strato/disks/vm.qcow2",
            readonlyDisk: false,
            kernelPath: "/vm/kernel"
        )
        let interface = createTestInterface(ipAddress: "192.168.1.100")

        let spec = VMSpecBuilder.buildVMSpec(from: vm, image: image, networkInterfaces: [interface])
        let boot = try directKernel(spec)

        #expect(spec.cpus == 4)
        #expect(spec.maxCpus == 8)
        #expect(spec.memoryBytes == 8192)
        #expect(spec.hugepages == true)
        #expect(spec.sharedMemory == true)
        #expect(!spec.volumes.isEmpty)
        #expect(!spec.networks.isEmpty)
        #expect(!boot.kernel.isEmpty)
    }

    @Test("VMSpecBuilder creates minimal spec without optional components")
    func testMinimalSpec() throws {
        let image = createTestImage()
        let vm = createTestVM(diskPath: nil)

        let spec = VMSpecBuilder.buildVMSpec(from: vm, image: image, networkInterfaces: [])

        #expect(spec.cpus == 2)
        #expect(spec.memoryBytes == 2048)
        #expect(spec.volumes.isEmpty)
        #expect(spec.networks.isEmpty)
        #expect(spec.userData == nil)
    }

    @Test("VMSpecBuilder carries cloud-init user data verbatim")
    func testUserDataPassthrough() throws {
        let image = createTestImage()
        let vm = createTestVM()
        let payload = "#cloud-config\npackages:\n  - nginx\nruncmd:\n  - systemctl enable --now nginx\n"
        vm.userData = payload

        let spec = VMSpecBuilder.buildVMSpec(from: vm, image: image, networkInterfaces: [])
        #expect(spec.userData == payload)

        let specWithVolumes = VMSpecBuilder.buildVMSpecWithVolumes(
            from: vm, image: image, volumes: [], networkInterfaces: [])
        #expect(specWithVolumes.userData == payload)
    }

    // MARK: - Machine profile (issue #565)

    @Test("VMSpecBuilder carries the VM's Secure Boot and TPM intent")
    func testMachineProfilePassthrough() throws {
        let image = createTestImage()
        let vm = createTestVM()
        vm.secureBoot = true
        vm.tpmEnabled = true

        let spec = VMSpecBuilder.buildVMSpec(from: vm, image: image, networkInterfaces: [])
        #expect(spec.machine?.secureBoot == true)
        #expect(spec.machine?.tpm == true)

        let specWithVolumes = VMSpecBuilder.buildVMSpecWithVolumes(
            from: vm, image: image, volumes: [], networkInterfaces: [])
        #expect(specWithVolumes.machine?.secureBoot == true)
        #expect(specWithVolumes.machine?.tpm == true)
    }

    @Test("A VM with no machine features sends the default profile, not garbage")
    func testDefaultMachineProfile() throws {
        let image = createTestImage()
        let vm = createTestVM()

        let spec = VMSpecBuilder.buildVMSpec(from: vm, image: image, networkInterfaces: [])
        #expect(spec.effectiveMachine == .default)
        #expect(spec.machine?.secureBoot == false)
        #expect(spec.machine?.tpm == false)
    }
}

@Suite("VM create user-data validation")
struct VMUserDataValidationTests {
    @Test("nil and blank normalize to nil")
    func blankNormalizesToNil() throws {
        #expect(try VMController.validatedUserData(nil) == nil)
        #expect(try VMController.validatedUserData("") == nil)
        #expect(try VMController.validatedUserData("  \n\t ") == nil)
    }

    @Test("recognized formats pass through verbatim")
    func recognizedFormatsPass() throws {
        let cloudConfig = "#cloud-config\npackages: [nginx]\n"
        #expect(try VMController.validatedUserData(cloudConfig) == cloudConfig)
        let script = "#!/bin/bash\necho hello > /root/hello.txt\n"
        #expect(try VMController.validatedUserData(script) == script)
        let mime = "Content-Type: multipart/mixed; boundary=\"b\"\nMIME-Version: 1.0\n\n--b--\n"
        #expect(try VMController.validatedUserData(mime) == mime)
    }

    @Test("payload without a cloud-init header is rejected")
    func missingHeaderRejected() {
        #expect(throws: Abort.self) {
            _ = try VMController.validatedUserData("echo missing shebang\n")
        }
    }

    @Test("oversized payload is rejected")
    func oversizedRejected() {
        let big = "#cloud-config\n" + String(repeating: "a", count: CloudInitUserDataFormat.maxBytes)
        #expect(throws: Abort.self) {
            _ = try VMController.validatedUserData(big)
        }
    }
}
