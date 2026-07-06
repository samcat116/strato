import Testing
import Vapor
import StratoShared
@testable import App

// The template-based builder is deprecated but still exercised by the legacy
// creation path, so these tests intentionally keep covering it.
@Suite("VMSpecBuilder Tests", .serialized)
struct VMSpecBuilderTests {

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
        return VMNetworkInterface(
            vmID: UUID(),
            network: network,
            macAddress: macAddress,
            ipAddress: ipAddress,
            netmask: netmask,
            gateway: gateway,
            mtu: mtu,
            deviceName: deviceName,
            orderIndex: orderIndex
        )
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

    @Test("VMSpecBuilder creates spec with VM and template defaults")
    func testBasicSpecCreation() throws {
        let template = createTestTemplate()
        let vm = createTestVM()

        let spec = VMSpecBuilder.buildVMSpec(from: vm, template: template, networkInterfaces: [])

        #expect(spec.cpus == 2)
        #expect(spec.maxCpus == 4)
        #expect(spec.memoryBytes == 2048)
        #expect(spec.sharedMemory == false)
        #expect(spec.hugepages == false)
    }

    @Test("VMSpecBuilder sets CPU counts correctly")
    func testCPUConfiguration() throws {
        let template = createTestTemplate()
        let vm = createTestVM(cpu: 8, maxCpu: 16)

        let spec = VMSpecBuilder.buildVMSpec(from: vm, template: template, networkInterfaces: [])

        #expect(spec.cpus == 8)
        #expect(spec.maxCpus == 16)
    }

    @Test("VMSpecBuilder sets memory size from VM")
    func testMemorySize() throws {
        let template = createTestTemplate()
        let vm = createTestVM(memory: 4096)

        let spec = VMSpecBuilder.buildVMSpec(from: vm, template: template, networkInterfaces: [])

        #expect(spec.memoryBytes == 4096)
    }

    @Test("VMSpecBuilder configures hugepages correctly")
    func testHugepagesConfiguration() throws {
        let template = createTestTemplate()
        let vm = createTestVM(hugepages: true)

        let spec = VMSpecBuilder.buildVMSpec(from: vm, template: template, networkInterfaces: [])

        #expect(spec.hugepages == true)
    }

    @Test("VMSpecBuilder configures shared memory correctly")
    func testSharedMemoryConfiguration() throws {
        let template = createTestTemplate()
        let vm = createTestVM(sharedMemory: true)

        let spec = VMSpecBuilder.buildVMSpec(from: vm, template: template, networkInterfaces: [])

        #expect(spec.sharedMemory == true)
    }

    // MARK: - Boot Source Tests

    @Test("VMSpecBuilder uses VM paths when available")
    func testVMPathsOverrideTemplate() throws {
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

        let spec = VMSpecBuilder.buildVMSpec(from: vm, template: template, networkInterfaces: [])
        let boot = try directKernel(spec)

        #expect(boot.kernel == "/vm/kernel")
        #expect(boot.initramfs == "/vm/initramfs")
        #expect(boot.cmdline == "vm cmdline console=tty0 console=ttyS0,115200 console=ttyAMA0,115200 console=hvc0")
    }

