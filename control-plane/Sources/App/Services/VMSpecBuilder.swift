import Foundation
import Vapor
import StratoShared

/// Builds the hypervisor-neutral `VMSpec` sent to agents. The spec deliberately
/// carries no device-level realization (host paths the control plane cannot know,
/// tap names, queue sizing, machine types) — agents derive those when translating
/// the spec into their driver-native configuration.
struct VMSpecBuilder {
    private static func ensureSerialConsole(_ cmdline: String?) -> String {
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

    /// Direct kernel boot when a kernel is specified, firmware (disk) boot otherwise.
    private static func bootSource(
        kernel: String?,
        initramfs: String?,
        cmdline: String?,
        firmware: String?
    ) -> BootSource {
        if let kernel, !kernel.isEmpty {
            return .directKernel(
                kernel: kernel,
                initramfs: initramfs,
                cmdline: ensureSerialConsole(cmdline)
            )
        }
        return .disk(firmware: firmware)
    }

    /// Builds network specs from the VM's interfaces, ordered by order index
    /// (then device name, for stability when orders collide). Interfaces must
    /// have `addresses` eager-loaded — the per-family address rows are the
    /// source of NIC addressing (the legacy single-address columns are dead).
    ///
    /// `networks` maps logical-network name → its model, supplying the DHCP/DNS
    /// configuration agents program into OVN. It defaults empty (DHCP disabled)
    /// so callers that don't care about DHCP — and tests — need not fetch it.
    static func networkSpecs(
        from interfaces: [VMNetworkInterface],
        networks: [String: LogicalNetwork] = [:]
    ) -> [NetworkSpec] {
        interfaces
            .sorted { ($0.orderIndex, $0.deviceName) < ($1.orderIndex, $1.deviceName) }
            .map { interface in
                let network = networks[interface.network]
                let ipv4 = interface.ipv4Address
                let ipv6 = interface.ipv6Address
                return NetworkSpec(
                    network: interface.network,
                    // The network's id, so the agent names its OVN switch after
                    // the id (not the user-chosen name) and lands the VM on the
                    // same switch the network reconciler creates (issue #342).
                    networkId: network?.id,
                    macAddress: interface.macAddress,
                    ipAddress: ipv4?.address,
                    // Old agents still read a dotted netmask off the wire.
                    netmask: interface.ipv4Netmask,
                    gateway: ipv4?.gateway,
                    ipv6Address: ipv6?.address,
                    ipv6PrefixLength: ipv6?.prefixLength,
                    gateway6: ipv6?.gateway,
                    mtu: interface.mtu,
                    dhcpEnabled: network?.dhcpEnabled ?? false,
                    dnsServers: network?.dnsServers ?? [],
                    domainName: network?.domainName,
                    leaseTime: network?.leaseTime
                )
            }
    }

    /// Legacy single-disk volume list from `vm.diskPath`.
    private static func legacyVolumeSpecs(from vm: VM) -> [VolumeSpec] {
        guard let diskPath = vm.diskPath else { return [] }
        return [
            VolumeSpec(
                deviceName: "disk0",
                storagePath: diskPath,
                readonly: vm.readonlyDisk
            )
        ]
    }

    /// Builds a VM spec from VM and Image. The boot volume is materialized by the
    /// agent from the cached image (see `buildImageInfo`), so no volume entry is
    /// sent unless the VM carries a legacy disk path.
    static func buildVMSpec(
        from vm: VM, image: Image, networkInterfaces: [VMNetworkInterface],
        networks: [String: LogicalNetwork] = [:]
    ) -> VMSpec {
        let cpuCount = vm.cpu > 0 ? vm.cpu : (image.defaultCpu ?? 1)
        let memorySize = vm.memory > 0 ? vm.memory : (image.defaultMemory ?? 1024 * 1024 * 1024)  // 1GB default

        return VMSpec(
            cpus: cpuCount,
            maxCpus: vm.maxCpu > 0 ? vm.maxCpu : cpuCount,
            memoryBytes: memorySize,
            diskBytes: vm.disk,
            sharedMemory: vm.sharedMemory,
            hugepages: vm.hugepages,
            boot: bootSource(
                kernel: vm.kernelPath,
                initramfs: vm.initramfsPath,
                cmdline: vm.cmdline ?? image.defaultCmdline,
                firmware: vm.firmwarePath
            ),
            volumes: legacyVolumeSpecs(from: vm),
            networks: networkSpecs(from: networkInterfaces, networks: networks),
            console: ConsoleSpec(console: vm.consoleMode, serial: vm.serialMode),
            sshAuthorizedKeys: vm.sshPublicKey.map { [$0] } ?? [],
            userData: vm.userData
        )
    }

    /// Builds a VM spec from VM and Image, with attached volumes
    /// - Parameters:
    ///   - vm: The VM to build the spec for (must have volumes eager-loaded with .with(\.$volumes))
    ///   - image: The image used for the boot volume (if no boot volume attached)
    ///   - volumes: Attached volumes (sorted by boot order, then device name)
    ///   - networkInterfaces: The VM's network interfaces
    static func buildVMSpecWithVolumes(
        from vm: VM, image: Image?, volumes: [Volume], networkInterfaces: [VMNetworkInterface],
        networks: [String: LogicalNetwork] = [:]
    ) -> VMSpec {
        let cpuCount = vm.cpu > 0 ? vm.cpu : (image?.defaultCpu ?? 1)
        let memorySize = vm.memory > 0 ? vm.memory : (image?.defaultMemory ?? 1024 * 1024 * 1024)  // 1GB default

        var volumes = volumeSpecs(from: volumes)
        if volumes.isEmpty {
            volumes = legacyVolumeSpecs(from: vm)
        }

        return VMSpec(
            cpus: cpuCount,
            maxCpus: vm.maxCpu > 0 ? vm.maxCpu : cpuCount,
            memoryBytes: memorySize,
            diskBytes: vm.disk,
            sharedMemory: vm.sharedMemory,
            hugepages: vm.hugepages,
            boot: bootSource(
                kernel: vm.kernelPath,
                initramfs: vm.initramfsPath,
                cmdline: vm.cmdline ?? image?.defaultCmdline,
                firmware: vm.firmwarePath
            ),
            volumes: volumes,
            networks: networkSpecs(from: networkInterfaces, networks: networks),
            console: ConsoleSpec(console: vm.consoleMode, serial: vm.serialMode),
            sshAuthorizedKeys: vm.sshPublicKey.map { [$0] } ?? [],
            userData: vm.userData
        )
    }

    /// Builds volume specs from attached volumes, sorted by boot order (explicit
    /// orders first), then device name.
    static func volumeSpecs(from volumes: [Volume]) -> [VolumeSpec] {
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

        var specs: [VolumeSpec] = []
        for volume in sortedVolumes where volume.status == .attached {
            guard let storagePath = volume.storagePath else { continue }
            specs.append(
                VolumeSpec(
                    volumeId: volume.id,
                    deviceName: volume.deviceName ?? "disk\(specs.count)",
                    storagePath: storagePath,
                    readonly: false,  // Could be enhanced to track readonly per-volume
                    bootOrder: volume.bootOrder
                ))
        }
        return specs
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

        guard image.status == .ready else {
            throw Abort(.badRequest, reason: "Image is not ready for use")
        }

        let projectId = image.$project.id
        let expiresAt = Date().addingTimeInterval(expiresIn)

        func sign(_ kind: ArtifactKind?) -> String {
            URLSigningService.signImageDownloadURL(
                imageId: imageId,
                projectId: projectId,
                agentName: agentName,
                baseURL: controlPlaneURL,
                expiresIn: expiresIn,
                signingKey: signingKey,
                artifactKind: kind
            )
        }

        // One signed download descriptor per typed artifact. Exclude any artifact
        // that isn't fully materialized — a pending/downloading URL fetch has no
        // real checksum or bytes yet and must never reach an agent.
        let artifacts = (image.$artifacts.value ?? []).filter { $0.status == .ready }.map { artifact in
            ArtifactInfo(
                kind: artifact.kind,
                format: artifact.format?.rawValue,
                filename: artifact.filename,
                checksum: artifact.checksum,
                size: artifact.size,
                downloadURL: sign(artifact.kind),
                expiresAt: expiresAt
            )
        }

        // Top-level fields describe the primary disk for the QEMU disk path and
        // legacy agents. Prefer the disk-image artifact; fall back to any artifact,
        // then to the image's own single-file columns.
        let primary = artifacts.first { $0.kind == .diskImage } ?? artifacts.first
        if let primary {
            return ImageInfo(
                imageId: imageId,
                projectId: projectId,
                filename: primary.filename,
                checksum: primary.checksum,
                size: primary.size,
                downloadURL: primary.downloadURL,
                expiresAt: expiresAt,
                architecture: image.architecture,
                artifacts: artifacts
            )
        }

        // No artifacts (image predates the backfill): fall back to legacy fields.
        guard let checksum = image.checksum else {
            throw Abort(.internalServerError, reason: "Image checksum is required")
        }
        return ImageInfo(
            imageId: imageId,
            projectId: projectId,
            filename: image.filename,
            checksum: checksum,
            size: image.size,
            downloadURL: sign(nil),
            expiresAt: expiresAt,
            architecture: image.architecture,
            artifacts: []
        )
    }
}
