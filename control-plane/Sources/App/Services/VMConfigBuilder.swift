import Foundation
import Vapor
import StratoShared

struct VMConfigBuilder {
    private static func ensureSerialConsole(_ cmdline: String?) -> String? {
        let trimmed = (cmdline ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "console=tty0 console=ttyS0,115200 console=ttyAMA0,115200 console=hvc0"
        }
        var parts = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        var seen: Set<String> = []
        for index in parts.indices {
            if parts[index].hasPrefix("console=tty0") {
                parts[index] = "console=tty0"
                seen.insert("tty0")
            } else if parts[index].hasPrefix("console=ttyS0") {
                parts[index] = "console=ttyS0,115200"
                seen.insert("ttyS0")
            } else if parts[index].hasPrefix("console=ttyAMA0") {
                parts[index] = "console=ttyAMA0,115200"
                seen.insert("ttyAMA0")
            } else if parts[index].hasPrefix("console=hvc0") {
                parts[index] = "console=hvc0"
                seen.insert("hvc0")
            }
        }
        if !seen.contains("tty0") { parts.append("console=tty0") }
        if !seen.contains("ttyS0") { parts.append("console=ttyS0,115200") }
        if !seen.contains("ttyAMA0") { parts.append("console=ttyAMA0,115200") }
        if !seen.contains("hvc0") { parts.append("console=hvc0") }
        return parts.joined(separator: " ")
    }

