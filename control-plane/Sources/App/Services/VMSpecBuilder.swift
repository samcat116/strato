import Foundation
import Vapor
import StratoShared

/// Builds the hypervisor-neutral `VMSpec` sent to agents. The spec deliberately
/// carries no device-level realization (host paths the control plane cannot know,
/// tap names, queue sizing, machine types) — agents derive those when translating
/// the spec into their driver-native configuration.
struct VMSpecBuilder {
    /// Upper bound on a guest kernel cmdline, in unicode scalars. The VM-create
    /// API applies the same 4096 bound in UTF-8 bytes; the two agree for the
    /// ASCII a cmdline is made of, and where they diverge this sink is the
    /// stricter of the pair.
    private static let maxCmdlineLength = 4096

    private static func ensureSerialConsole(_ cmdline: String?) -> String {
        // Sanitize before use: the cmdline is resolved by callers as
        // `vm.cmdline ?? image.defaultCmdline`, and an image's defaultCmdline is
        // settable through the image API — so this is the single sink that must
        // hold for every source. Strip control characters (NUL, escapes, stray
        // newlines the whitespace split below wouldn't neutralize) and cap the
        // length, so a stored cmdline can't smuggle extra directives or
        // unbounded data into the boot arguments. VM create additionally
        // rejects these at the API for immediate feedback.
        let cleaned = (cmdline ?? "").unicodeScalars
            .filter { $0.value >= 0x20 && $0.value != 0x7f }
            .prefix(maxCmdlineLength)
        let trimmed = String(String.UnicodeScalarView(cleaned))
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// The VM's NICs in device order, each paired with the logical network it
    /// attaches to. Interfaces must have `addresses` eager-loaded — the
    /// per-family address rows are the source of NIC addressing (the legacy
    /// single-address columns are dead).
    ///
    /// The one decision point for both halves of what a sync says about a NIC:
    /// the `VMSpec`'s `NetworkSpec` list and the `InstanceMetadata.nics` the
    /// guest reads. Ordering and the drop policy are settled here so the two
    /// cannot disagree — a guest whose metadata lists NICs its spec doesn't
    /// (or in another order) has no way to tell which is right.
    ///
    /// `networks` maps logical-network id → its model, supplying the network's
    /// name and the DHCP/DNS configuration agents program into OVN. A NIC whose
    /// network is absent from the map is dropped entirely: the row it points
    /// at is guaranteed by a foreign key, so a miss means the caller under-
    /// fetched, and a half-built spec would put the port on the wrong switch.
    ///
    /// `logger`, when supplied, records a dropped NIC. A miss is only reachable
    /// through an assembly bug, but dropping one silently costs a VM a NIC with
    /// no symptom anywhere — so the sync paths pass a logger and the pure
    /// callers (tests) need not.
    static func resolvedInterfaces(
        from interfaces: [VMNetworkInterface],
        networks: [UUID: LogicalNetwork],
        logger: Logger? = nil
    ) -> [(interface: VMNetworkInterface, network: LogicalNetwork)] {
        interfaces.inDeviceOrder
            .filter { $0.detachGeneration == nil }
            .compactMap { interface in
                guard let network = networks[interface.logicalNetworkID] else {
                    logger?.error(
                        "NIC's logical network was not loaded; omitting it from the VM's desired state",
                        metadata: [
                            "interfaceId": .string(interface.id?.uuidString ?? "unsaved"),
                            "networkId": .string(interface.logicalNetworkID.uuidString),
                            "deviceName": .string(interface.deviceName),
                        ])
                    return nil
                }
                return (interface, network)
            }
    }

    /// Builds network specs from the VM's interfaces (see
    /// `resolvedInterfaces(from:networks:logger:)` for ordering, the eager-load
    /// requirement, and what happens to a NIC whose network wasn't loaded).
    ///
    /// `securityGroupsByInterface` maps NIC id → its security-group ids;
    /// missing entries emit nil (unmanaged), which is also the default so
    /// callers that predate security groups — and tests — need not fetch it.
    ///
    /// `sendsMetadataPort` gates `metadataEnabled` on the receiving agent's protocol
    /// version, exactly as `securityGroupsByInterface` is gated by its caller.
    static func networkSpecs(
        from interfaces: [VMNetworkInterface],
        networks: [UUID: LogicalNetwork] = [:],
        securityGroupsByInterface: [UUID: [UUID]] = [:],
        sendsMetadataPort: Bool = true,
        siteResolverCapable: Bool? = true,
        logger: Logger? = nil
    ) -> [NetworkSpec] {
        networkSpecs(
            fromResolved: resolvedInterfaces(from: interfaces, networks: networks, logger: logger),
            securityGroupsByInterface: securityGroupsByInterface,
            sendsMetadataPort: sendsMetadataPort,
            siteResolverCapable: siteResolverCapable)
    }

    /// The same, for a caller that resolved the NICs itself — the sync, which
    /// hands one resolution to both the spec and the VM's instance metadata so
    /// the two lists agree by construction and an under-fetched NIC is logged
    /// once rather than once per consumer.
    static func networkSpecs(
        fromResolved resolved: [(interface: VMNetworkInterface, network: LogicalNetwork)],
        securityGroupsByInterface: [UUID: [UUID]] = [:],
        sendsMetadataPort: Bool = true,
        siteResolverCapable: Bool? = true
    ) -> [NetworkSpec] {
        resolved.map { interface, network in
            NetworkSpec.build(
                interface: interface,
                network: network,
                securityGroupIds: interface.id.flatMap { id in securityGroupsByInterface[id] },
                sendsMetadataPort: sendsMetadataPort,
                siteResolverCapable: siteResolverCapable)
        }
    }

    /// Builds the canonical VM spec. Every VM must carry exactly one managed
    /// boot volume; a missing or ambiguous boot disk is a persisted-data
    /// invariant violation, never a reason to reconstruct a path-only disk.
    /// - Parameters:
    ///   - vm: The VM to build the spec for (must have volumes eager-loaded with .with(\.$volumes))
    ///   - image: Image defaults used for CPU, memory, and direct-kernel boot metadata
    ///   - volumes: Attached volumes (sorted by boot order, then device name)
    ///   - networkInterfaces: The VM's network interfaces
    static func buildVMSpec(
        from vm: VM, image: Image?, volumes: [Volume], networkInterfaces: [VMNetworkInterface],
        storagePathsByVolumeID: [UUID: String] = [:],
        networks: [UUID: LogicalNetwork] = [:],
        securityGroupsByInterface: [UUID: [UUID]] = [:],
        sendsMetadataPort: Bool = true,
        siteResolverCapable: Bool? = true,
        logger: Logger? = nil
    ) throws -> VMSpec {
        try buildVMSpec(
            from: vm, image: image, volumes: volumes,
            storagePathsByVolumeID: storagePathsByVolumeID,
            resolvedInterfaces: resolvedInterfaces(
                from: networkInterfaces, networks: networks, logger: logger),
            securityGroupsByInterface: securityGroupsByInterface,
            sendsMetadataPort: sendsMetadataPort,
            siteResolverCapable: siteResolverCapable)
    }

    /// The same, for a caller holding an already-resolved NIC list (see
    /// `networkSpecs(fromResolved:securityGroupsByInterface:sendsMetadataPort:)`).
    static func buildVMSpec(
        from vm: VM, image: Image?, volumes: [Volume],
        storagePathsByVolumeID: [UUID: String] = [:],
        resolvedInterfaces: [(interface: VMNetworkInterface, network: LogicalNetwork)],
        securityGroupsByInterface: [UUID: [UUID]] = [:],
        sendsMetadataPort: Bool = true,
        siteResolverCapable: Bool? = true
    ) throws -> VMSpec {
        let cpuCount = vm.cpu > 0 ? vm.cpu : (image?.defaultCpu ?? 1)
        let memorySize = vm.memory > 0 ? vm.memory : (image?.defaultMemory ?? 1024 * 1024 * 1024)  // 1GB default

        let attachedVolumes = volumes.filter { $0.$vm.id != nil }
        let bootVolumes = attachedVolumes.filter { $0.volumeType == .boot }
        guard bootVolumes.count == 1 else {
            throw Abort(
                .internalServerError,
                reason: "VM \(vm.id?.uuidString ?? "unsaved") must have exactly one managed boot volume")
        }
        let bootVolume = bootVolumes[0]
        guard bootVolume.deviceName == VolumeDeviceName.disk(0).rawValue,
            bootVolume.bootOrder == 0,
            !bootVolume.readonly
        else {
            throw Abort(
                .internalServerError,
                reason: "VM \(vm.id?.uuidString ?? "unsaved") has a non-canonical boot volume")
        }
        if vm.desiredStatus != .absent, bootVolume.desiredStatus != .present {
            throw Abort(
                .internalServerError,
                reason: "Live VM \(vm.id?.uuidString ?? "unsaved") has a terminating boot volume")
        }
        let desiredVolumes =
            vm.desiredStatus == .absent
            ? attachedVolumes : attachedVolumes.filter { $0.desiredStatus == .present }
        let volumeSpecs = try volumeSpecs(
            from: desiredVolumes, storagePathsByVolumeID: storagePathsByVolumeID)

        return VMSpec(
            cpus: cpuCount,
            maxCpus: vm.maxCpu > 0 ? vm.maxCpu : cpuCount,
            memoryBytes: memorySize,
            maxMemoryBytes: vm.maxMemory > memorySize ? vm.maxMemory : memorySize,
            balloonTargetBytes: vm.balloonTarget,
            diskBytes: vm.disk,
            sharedMemory: vm.sharedMemory,
            hugepages: vm.hugepages,
            boot: bootSource(
                kernel: vm.kernelPath,
                initramfs: vm.initramfsPath,
                cmdline: vm.cmdline ?? image?.defaultCmdline,
                firmware: vm.firmwarePath
            ),
            machine: MachineProfile(secureBoot: vm.secureBoot, tpm: vm.tpmEnabled),
            guestAgentEnabled: vm.guestAgentEnabled,
            volumes: volumeSpecs,
            networks: networkSpecs(
                fromResolved: resolvedInterfaces,
                securityGroupsByInterface: securityGroupsByInterface,
                sendsMetadataPort: sendsMetadataPort,
                siteResolverCapable: siteResolverCapable),
            // nil, not an explicit `.headless`, so the key is omitted
            // entirely and stays out of the sync digest for headless VMs
            // (issue #566).
            console: ConsoleSpec(graphics: vm.graphicsConsole ? .vnc : nil),
            sshAuthorizedKeys: vm.effectiveSSHAuthorizedKeys,
            userData: vm.userData,
            metadataSource: vm.metadataSource
        )
    }

    /// Builds volume specs from attached volumes, sorted by boot order (explicit
    /// orders first), then device name, then volume id.
    ///
    /// The comparison is a *total* order on all three keys (STR-129). Ordering
    /// on `bootOrder` alone left two volumes at the same priority — or two with
    /// none — incomparable, and the input arrives from an unordered
    /// `.with(\.$volumes)` through a `sort` that is not stable: two assemblies
    /// of the same unchanged VM could emit its disks in different orders, which
    /// is a spurious diff on the agent and potentially a different boot disk
    /// after a restart. The NIC path already avoids this by sorting on
    /// `(orderIndex, deviceName)`.
    static func volumeSpecs(
        from volumes: [Volume], storagePathsByVolumeID: [UUID: String] = [:]
    ) throws -> [VolumeSpec] {
        // Volumes with no explicit boot order sort after those that have one,
        // which `Int.max` expresses without a special case.
        func sortKey(_ volume: Volume) -> (Int, String, String) {
            (volume.bootOrder ?? Int.max, volume.deviceName ?? "", volume.id?.uuidString ?? "")
        }
        let sortedVolumes = volumes.sorted { sortKey($0) < sortKey($1) }

        var specs: [VolumeSpec] = []
        // Filtered on the *desired* attachment, not the observed status
        // (STR-148). This list and `DesiredVolumeState.attachment` are two
        // projections of one fact, and reading them off different columns is
        // what used to let them disagree — a volume the VM's spec called
        // attached while the volume lane called it detached, or the reverse.
        // The volume lane is authoritative for realizing an attachment; this
        // list is the boot-time convenience that rebuilds the same disk set.
        for volume in sortedVolumes where volume.$vm.id != nil && volume.desiredStatus == .present {
            guard let volumeID = volume.id else {
                throw Abort(.internalServerError, reason: "Attached volume is missing its managed identity")
            }
            // An attached row without a legal device name cannot exist: the API
            // validates one on the way in, and the schema has a
            // `vm_id IS NULL OR device_name IS NOT NULL` check plus the
            // `(vm_id, device_name)` unique index. Skipped rather than given a
            // synthesized `disk<n>` if one somehow does — that fallback could
            // collide with an explicit name on the same VM, and a duplicate id
            // is what stops the VM booting at all.
            guard let rawDeviceName = volume.deviceName,
                let deviceName = VolumeDeviceName(rawDeviceName)
            else {
                throw Abort(
                    .internalServerError,
                    reason: "Managed volume \(volumeID) has no valid attachment device name")
            }
            specs.append(
                VolumeSpec(
                    volumeId: volumeID,
                    deviceName: deviceName,
                    storagePath: storagePathsByVolumeID[volumeID],
                    readonly: volume.readonly,
                    bootOrder: volume.bootOrder,
                    // Read off the same column `DesiredVolumeState.ioLimits`
                    // is, so a VM realized from its spec boots with the caps
                    // the volume lane would apply (STR-19).
                    ioLimits: volume.ioLimits
                ))
        }
        return specs
    }

    /// Builds ImageInfo for the agent to download and cache the image.
    ///
    /// Download URLs are control-plane-relative paths (issue #493): the agent
    /// resolves them against the base URL it already dials — the Envoy mTLS
    /// listener — and authenticates the fetch with its SPIFFE SVID. No
    /// signature, no expiry, and no dependency on a control-plane-side notion
    /// of its own externally reachable URL.
    static func buildImageInfo(from image: Image) throws -> ImageInfo {
        guard let imageId = image.id else {
            throw Abort(.internalServerError, reason: "Image ID is required")
        }

        guard image.status == .ready else {
            throw Abort(.badRequest, reason: "Image is not ready for use")
        }

        let projectId = image.$project.id
        let downloadPath = "/api/projects/\(projectId)/images/\(imageId)/download"

        // One download descriptor per typed artifact. Exclude any artifact
        // that isn't fully materialized — a pending/downloading URL fetch has no
        // real checksum or bytes yet and must never reach an agent.
        let artifacts = (image.$artifacts.value ?? []).filter(\.isUsable).map { artifact in
            ArtifactInfo(
                kind: artifact.kind,
                filename: artifact.filename,
                checksum: artifact.checksum,
                size: artifact.size,
                downloadURL: "\(downloadPath)?artifact=\(artifact.kind.rawValue)"
            )
        }

        guard !artifacts.isEmpty else {
            throw Abort(
                .internalServerError,
                reason: "Ready image \(imageId) has no ready typed artifacts")
        }
        return ImageInfo(
            imageId: imageId,
            projectId: projectId,
            architecture: image.architecture,
            artifacts: artifacts
        )
    }

    /// Builds the stricter image descriptor used to materialize a managed
    /// volume. Firecracker's kernel/rootfs pair can boot a VM directly but
    /// cannot seed the disk-image-only volume creation path.
    static func buildDiskImageInfo(from image: Image) throws -> ImageInfo {
        guard image.usableDiskArtifact != nil else {
            throw Abort(
                .badRequest,
                reason: "Image does not have a usable disk-image artifact")
        }
        return try buildImageInfo(from: image)
    }
}
