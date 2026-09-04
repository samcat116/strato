import Foundation
import Vapor
import StratoShared

/// Builds the hypervisor-neutral `VMSpec` sent to agents. The spec carries each
/// backend-owned disk attachment exactly as the agent reported it, but no
/// agent-derived networking, queue sizing, or machine configuration. Agents
/// translate those details into their driver-native configuration.
struct VMSpecBuilder {
    /// A persisted per-VM invariant that prevents this VM's wire spec from
    /// being assembled. The code is deliberately bounded for telemetry; the
    /// human-readable description may carry the row-specific detail instead.
    enum AssemblyError: Error, LocalizedError, Equatable, Sendable {
        case bootVolumeCount(Int)
        case nonCanonicalBootVolume
        case terminatingBootVolume
        case attachedVolumeMissingIdentity
        case invalidAttachmentDeviceName(volumeID: UUID)

        var code: String {
            switch self {
            case .bootVolumeCount: return "boot_volume_count"
            case .nonCanonicalBootVolume: return "non_canonical_boot_volume"
            case .terminatingBootVolume: return "terminating_boot_volume"
            case .attachedVolumeMissingIdentity: return "missing_volume_identity"
            case .invalidAttachmentDeviceName: return "invalid_volume_device_name"
            }
        }

        var errorDescription: String? {
            switch self {
            case .bootVolumeCount(let count):
                return "expected exactly one managed boot volume, found \(count)"
            case .nonCanonicalBootVolume:
                return "the managed boot volume is not the canonical writable disk0 at boot order 0"
            case .terminatingBootVolume:
                return "a live VM has a terminating boot volume"
            case .attachedVolumeMissingIdentity:
                return "an attached volume is missing its managed identity"
            case .invalidAttachmentDeviceName(let volumeID):
                return "managed volume \(volumeID) has no valid attachment device name"
            }
        }
    }

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
    static func networkSpecs(
        from interfaces: [VMNetworkInterface],
        networks: [UUID: LogicalNetwork] = [:],
        securityGroupsByInterface: [UUID: [UUID]] = [:],
        siteResolverCapable: Bool? = true,
        logger: Logger? = nil
    ) -> [NetworkSpec] {
        networkSpecs(
            fromResolved: resolvedInterfaces(from: interfaces, networks: networks, logger: logger),
            securityGroupsByInterface: securityGroupsByInterface,
            siteResolverCapable: siteResolverCapable)
    }

    /// The same, for a caller that resolved the NICs itself — the sync, which
    /// hands one resolution to both the spec and the VM's instance metadata so
    /// the two lists agree by construction and an under-fetched NIC is logged
    /// once rather than once per consumer.
    static func networkSpecs(
        fromResolved resolved: [(interface: VMNetworkInterface, network: LogicalNetwork)],
        securityGroupsByInterface: [UUID: [UUID]] = [:],
        siteResolverCapable: Bool? = true
    ) -> [NetworkSpec] {
        resolved.map { interface, network in
            NetworkSpec.build(
                interface: interface,
                network: network,
                securityGroupIds: interface.id.flatMap { id in securityGroupsByInterface[id] },
                siteResolverCapable: siteResolverCapable)
        }
    }

    /// Builds the canonical VM spec. Every live VM must carry exactly one
    /// managed boot volume; a missing or ambiguous boot disk is a persisted-
    /// data invariant violation, never a reason to reconstruct a path-only
    /// disk. A terminating VM needs no boot volume to describe its teardown:
    /// the VM row itself is the level-triggered instruction to remove it.
    /// - Parameters:
    ///   - vm: The VM to build the spec for (must have volumes eager-loaded with .with(\.$volumes))
    ///   - image: Image defaults used for CPU, memory, and direct-kernel boot metadata
    ///   - volumes: Attached volumes (sorted by boot order, then device name)
    ///   - networkInterfaces: The VM's network interfaces
    static func buildVMSpec(
        from vm: VM, image: Image?, volumes: [Volume], networkInterfaces: [VMNetworkInterface],
        diskAttachmentsByVolumeID: [UUID: DiskAttachment] = [:],
        networks: [UUID: LogicalNetwork] = [:],
        securityGroupsByInterface: [UUID: [UUID]] = [:],
        siteResolverCapable: Bool? = true,
        logger: Logger? = nil
    ) throws -> VMSpec {
        try buildVMSpec(
            from: vm, image: image, volumes: volumes,
            diskAttachmentsByVolumeID: diskAttachmentsByVolumeID,
            resolvedInterfaces: resolvedInterfaces(
                from: networkInterfaces, networks: networks, logger: logger),
            securityGroupsByInterface: securityGroupsByInterface,
            siteResolverCapable: siteResolverCapable)
    }