    @Test("VMSpecBuilder falls back to template paths")
    func testTemplateFallback() throws {
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

        let spec = VMSpecBuilder.buildVMSpec(from: vm, template: template, networkInterfaces: [])
        let boot = try directKernel(spec)

        #expect(boot.kernel == "/template/kernel")
        #expect(boot.initramfs == "/template/initramfs")
        #expect(
            boot.cmdline == "template cmdline console=tty0 console=ttyS0,115200 console=ttyAMA0,115200 console=hvc0")
    }

    @Test("VMSpecBuilder handles missing optional template paths")
    func testMissingOptionalPaths() throws {
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

        let spec = VMSpecBuilder.buildVMSpec(from: vm, template: template, networkInterfaces: [])
        let boot = try directKernel(spec)

        #expect(boot.kernel == "/vm/kernel")
        #expect(boot.initramfs == nil)
        #expect(boot.cmdline == "cmdline console=tty0 console=ttyS0,115200 console=ttyAMA0,115200 console=hvc0")
    }

    @Test("VMSpecBuilder falls back to firmware boot when no kernel is specified")
    func testFirmwareBootWithoutKernel() throws {
        let template = createTestTemplate(kernelPath: "")
        let vm = createTestVM(kernelPath: nil, firmwarePath: "/vm/firmware")

        let spec = VMSpecBuilder.buildVMSpec(from: vm, template: template, networkInterfaces: [])

        guard case .disk(let firmware) = spec.boot else {
            Issue.record("Expected disk (firmware) boot, got \(spec.boot)")
            return
        }
        #expect(firmware == "/vm/firmware")
    }

    // MARK: - Volume Tests

    @Test("VMSpecBuilder creates a volume when disk path is set")
    func testVolumeConfiguration() throws {
        let template = createTestTemplate()
        let vm = createTestVM(diskPath: "/var/lib/strato/disks/vm.qcow2", readonlyDisk: false)

        let spec = VMSpecBuilder.buildVMSpec(from: vm, template: template, networkInterfaces: [])

        #expect(spec.volumes.count == 1)
        #expect(spec.volumes.first?.storagePath == "/var/lib/strato/disks/vm.qcow2")
        #expect(spec.volumes.first?.readonly == false)
        #expect(spec.volumes.first?.deviceName == "disk0")
        #expect(spec.volumes.first?.volumeId == nil)
    }

    @Test("VMSpecBuilder creates readonly volume when specified")
    func testReadonlyVolume() throws {
        let template = createTestTemplate()
        let vm = createTestVM(diskPath: "/var/lib/strato/disks/vm.qcow2", readonlyDisk: true)

        let spec = VMSpecBuilder.buildVMSpec(from: vm, template: template, networkInterfaces: [])

        #expect(spec.volumes.first?.readonly == true)
    }

    @Test("VMSpecBuilder omits volumes when no disk path is set")
    func testNoDiskPath() throws {
        let template = createTestTemplate()
        let vm = createTestVM(diskPath: nil)

        let spec = VMSpecBuilder.buildVMSpec(from: vm, template: template, networkInterfaces: [])

        #expect(spec.volumes.isEmpty)
    }

    // MARK: - Network Tests

    @Test("VMSpecBuilder maps a network interface to a network spec")
    func testNetworkConfiguration() throws {
        let template = createTestTemplate()
        let vm = createTestVM()
        let interface = createTestInterface(
            macAddress: "52:54:00:12:34:56",
            ipAddress: "192.168.1.10",
            netmask: "255.255.255.0"
        )

        let spec = VMSpecBuilder.buildVMSpec(from: vm, template: template, networkInterfaces: [interface])

        #expect(spec.networks.count == 1)
        #expect(spec.networks.first?.network == "default")
        #expect(spec.networks.first?.macAddress == "52:54:00:12:34:56")
        #expect(spec.networks.first?.ipAddress == "192.168.1.10")
        #expect(spec.networks.first?.netmask == "255.255.255.0")
    }

    @Test("VMSpecBuilder passes the NIC's gateway through to the network spec")
    func testGatewayPassthrough() throws {
        let template = createTestTemplate()
        let vm = createTestVM()
        let interface = createTestInterface(gateway: "192.168.1.1")

        let spec = VMSpecBuilder.buildVMSpec(from: vm, template: template, networkInterfaces: [interface])

        #expect(spec.networks.first?.gateway == "192.168.1.1")
    }

    @Test("VMSpecBuilder does not fabricate an IP when none is assigned")
    func testNoFabricatedIPAddress() throws {
        let template = createTestTemplate()
        let vm = createTestVM()
        let interface = createTestInterface(ipAddress: nil, netmask: nil)

        let spec = VMSpecBuilder.buildVMSpec(from: vm, template: template, networkInterfaces: [interface])

        #expect(spec.networks.first?.ipAddress == nil)
        #expect(spec.networks.first?.netmask == nil)
    }

    @Test("VMSpecBuilder omits networks when the VM has no interfaces")
    func testNoNetworkInterfaces() throws {
        let template = createTestTemplate()
        let vm = createTestVM()

        let spec = VMSpecBuilder.buildVMSpec(from: vm, template: template, networkInterfaces: [])

        #expect(spec.networks.isEmpty)
    }

    @Test("VMSpecBuilder orders multiple interfaces by order index, then device name")
    func testMultipleInterfaceOrdering() throws {
        let template = createTestTemplate()
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
        let spec = VMSpecBuilder.buildVMSpec(from: vm, template: template, networkInterfaces: [second, first])

        #expect(spec.networks.count == 2)
        #expect(spec.networks.first?.macAddress == "52:54:00:00:00:01")
        #expect(spec.networks.first?.network == "default")
        #expect(spec.networks.last?.macAddress == "52:54:00:00:00:02")
        #expect(spec.networks.last?.network == "backend")
    }

    // MARK: - Console Tests

    @Test("VMSpecBuilder carries console and serial mode preferences")
    func testConsoleConfiguration() throws {
        let template = createTestTemplate()
        let vm = createTestVM(consoleMode: .pty, serialMode: .tty)

        let spec = VMSpecBuilder.buildVMSpec(from: vm, template: template, networkInterfaces: [])

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
        let template = createTestTemplate()
        let vm = createTestVM(
            cpu: 4,
            maxCpu: 8,
            memory: 8192,
            disk: 50000,
            hugepages: true,
            sharedMemory: true,
            diskPath: "/var/lib/strato/disks/vm.qcow2",
            readonlyDisk: false
        )
        let interface = createTestInterface(ipAddress: "192.168.1.100")

        let spec = VMSpecBuilder.buildVMSpec(from: vm, template: template, networkInterfaces: [interface])
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
        let template = createTestTemplate()
        let vm = createTestVM(diskPath: nil)

        let spec = VMSpecBuilder.buildVMSpec(from: vm, template: template, networkInterfaces: [])

        #expect(spec.cpus == 2)
        #expect(spec.memoryBytes == 2048)
        #expect(spec.volumes.isEmpty)
        #expect(spec.networks.isEmpty)
    }
}
