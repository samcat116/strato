import Foundation
import Vapor
import StratoShared

struct VMConfigBuilder {
    static func buildVMConfig(from vm: VM, template: VMTemplate) async throws -> VmConfig {
        // Payload configuration
        let payload = PayloadConfig(
            firmware: vm.firmwarePath ?? template.firmwarePath,
            kernel: vm.kernelPath ?? template.kernelPath,
            cmdline: vm.cmdline ?? template.defaultCmdline,
            initramfs: vm.initramfsPath ?? template.initramfsPath
        )

        // CPU configuration
        let cpus = CpusConfig(
            bootVcpus: vm.cpu,
            maxVcpus: vm.maxCpu,
            kvmHyperv: false
        )

        // Memory configuration
        let memory = MemoryConfig(
            size: vm.memory,
            mergeable: false,
            shared: vm.sharedMemory,
            hugepages: vm.hugepages,
            thp: true
        )

        // Disk configuration
        var disks: [DiskConfig] = []
        if let diskPath = vm.diskPath {
            let disk = DiskConfig(
                path: diskPath,
                readonly: vm.readonlyDisk,
                direct: false,
                id: "disk0"
            )
            disks.append(disk)
        }

        // Network configuration
        var networks: [NetConfig] = []
        if let macAddress = vm.macAddress {
            let network = NetConfig(
                ip: vm.ipAddress ?? "192.168.249.1",
                mask: vm.networkMask ?? "255.255.255.0",
                mac: macAddress,
                numQueues: 2,
                queueSize: 256,
                id: "net0"
            )
            networks.append(network)
        }

        // Console configuration
        let console = ConsoleConfig(
            socket: vm.consoleSocket,
            mode: vm.consoleMode.rawValue
        )

        let serial = ConsoleConfig(
            socket: vm.serialSocket,
            mode: vm.serialMode.rawValue
        )

        // RNG configuration
        let rng = RngConfig(src: "/dev/urandom")

        return VmConfig(
            cpus: cpus,
            memory: memory,
            payload: payload,
            disks: disks.isEmpty ? nil : disks,
            net: networks.isEmpty ? nil : networks,
            rng: rng,
            serial: serial,
            console: console,
            iommu: false,
            watchdog: false,
            pvpanic: false
        )
    }
}