    /// The same, for a caller holding an already-resolved NIC list (see
    /// `networkSpecs(fromResolved:securityGroupsByInterface:)`).
    static func buildVMSpec(
        from vm: VM, image: Image?, volumes: [Volume],
        diskAttachmentsByVolumeID: [UUID: DiskAttachment] = [:],
        resolvedInterfaces: [(interface: VMNetworkInterface, network: LogicalNetwork)],
        securityGroupsByInterface: [UUID: [UUID]] = [:],
        siteResolverCapable: Bool? = true
    ) throws -> VMSpec {
        let cpuCount = vm.cpu > 0 ? vm.cpu : (image?.defaultCpu ?? 1)
        let memorySize = vm.memory > 0 ? vm.memory : (image?.defaultMemory ?? 1024 * 1024 * 1024)  // 1GB default

        let attachedVolumes = volumes.filter { $0.$vm.id != nil }
        let bootVolumes = attachedVolumes.filter { $0.volumeType == .boot }
        if vm.desiredStatus != .absent {
            guard bootVolumes.count == 1 else {
                throw AssemblyError.bootVolumeCount(bootVolumes.count)
            }
            let bootVolume = bootVolumes[0]
            guard bootVolume.deviceName == VolumeDeviceName.disk(0).rawValue,
                bootVolume.bootOrder == 0,
                !bootVolume.readonly
            else {
                throw AssemblyError.nonCanonicalBootVolume
            }
            guard bootVolume.desiredStatus == .present else {
                throw AssemblyError.terminatingBootVolume
            }
        }
        let desiredVolumes =
            vm.desiredStatus == .absent
            ? attachedVolumes : attachedVolumes.filter { $0.desiredStatus == .present }
        let volumeSpecs = try volumeSpecs(
            from: desiredVolumes, diskAttachmentsByVolumeID: diskAttachmentsByVolumeID)

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
        from volumes: [Volume], diskAttachmentsByVolumeID: [UUID: DiskAttachment] = [:]
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
                throw AssemblyError.attachedVolumeMissingIdentity
            }
            // An attached row without a legal device name cannot exist: the API
            // validates one on the way in, and the schema has a
            // `vm_id IS NULL OR device_name IS NOT NULL` check plus the
            // `(vm_id, device_name)` unique index. Failed rather than given a
            // synthesized `disk<n>` if one somehow does — that fallback could
            // collide with an explicit name on the same VM, and a duplicate id
            // is what stops the VM booting at all. The desired-state assembler
            // catches this per VM and omits only that entry.
            guard let rawDeviceName = volume.deviceName,
                let deviceName = VolumeDeviceName(rawDeviceName)
            else {
                throw AssemblyError.invalidAttachmentDeviceName(volumeID: volumeID)
            }
            specs.append(
                VolumeSpec(
                    volumeId: volumeID,
                    deviceName: deviceName,
                    attachment: diskAttachmentsByVolumeID[volumeID],
                    readonly: volume.readonly,
                    bootOrder: volume.bootOrder,
                    // Read off the same column `DesiredVolumeState.ioLimits`
                    // is, so a VM realized from its spec boots with the caps
                    // the volume lane would apply (STR-19).
                    ioLimits: volume.ioLimits,
                    blockMode: volume.blockMode
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

}