    /// Builds VM configuration from VM and template (legacy method)
    /// - Note: This method is deprecated. Use `buildVMConfig(from:image:)` instead.
    @available(*, deprecated, message: "Use buildVMConfig(from:image:) instead")
    static func buildVMConfig(from vm: VM, template: VMTemplate) async throws -> VmConfig {
        // Payload configuration
        let payload = PayloadConfig(
            firmware: vm.firmwarePath ?? template.firmwarePath,
            kernel: vm.kernelPath ?? template.kernelPath,
            cmdline: ensureSerialConsole(vm.cmdline ?? template.defaultCmdline),
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

    /// Builds VM configuration from VM and Image (new method)
    static func buildVMConfig(from vm: VM, image: Image) async throws -> VmConfig {
        // Payload configuration - use image defaults if available
        let payload = PayloadConfig(
            firmware: vm.firmwarePath,
            kernel: vm.kernelPath,
            cmdline: ensureSerialConsole(vm.cmdline ?? image.defaultCmdline),
            initramfs: vm.initramfsPath
        )

        // CPU configuration - use image defaults or VM values
        let cpuCount = vm.cpu > 0 ? vm.cpu : (image.defaultCpu ?? 1)
        let cpus = CpusConfig(
            bootVcpus: cpuCount,
            maxVcpus: vm.maxCpu > 0 ? vm.maxCpu : cpuCount,
            kvmHyperv: false
        )

        // Memory configuration - use image defaults or VM values
        let memorySize = vm.memory > 0 ? vm.memory : (image.defaultMemory ?? 1024 * 1024 * 1024) // 1GB default
        let memory = MemoryConfig(
            size: memorySize,
            mergeable: false,
            shared: vm.sharedMemory,
            hugepages: vm.hugepages,
            thp: true
        )

        // Disk configuration - disk path will be set by agent using cached image
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

    /// Builds VM configuration from VM and Image, with attached volumes (QEMU only)
    /// This method builds disk configs from the VM's attached volumes instead of the legacy diskPath field
    /// - Parameters:
    ///   - vm: The VM to build config for (must have volumes eager-loaded with .with(\.$volumes))
    ///   - image: The image used for the boot volume (if no boot volume attached)
    ///   - volumes: Attached volumes (sorted by boot order, then device name)
    /// - Returns: VmConfig with disk configs built from volumes
    static func buildVMConfigWithVolumes(from vm: VM, image: Image?, volumes: [Volume]) async throws -> VmConfig {
        // Payload configuration - use image defaults if available
        let payload = PayloadConfig(
            firmware: vm.firmwarePath,
            kernel: vm.kernelPath,
            cmdline: ensureSerialConsole(vm.cmdline ?? image?.defaultCmdline),
            initramfs: vm.initramfsPath
        )

        // CPU configuration - use image defaults or VM values
        let cpuCount = vm.cpu > 0 ? vm.cpu : (image?.defaultCpu ?? 1)
        let cpus = CpusConfig(
            bootVcpus: cpuCount,
            maxVcpus: vm.maxCpu > 0 ? vm.maxCpu : cpuCount,
            kvmHyperv: false
        )

        // Memory configuration - use image defaults or VM values
        let memorySize = vm.memory > 0 ? vm.memory : (image?.defaultMemory ?? 1024 * 1024 * 1024) // 1GB default
        let memory = MemoryConfig(
            size: memorySize,
            mergeable: false,
            shared: vm.sharedMemory,
            hugepages: vm.hugepages,
            thp: true
        )

        // Disk configuration from volumes
        // Sort by boot order (nil boot order comes after explicit orders), then by device name
        let sortedVolumes = volumes.sorted { v1, v2 in
            switch (v1.bootOrder, v2.bootOrder) {
            case (let o1?, let o2?):
                return o1 < o2
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            case (nil, nil):
                return (v1.deviceName ?? "") < (v2.deviceName ?? "")
            }
        }

        var disks: [DiskConfig] = []
        for volume in sortedVolumes where volume.status == .attached {
            guard let storagePath = volume.storagePath else { continue }
            let disk = DiskConfig(
                path: storagePath,
                readonly: false, // Could be enhanced to track readonly per-volume
                direct: false,
                id: volume.deviceName ?? "disk\(disks.count)"
            )
            disks.append(disk)
        }

        // Fallback to legacy diskPath if no volumes attached
        if disks.isEmpty, let diskPath = vm.diskPath {
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

    /// Builds disk configurations from attached volumes
    /// Used for updating VM disk config when volumes are attached/detached
    static func buildDiskConfigs(from volumes: [Volume]) -> [DiskConfig] {
        // Sort by boot order (nil boot order comes after explicit orders), then by device name
        let sortedVolumes = volumes.sorted { v1, v2 in
            switch (v1.bootOrder, v2.bootOrder) {
            case (let o1?, let o2?):
                return o1 < o2
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            case (nil, nil):
                return (v1.deviceName ?? "") < (v2.deviceName ?? "")
            }
        }

        var disks: [DiskConfig] = []
        for volume in sortedVolumes where volume.status == .attached {
            guard let storagePath = volume.storagePath else { continue }
            let disk = DiskConfig(
                path: storagePath,
                readonly: false,
                direct: false,
                id: volume.deviceName ?? "disk\(disks.count)"
            )
            disks.append(disk)
        }

        return disks
    }

    /// Builds ImageInfo for agent to download and cache the image
    /// - Parameters:
    ///   - image: The image to build info for
    ///   - controlPlaneURL: Base URL of the control plane
    ///   - agentName: Name of the agent that will download the image
    ///   - signingKey: Secret key for signing the download URL
    ///   - expiresIn: Time until the URL expires (default: 1 hour)
    /// - Returns: ImageInfo with a signed download URL
    static func buildImageInfo(
        from image: Image,
        controlPlaneURL: String,
        agentName: String,
        signingKey: String,
        expiresIn: TimeInterval = URLSigningService.defaultExpiration
    ) throws -> ImageInfo {
        guard let imageId = image.id else {
            throw Abort(.internalServerError, reason: "Image ID is required")
        }

        guard let checksum = image.checksum else {
            throw Abort(.internalServerError, reason: "Image checksum is required")
        }

        guard image.status == .ready else {
            throw Abort(.badRequest, reason: "Image is not ready for use")
        }

        // Generate signed URL for agent download
        let downloadURL = URLSigningService.signImageDownloadURL(
            imageId: imageId,
            projectId: image.$project.id,
            agentName: agentName,
            baseURL: controlPlaneURL,
            expiresIn: expiresIn,
            signingKey: signingKey
        )

        // Calculate expiration date for agent awareness
        let expiresAt = Date().addingTimeInterval(expiresIn)

        return ImageInfo(
            imageId: imageId,
            projectId: image.$project.id,
            filename: image.filename,
            checksum: checksum,
            size: image.size,
            downloadURL: downloadURL,
            expiresAt: expiresAt
        )
    }
}
