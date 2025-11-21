import Testing
import Vapor
import StratoShared
@testable import App

@Suite("VMConfigBuilder Tests", .serialized)
struct VMConfigBuilderTests {

    // MARK: - Test Data Helpers

    func createTestTemplate(
        kernelPath: String = "/boot/vmlinuz",
        initramfsPath: String? = "/boot/initramfs.img",
        firmwarePath: String? = "/boot/firmware.bin",
        defaultCmdline: String = "console=ttyS0"
    ) -> VMTemplate {
        return VMTemplate(
            name: "Test Template",
            description: "Test template",
            imageName: "test-image",
            defaultCpu: 2,
            defaultMemory: 2048,
            defaultDisk: 20000,
            kernelPath: kernelPath,
            baseDiskPath: "/var/lib/strato/disks/base.qcow2",
            defaultCmdline: defaultCmdline,
            initramfsPath: initramfsPath,
            firmwarePath: firmwarePath
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
        macAddress: String? = "52:54:00:12:34:56",
        ipAddress: String? = "192.168.1.10",
        networkMask: String? = "255.255.255.0",
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
        vm.macAddress = macAddress
        vm.ipAddress = ipAddress
        vm.networkMask = networkMask
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

    // MARK: - Basic Configuration Tests

    @Test("VMConfigBuilder creates config with VM and template defaults")
    func testBasicConfigCreation() async throws {
        let template = createTestTemplate()
        let vm = createTestVM()

        let config = try await VMConfigBuilder.buildVMConfig(from: vm, template: template)

        // Verify CPU configuration
        #expect(config.cpus?.bootVcpus == 2)
        #expect(config.cpus?.maxVcpus == 4)
        #expect(config.cpus?.kvmHyperv == false)

        // Verify memory configuration
        #expect(config.memory?.size == 2048)
        #expect(config.memory?.mergeable == false)
        #expect(config.memory?.shared == false)
        #expect(config.memory?.hugepages == false)
        #expect(config.memory?.thp == true)
    }

    // MARK: - Payload Configuration Tests

    @Test("VMConfigBuilder uses VM paths when available")
    func testVMPathsOverrideTemplate() async throws {
        let template = createTestTemplate(
            kernelPath: "/template/kernel",
            initramfsPath: "/template/initramfs",
            firmwarePath: "/template/firmware",
            defaultCmdline: "template cmdline"
        )
        let vm = createTestVM(
            kernelPath: "/vm/kernel",
            initramfsPath: "/vm/initramfs",
            firmwarePath: "/vm/firmware",
            cmdline: "vm cmdline"
        )

        let config = try await VMConfigBuilder.buildVMConfig(from: vm, template: template)

        #expect(config.payload.kernel == "/vm/kernel")
        #expect(config.payload.initramfs == "/vm/initramfs")
        #expect(config.payload.firmware == "/vm/firmware")
        #expect(config.payload.cmdline == "vm cmdline")
    }

    @Test("VMConfigBuilder falls back to template paths")
    func testTemplateFallback() async throws {
        let template = createTestTemplate(
            kernelPath: "/template/kernel",
            initramfsPath: "/template/initramfs",
            firmwarePath: "/template/firmware",
            defaultCmdline: "template cmdline"
        )
        let vm = createTestVM(
            kernelPath: nil,
            initramfsPath: nil,
            firmwarePath: nil,
            cmdline: nil
        )

        let config = try await VMConfigBuilder.buildVMConfig(from: vm, template: template)

        #expect(config.payload.kernel == "/template/kernel")
        #expect(config.payload.initramfs == "/template/initramfs")
        #expect(config.payload.firmware == "/template/firmware")
        #expect(config.payload.cmdline == "template cmdline")
    }

    @Test("VMConfigBuilder handles missing optional template paths")
    func testMissingOptionalPaths() async throws {
        let template = createTestTemplate(
            initramfsPath: nil,
            firmwarePath: nil
        )
        let vm = createTestVM(
            kernelPath: "/vm/kernel",
            initramfsPath: nil,
            firmwarePath: nil,
            cmdline: "cmdline"
        )

        let config = try await VMConfigBuilder.buildVMConfig(from: vm, template: template)

        #expect(config.payload.kernel == "/vm/kernel")
        #expect(config.payload.initramfs == nil)
        #expect(config.payload.firmware == nil)
        #expect(config.payload.cmdline == "cmdline")
    }

    // MARK: - Memory Configuration Tests

    @Test("VMConfigBuilder configures hugepages correctly")
    func testHugepagesConfiguration() async throws {
        let template = createTestTemplate()
        let vm = createTestVM(hugepages: true)

        let config = try await VMConfigBuilder.buildVMConfig(from: vm, template: template)

        #expect(config.memory?.hugepages == true)
    }

    @Test("VMConfigBuilder configures shared memory correctly")
    func testSharedMemoryConfiguration() async throws {
        let template = createTestTemplate()
        let vm = createTestVM(sharedMemory: true)

        let config = try await VMConfigBuilder.buildVMConfig(from: vm, template: template)

        #expect(config.memory?.shared == true)
    }

    @Test("VMConfigBuilder sets memory size from VM")
    func testMemorySize() async throws {
        let template = createTestTemplate()
        let vm = createTestVM(memory: 4096)

        let config = try await VMConfigBuilder.buildVMConfig(from: vm, template: template)

        #expect(config.memory?.size == 4096)
    }

    // MARK: - Disk Configuration Tests

    @Test("VMConfigBuilder creates disk config when disk path is set")
    func testDiskConfiguration() async throws {
        let template = createTestTemplate()
        let vm = createTestVM(diskPath: "/var/lib/strato/disks/vm.qcow2", readonlyDisk: false)

        let config = try await VMConfigBuilder.buildVMConfig(from: vm, template: template)

        #expect(config.disks != nil)
        #expect(config.disks?.count == 1)
        #expect(config.disks?.first?.path == "/var/lib/strato/disks/vm.qcow2")
        #expect(config.disks?.first?.readonly == false)
        #expect(config.disks?.first?.direct == false)
        #expect(config.disks?.first?.id == "disk0")
    }

    @Test("VMConfigBuilder creates readonly disk when specified")
    func testReadonlyDisk() async throws {
        let template = createTestTemplate()
        let vm = createTestVM(diskPath: "/var/lib/strato/disks/vm.qcow2", readonlyDisk: true)

        let config = try await VMConfigBuilder.buildVMConfig(from: vm, template: template)

        #expect(config.disks?.first?.readonly == true)
    }

    @Test("VMConfigBuilder omits disks when no disk path is set")
    func testNoDiskPath() async throws {
        let template = createTestTemplate()
        let vm = createTestVM(diskPath: nil)

        let config = try await VMConfigBuilder.buildVMConfig(from: vm, template: template)

        #expect(config.disks == nil)
    }

    // MARK: - Network Configuration Tests

    @Test("VMConfigBuilder creates network config when MAC address is set")
    func testNetworkConfiguration() async throws {
        let template = createTestTemplate()
        let vm = createTestVM(
            macAddress: "52:54:00:12:34:56",
            ipAddress: "192.168.1.10",
            networkMask: "255.255.255.0"
        )

        let config = try await VMConfigBuilder.buildVMConfig(from: vm, template: template)

        #expect(config.net != nil)
        #expect(config.net?.count == 1)
        #expect(config.net?.first?.mac == "52:54:00:12:34:56")
        #expect(config.net?.first?.ip == "192.168.1.10")
        #expect(config.net?.first?.mask == "255.255.255.0")
        #expect(config.net?.first?.numQueues == 2)
        #expect(config.net?.first?.queueSize == 256)
        #expect(config.net?.first?.id == "net0")
    }

    @Test("VMConfigBuilder uses default IP when not specified")
    func testDefaultIPAddress() async throws {
        let template = createTestTemplate()
        let vm = createTestVM(
            macAddress: "52:54:00:12:34:56",
            ipAddress: nil,
            networkMask: nil
        )

        let config = try await VMConfigBuilder.buildVMConfig(from: vm, template: template)

        #expect(config.net?.first?.ip == "192.168.249.1")
        #expect(config.net?.first?.mask == "255.255.255.0")
    }

    @Test("VMConfigBuilder omits network when no MAC address is set")
    func testNoMACAddress() async throws {
        let template = createTestTemplate()
        let vm = createTestVM(macAddress: nil)

        let config = try await VMConfigBuilder.buildVMConfig(from: vm, template: template)

        #expect(config.net == nil)
    }

    // MARK: - Console Configuration Tests

    @Test("VMConfigBuilder configures console correctly")
    func testConsoleConfiguration() async throws {
        let template = createTestTemplate()
        let vm = createTestVM(
            consoleSocket: "/var/run/console.sock",
            consoleMode: .pty
        )

        let config = try await VMConfigBuilder.buildVMConfig(from: vm, template: template)

        #expect(config.console?.socket == "/var/run/console.sock")
        #expect(config.console?.mode == "Pty")
    }

    @Test("VMConfigBuilder configures serial correctly")
    func testSerialConfiguration() async throws {
        let template = createTestTemplate()
        let vm = createTestVM(
            serialSocket: "/var/run/serial.sock",
            serialMode: .tty
        )

        let config = try await VMConfigBuilder.buildVMConfig(from: vm, template: template)

        #expect(config.serial?.socket == "/var/run/serial.sock")
        #expect(config.serial?.mode == "Tty")
    }

    // MARK: - RNG Configuration Tests

    @Test("VMConfigBuilder configures RNG device")
    func testRNGConfiguration() async throws {
        let template = createTestTemplate()
        let vm = createTestVM()

        let config = try await VMConfigBuilder.buildVMConfig(from: vm, template: template)

        #expect(config.rng?.src == "/dev/urandom")
    }

    // MARK: - Fixed Settings Tests

    @Test("VMConfigBuilder sets fixed boolean flags correctly")
    func testFixedFlags() async throws {
        let template = createTestTemplate()
        let vm = createTestVM()

        let config = try await VMConfigBuilder.buildVMConfig(from: vm, template: template)

        #expect(config.iommu == false)
        #expect(config.watchdog == false)
        #expect(config.pvpanic == false)
    }

    // MARK: - Integration Tests

    @Test("VMConfigBuilder creates complete config with all components")
    func testCompleteConfiguration() async throws {
        let template = createTestTemplate()
        let vm = createTestVM(
            cpu: 4,
            maxCpu: 8,
            memory: 8192,
            disk: 50000,
            hugepages: true,
            sharedMemory: true,
            diskPath: "/var/lib/strato/disks/vm.qcow2",
            readonlyDisk: false,
            macAddress: "52:54:00:12:34:56",
            ipAddress: "192.168.1.100",
            networkMask: "255.255.255.0"
        )

        let config = try await VMConfigBuilder.buildVMConfig(from: vm, template: template)

        // Verify all components are present
        #expect(config.cpus?.bootVcpus == 4)
        #expect(config.cpus?.maxVcpus == 8)
        #expect(config.memory?.size == 8192)
        #expect(config.memory?.hugepages == true)
        #expect(config.memory?.shared == true)
        #expect(config.disks != nil)
        #expect(config.net != nil)
        #expect(config.payload.kernel != nil)
        #expect(config.rng?.src == "/dev/urandom")
    }

    @Test("VMConfigBuilder creates minimal config without optional components")
    func testMinimalConfiguration() async throws {
        let template = createTestTemplate()
        let vm = createTestVM(
            diskPath: nil,
            macAddress: nil
        )

        let config = try await VMConfigBuilder.buildVMConfig(from: vm, template: template)

        // Verify only required components are present
        #expect(config.cpus?.bootVcpus == 2)
        #expect(config.memory?.size == 2048)
        #expect(config.disks == nil)
        #expect(config.net == nil)
        #expect(config.payload.kernel != nil)
        #expect(config.rng?.src == "/dev/urandom")
    }

    // MARK: - CPU Configuration Tests

    @Test("VMConfigBuilder sets CPU counts correctly")
    func testCPUConfiguration() async throws {
        let template = createTestTemplate()
        let vm = createTestVM(cpu: 8, maxCpu: 16)

        let config = try await VMConfigBuilder.buildVMConfig(from: vm, template: template)

        #expect(config.cpus?.bootVcpus == 8)
        #expect(config.cpus?.maxVcpus == 16)
    }

    @Test("VMConfigBuilder disables KVM Hyper-V by default")
    func testKVMHypervDisabled() async throws {
        let template = createTestTemplate()
        let vm = createTestVM()

        let config = try await VMConfigBuilder.buildVMConfig(from: vm, template: template)

        #expect(config.cpus?.kvmHyperv == false)
    }
}
