import Foundation
import Logging
import StratoAgentCore
import StratoShared

#if os(Linux)
import Glibc
import SwiftFirecracker

/// Owns sandbox provisioning, boot, shutdown, deletion, adoption, and status.
extension FirecrackerSandboxRuntime {
    // MARK: - SandboxRuntimeService

    func createSandbox(
        sandboxId: String,
        spec: SandboxSpec,
        registryCredential: RegistryCredential?,
        networkAttachments: [ResolvedNetworkAttachment]
    ) async throws {
        // Idempotent: a replayed create for an already-defined sandbox is a
        // no-op (the Firecracker process is already configured).
        if sandboxes[sandboxId] != nil {
            return
        }

        guard !requiresJailUID || jailUIDs.uid(for: sandboxId) != nil else {
            throw SandboxRuntimeError.jailIdentityUnavailable(
                "sandbox \(sandboxId) has no exclusive allocation; persist a fresh jailUID before creating it")
        }

        // The jailer is required but unusable: creating this sandbox would
        // mean running an untrusted workload unjailed, which `required`
        // forbids. (Normally unreachable — the capability is dark — but a
        // stray desired entry must fail here, not fall through.)
        if let jailerBlockedReason {
            throw SandboxRuntimeError.jailerRequiredUnavailable(jailerBlockedReason)
        }

        logger.info(
            "Creating sandbox",
            metadata: ["strato.sandbox.id": .string(sandboxId), "image": .string(spec.image)])

        // User checkpoint fork (issue #427): unlike a warm template this
        // snapshot already contains a running workload, so restore, rotate its
        // identity, and report it healthy as one create operation. No registry
        // pull or cold/warm image provisioning belongs on this path.
        if let restoreFrom = spec.restoreFrom {
            try await provisionFromSandboxSnapshot(
                sandboxId: sandboxId, spec: spec, restoreFrom: restoreFrom,
                networkAttachments: networkAttachments)
            return
        }

        let guestImage = try SandboxGuestImage.resolve(atDirectory: guestImagePath)

        // Materialize the flattened container rootfs (cache-owned, read-only),
        // then copy it to a per-sandbox writable image — container semantics
        // give the workload a writable root, and the cache entry must never be
        // written. (An overlay would avoid the copy; that is future work.)
        let materialized = try await imageService.materializeRootfs(
            image: spec.image, imageDigest: spec.imageDigest, credential: registryCredential)

        // Stage the config drive the guest init reads at boot. Every config
        // drive is padded to one standard capacity so a warm restore (below)
        // can stage a different sandbox's document at the exact device size
        // the template snapshot recorded.
        let nonce = UUID().uuidString
        let configDrive = SandboxConfigDrive(
            sandboxId: sandboxId, identityNonce: nonce,
            guestConfig: materialized.guestConfig, spec: spec,
            network: try guestNetwork(attachments: networkAttachments))
        let configData = try configDrive.blockImage(
            minimumBytes: SandboxConfigDrive.standardBlockImageBytes)

        // Warm start (issue #426): when a template snapshot for this exact
        // (image, guest, machine shape, NIC shape) exists, provision by
        // restoring it — the microVM comes up already booted to the held
        // point, and `bootSandbox` launches the real workload into it. Any
        // failure here falls back to the cold path; a config document too
        // large for the standard capacity is cold-only (the device size would
        // not match the template's).
        //
        // A networked sandbox additionally needs a Firecracker that can point
        // the template's network device at *this* sandbox's TAP as it loads
        // (STR-104). On an older VMM the honest answer is a cold boot, which
        // costs the latency saving and nothing else.
        let warmNetworkRemapOK: Bool
        if networkAttachments.isEmpty {
            warmNetworkRemapOK = true
        } else {
            // A host that could not be asked reads the same as one that
            // cannot: warm start only ever trades latency, so an unknown is a
            // cold boot rather than something to fail or retry over.
            warmNetworkRemapOK = await probeNetworkOverridesSupport() == true
        }
        let warmEligible =
            warmStartActive && warmNetworkRemapOK
            && configData.count == SandboxConfigDrive.standardBlockImageBytes
        if warmStartActive, !warmNetworkRemapOK {
            logger.debug(
                "Firecracker predates snapshot network remapping, so this networked sandbox is cold-provisioned",
                metadata: [
                    "strato.sandbox.id": .string(sandboxId),
                    "minimumFirecracker": .string(
                        FirecrackerSnapshotFeatures.networkOverridesMinimumVersion),
                ])
        }
        let warmKey = warmSnapshotKey(
            imageDigest: materialized.manifestDigest, guestImage: guestImage, spec: spec,
            nicCount: networkAttachments.count)
        var warmMissed = true
        if warmEligible, let warmEntry = warmCache.lookup(warmKey) {
            warmMissed = false
            do {
                // The meta sidecar carries the template identity the held
                // guest must echo at boot; an entry without one is unusable.
                guard let meta = warmCache.loadMeta(warmKey) else {
                    throw SandboxRuntimeError.warmStartFailed(
                        "cache entry has no readable meta sidecar")
                }
                let vm = try await provisionFromWarmSnapshot(
                    sandboxId: sandboxId, spec: spec, entry: warmEntry, configData: configData,
                    networkAttachments: networkAttachments)
                sandboxes[sandboxId] = Managed(
                    spec: spec, rootfsPath: vm.rootfsPath, configPath: vm.configPath,
                    vsockUdsPath: vm.vsockUdsPath, identityNonce: nonce, jail: vm.jail,
                    registryCredential: registryCredential,
                    networkAttachments: networkAttachments,
                    warmHeldIdentity: (meta.templateId, meta.templateNonce),
                    manager: vm.manager, lastExitCode: nil)
                logger.info(
                    "Sandbox created from warm snapshot",
                    metadata: [
                        "strato.sandbox.id": .string(sandboxId),
                        "warmKey": .string(warmKey.directoryName),
                    ])
                return
            } catch {
                // A stale or corrupt entry (e.g. the Firecracker binary
                // changed under an unchanged mtime) must not wedge creates:
                // drop it and cold-boot.
                logger.warning(
                    "Warm-start provisioning failed; invalidating the cache entry and cold-booting",
                    metadata: [
                        "strato.sandbox.id": .string(sandboxId),
                        "warmKey": .string(warmKey.directoryName),
                        "error": .string(error.localizedDescription),
                    ])
                warmCache.invalidate(warmKey)
                warmMissed = true
            }
        }

        try await coldProvisionAndRegister(
            sandboxId: sandboxId, spec: spec, credential: registryCredential,
            materialized: materialized, guestImage: guestImage, nonce: nonce, configData: configData,
            networkAttachments: networkAttachments)

        // This image had no usable warm template: build one in the background
        // so the next sandbox for the same (image, machine shape) warm-starts.
        if warmEligible, warmMissed {
            maybeStartWarmTemplateBuild(
                key: warmKey, materialized: materialized, guestImage: guestImage, spec: spec)
        }
    }

    /// Whether this host's Firecracker accepts `network_overrides` on a
    /// snapshot load — the single thing that makes a checkpoint's network
    /// device reusable under a different host TAP (STR-104).
    ///
    /// **Nil means "could not tell", not "no".** The three answers are
    /// genuinely different to callers: `true` remaps, `false` is a permanent
    /// property of the host, and nil is a probe that failed for reasons a
    /// retry can clear.
    func probeNetworkOverridesSupport() async -> Bool? {
        if let networkOverridesSupport { return networkOverridesSupport }
        guard let version = await HypervisorProbe.firecrackerVersion(binaryPath: firecrackerBinaryPath)
        else {
            // Deliberately not memoized — see the property.
            logger.warning(
                "Could not read the Firecracker version, so whether a restored network device can be remapped is unknown",
                metadata: ["firecrackerBinaryPath": .string(firecrackerBinaryPath)])
            return nil
        }
        let supported = FirecrackerSnapshotFeatures.supportsNetworkOverrides(version)
        networkOverridesSupport = supported
        if !supported {
            logger.info(
                "Firecracker cannot remap a restored network device; networked sandboxes cold-boot and cannot be forked",
                metadata: [
                    "firecrackerVersion": .string(version),
                    "minimumVersion": .string(
                        FirecrackerSnapshotFeatures.networkOverridesMinimumVersion),
                ])
        }
        return supported
    }

    /// The host TAP backing this sandbox's NIC, or nil when it has none.
    ///
    /// Throws for a NIC realized as anything else, for the same reason the cold
    /// path does: Firecracker's only network backend is a TAP opened by name —
    /// no fd passing, no vhost-user — so an agent in `network_mode = "user"`
    /// (or with no network service at all) resolves every NIC to `.userMode`
    /// and can realize nothing. Silently skipping it would produce a sandbox
    /// with no interface that the control plane records as having one.
    func sandboxTAPName(_ attachments: [ResolvedNetworkAttachment]) throws -> String? {
        // A spec is capped at one NIC, so the first attachment is the whole set.
        guard let nic = attachments.first else { return nil }
        guard case .tap(let tapName) = nic.attachment else {
            throw SandboxRuntimeError.networkingUnsupported(
                "this agent realized the sandbox's NIC as \(nic.attachment), but a jailed "
                    + "Firecracker can only open a TAP by name inside its namespace; "
                    + "sandbox networking needs network_mode = \"ovn\" with a working OVN/OVS")
        }
        return tapName
    }

    /// The `network_overrides` entry pointing a restored NIC at `tapName`,
    /// where the remap is *optional*: nil when there is no NIC, and nil rather
    /// than an error when this host cannot (or could not be asked to) remap.
    ///
    /// Only restore **in place** may use this. It does not need the remap at
    /// all — the TAP name derives from the sandbox id, which a restore in
    /// place does not change, so the checkpoint already names the right device
    /// — and a Firecracker that predates the field rejects the whole load body
    /// over it, so the key has to be absent rather than present-and-ignored.
    func optionalNetworkOverrides(
        forTAP tapName: String?
    ) async -> [SnapshotLoadConfig.NetworkOverride]? {
        guard let tapName, await probeNetworkOverridesSupport() == true else { return nil }
        return [
            SnapshotLoadConfig.NetworkOverride(
                ifaceId: Self.networkInterfaceId, hostDevName: tapName)
        ]
    }

    /// The `network_overrides` entry for a load that cannot work without one —
    /// a fork, or a warm restore — or nil when there is no NIC to remap.
    ///
    /// Separates the two ways this can be unavailable, because they call for
    /// opposite handling. A Firecracker too old is a property of the host, so
    /// it is permanent and the caller's convergence stops. A probe that could
    /// not answer is transient: the version is unread, not old, and retrying
    /// is what distinguishes them.
    func requiredNetworkOverrides(
        forTAP tapName: String?, operation: String
    ) async throws -> [SnapshotLoadConfig.NetworkOverride]? {
        guard let tapName else { return nil }
        switch await probeNetworkOverridesSupport() {
        case true:
            return [
                SnapshotLoadConfig.NetworkOverride(
                    ifaceId: Self.networkInterfaceId, hostDevName: tapName)
            ]
        case false:
            throw SandboxRuntimeError.networkingUnsupported(
                "\(operation) needs Firecracker "
                    + "\(FirecrackerSnapshotFeatures.networkOverridesMinimumVersion) or newer to point the "
                    + "checkpointed network device at this sandbox's TAP")
        case nil:
            throw SandboxRuntimeError.hostCapabilityUnknown(
                "could not read the Firecracker version, so \(operation) cannot be shown to be safe yet")
        }
    }

    /// The config-drive network block for a sandbox's realized NIC, or nil
    /// when it has none (STR-101).
    ///
    /// The guest configures its interface statically from this — it runs no
    /// DHCP client — so a networked sandbox whose block is missing or
    /// incomplete boots with a dead interface. Everything that could make it
    /// incomplete throws instead.
    func guestNetwork(
        attachments: [ResolvedNetworkAttachment]
    ) throws -> SandboxConfigDrive.NetworkConfig? {
        // A spec is capped at one NIC, so the first attachment is the whole set.
        guard let nic = attachments.first else { return nil }
        return try SandboxConfigDrive.network(for: nic)
    }

    /// Provision a cold microVM and register it as this sandbox. Shared by
    /// the ordinary cold create path and the warm-launch demotion fallback,
    /// so the two can never drift apart.
    func coldProvisionAndRegister(
        sandboxId: String,
        spec: SandboxSpec,
        credential: RegistryCredential?,
        materialized: MaterializedRootfs,
        guestImage: SandboxGuestImage,
        nonce: String,
        configData: Data,
        networkAttachments: [ResolvedNetworkAttachment]
    ) async throws {
        let vm = try await provisionColdMicroVM(
            vmId: sandboxId, spec: spec, rootfsSourcePath: materialized.rootfsPath,
            configData: configData, guestImage: guestImage, networkAttachments: networkAttachments)
        sandboxes[sandboxId] = Managed(
            spec: spec, rootfsPath: vm.rootfsPath, configPath: vm.configPath,
            unverifiedRootfsCacheDigest: materialized.manifestDigest,
            vsockUdsPath: vm.vsockUdsPath, identityNonce: nonce, jail: vm.jail,
            registryCredential: credential, networkAttachments: networkAttachments,
            manager: vm.manager, lastExitCode: nil)
        logger.info(
            "Sandbox created",
            metadata: [
                "strato.sandbox.id": .string(sandboxId),
                "jailed": .stringConvertible(vm.jail != nil),
            ])
    }

    /// The staged artifacts and live Firecracker session `provision*` hands
    /// back for registration (or, for a warm template, direct use).
    struct ProvisionedMicroVM {
        let rootfsPath: String
        let configPath: String
        let vsockUdsPath: String
        let jail: SandboxJailPlan?
        let manager: FirecrackerManager
    }

    /// Build a jail plan only from an exclusive allocator assignment. This is
    /// the structural seam that keeps path construction from smuggling the old
    /// hash-derived identity back into create/adopt/restore call sites.
    func jailPlan(for sandboxId: String) throws -> SandboxJailPlan {
        guard let uid = jailUIDs.uid(for: sandboxId) else {
            throw SandboxRuntimeError.jailIdentityUnavailable(
                "sandbox \(sandboxId) has no exclusive manifest-backed uid/gid assignment")
        }
        return try SandboxJailPlan(
            sandboxId: sandboxId, jailUID: uid, config: jailerConfig,
            firecrackerBinaryPath: firecrackerBinaryPath)
    }

    /// Cleanup/adoption of a legacy warm-template leak has an identity from
    /// its durable sidecar (or the pre-allocation hash fallback), but no
    /// manifest workload entry. Keep that exceptional input explicit.
    func jailPlan(for sandboxId: String, recordedUID: UInt32) throws -> SandboxJailPlan {
        try SandboxJailPlan(
            sandboxId: sandboxId, jailUID: recordedUID, config: jailerConfig,
            firecrackerBinaryPath: firecrackerBinaryPath)
    }

    /// Stage a microVM's artifacts and spawn + fully configure its
    /// Firecracker process, leaving it in `Not started`. The cold-boot
    /// staging path, shared between sandbox creation and warm-template
    /// builds; cleans up after itself on failure.
    func provisionColdMicroVM(
        vmId: String,
        spec: SandboxSpec,
        rootfsSourcePath: String,
        configData: Data,
        guestImage: SandboxGuestImage,
        networkAttachments: [ResolvedNetworkAttachment]
    ) async throws -> ProvisionedMicroVM {
        // Stage the per-VM artifacts. Jailed (issue #425), everything the
        // microVM touches lives inside its chroot and the Firecracker API is
        // given in-jail paths; unjailed, the historical flat layout is kept.
        // `rootfsPath`/`configPath`/`vsockUdsPath` are always the *host* views.
        let jailPlan: SandboxJailPlan?
        let rootfsPath: String
        let configPath: String
        let vsockUdsPath: String
        let apiPaths: (rootfs: String, config: String, kernel: String, initrd: String, vsock: String)
        var jailOptions: JailerOptions?

        if jailNewSandboxes {
            let plan = try self.jailPlan(for: vmId)
            jailPlan = plan
            // This id is being created fresh, so anything already under its
            // jail is a stale leftover from a crashed previous life.
            try? FileManager.default.removeItem(atPath: plan.jailDirectory)
            // `run/` holds the API socket and vsock UDS the jailed process
            // creates at runtime, so it must exist and be writable by its uid.
            try FileManager.default.createDirectory(
                atPath: plan.jailRoot + "/run", withIntermediateDirectories: true)

            rootfsPath = plan.hostPath(forInJail: SandboxJailPlan.rootfsPathInJail)
            try await reflinkCopy(from: rootfsSourcePath, to: rootfsPath)
            configPath = plan.hostPath(forInJail: SandboxJailPlan.configPathInJail)
            try configData.write(to: URL(fileURLWithPath: configPath))
            // Kernel/initramfs are shared read-only artifacts: hard-link when
            // the chroot shares their filesystem, copy otherwise. They stay
            // root-owned (world-readable suffices, and chowning a hard link
            // would chown the installed guest image itself).
            try linkOrCopy(
                from: guestImage.kernelPath,
                to: plan.hostPath(forInJail: SandboxJailPlan.kernelPathInJail))
            try linkOrCopy(
                from: guestImage.initramfsPath,
                to: plan.hostPath(forInJail: SandboxJailPlan.initramfsPathInJail))
            // The jailed process runs as the per-sandbox uid: it writes the
            // rootfs and creates sockets under run/.
            for path in [plan.jailRoot, plan.jailRoot + "/run", rootfsPath, configPath] {
                try chownPath(path, uid: plan.uid, gid: plan.gid)
            }

            // A dedicated network namespace: even a compromised VMM sees no
            // host interfaces. When the sandbox has a NIC the network
            // orchestrator has already created this namespace and wired a veth
            // + TAP into it (issue STR-100) — it runs first, on the reconcile
            // lane, before the runtime is called. This call is what covers the
            // network-free case, and reusing an existing namespace is exactly
            // what makes the two orders equivalent.
            try await createNetns(plan.netnsName)

            vsockUdsPath = plan.vsockUDSHostPath
            apiPaths = (
                rootfs: SandboxJailPlan.rootfsPathInJail,
                config: SandboxJailPlan.configPathInJail,
                kernel: SandboxJailPlan.kernelPathInJail,
                initrd: SandboxJailPlan.initramfsPathInJail,
                vsock: SandboxJailPlan.vsockUDSPathInJail
            )

            jailOptions = makeJailerOptions(plan: plan, guestMemoryBytes: spec.memoryBytes)
        } else {
            jailPlan = nil
            let dir = sandboxDirectory(vmId)
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

            rootfsPath = dir + "/rootfs.ext4"
            // Unlink any previous incarnation's rootfs first: `cp --force`
            // would truncate the existing inode in place, letting a stale
            // process that still holds it open scribble on the new copy.
            if FileManager.default.fileExists(atPath: rootfsPath) {
                try FileManager.default.removeItem(atPath: rootfsPath)
            }
            try await reflinkCopy(from: rootfsSourcePath, to: rootfsPath)
            configPath = dir + "/config.img"
            try configData.write(to: URL(fileURLWithPath: configPath))
            vsockUdsPath = vsockUDSPath(vmId)
            apiPaths = (
                rootfs: rootfsPath, config: configPath,
                kernel: guestImage.kernelPath, initrd: guestImage.initramfsPath,
                vsock: vsockUdsPath
            )
        }

        // Spawn and fully configure the Firecracker microVM, leaving it in
        // `Not started` (== stopped). Roll the process back on any configuration
        // failure so a retry starts from a clean slate rather than
        // `vmAlreadyRunning`.
        let manager: FirecrackerManager
        do {
            manager = try await client.createVM(vmId: vmId, jail: jailOptions)
        } catch {
            if let plan = jailPlan {
                await removeJailArtifacts(plan)
            }
            throw error
        }
        do {
            // The CPU template (issue #428) is applied at boot and thereby
            // baked into every checkpoint taken from this guest — it is what
            // makes those snapshots portable across same-arch hosts.
            try await manager.configureMachine(
                MachineConfig(
                    vcpuCount: spec.cpus,
                    memSizeMib: Int(spec.memoryBytes / (1024 * 1024)),
                    cpuTemplate: spec.cpuTemplate))

            let bootSource = SwiftFirecracker.BootSource(
                kernelImagePath: apiPaths.kernel,
                initrdPath: apiPaths.initrd,
                bootArgs: guestImage.bootArgs + " strato.config=/dev/vdb")
            try await manager.configureBootSource(bootSource)

            // Drive order fixes device naming: rootfs first ⇒ /dev/vda (what the
            // config drive names), config second ⇒ /dev/vdb (what the guest
            // reads by default).
            try await manager.configureDrive(
                Drive.rootDrive(id: "rootfs", path: apiPaths.rootfs, readOnly: false))
            try await manager.configureDrive(
                Drive.dataDrive(id: "config", path: apiPaths.config, readOnly: true))

            // Firecracker's VMGenID already rotates on every snapshot load on
            // supported kernels; virtio-rng supplies continuing host entropy as
            // defense in depth. Older Firecracker binaries may reject the
            // optional device, so explicit guest-side reseeding remains the
            // load-bearing fork boundary.
            do {
                try await manager.configureEntropy()
            } catch {
                logger.warning(
                    "Firecracker did not accept the optional entropy device",
                    metadata: [
                        "strato.sandbox.id": .string(vmId),
                        "error": .string(error.localizedDescription),
                    ])
            }

            // The sandbox's NIC, when it has one. The device is a TAP the
            // orchestrator created inside this sandbox's network namespace and
            // chowned to the jail's uid; Firecracker opens it by name from
            // inside the jail, which the jailer has already entered via
            // `--netns` (issue STR-100). `sandboxTAPName` is what refuses a
            // NIC realized as anything else.
            if let tapName = try sandboxTAPName(networkAttachments) {
                try await manager.configureNetwork(
                    NetworkInterface.tap(
                        id: Self.networkInterfaceId, tapName: tapName,
                        macAddress: networkAttachments[0].macAddress))
            }

            try await manager.configureVsock(
                VsockConfig(guestCid: Self.guestCID, udsPath: apiPaths.vsock))
        } catch {
            try? await client.destroyVM(vmId: vmId)
            if let plan = jailPlan {
                await removeJailArtifacts(plan)
            }
            throw error
        }

        return ProvisionedMicroVM(
            rootfsPath: rootfsPath, configPath: configPath, vsockUdsPath: vsockUdsPath,
            jail: jailPlan, manager: manager)
    }

    /// Provision a new sandbox by restoring the warm template snapshot (issue
    /// #426): stage the jail with clones of the template's rootfs +
    /// memory/vmstate and this sandbox's *own* config drive, then spawn +
    /// load without resuming — the microVM lands in `Paused`, which
    /// `bootSandbox` resumes and launches. Jailed-only by construction (see
    /// `warmStartActive`): the snapshot's chroot-relative paths are what let
    /// it load under a different sandbox's jail at all. Cleans up after
    /// itself on failure so the caller can fall back to a cold provision.
    func provisionFromWarmSnapshot(
        sandboxId: String,
        spec: SandboxSpec,
        entry: WarmSnapshotEntry,
        configData: Data,
        networkAttachments: [ResolvedNetworkAttachment]
    ) async throws -> ProvisionedMicroVM {
        guard jailNewSandboxes else {
            throw SandboxRuntimeError.warmStartFailed(
                "warm restore requires the jailer (snapshots record chroot-relative paths)")
        }
        // The template's NIC is a throwaway TAP in the template's own
        // namespace, long gone by now; the shape key guarantees the device
        // exists, and this is what points it at this sandbox's real TAP
        // (STR-104). Warm eligibility already established the remap, so a
        // throw here is a contradiction rather than a routine refusal — and
        // every warm failure falls back to a cold boot either way.
        let tapName = try sandboxTAPName(networkAttachments)
        let overrides = try await requiredNetworkOverrides(
            forTAP: tapName, operation: "warm-starting a networked sandbox")
        let plan = try jailPlan(for: sandboxId)
        do {
            try? FileManager.default.removeItem(atPath: plan.jailDirectory)
            try FileManager.default.createDirectory(
                atPath: plan.jailRoot + "/run", withIntermediateDirectories: true)
            // Kernel/initramfs are deliberately absent: a snapshot load
            // restores guest memory directly and never reads the boot
            // source (the restore-in-place path established this layout).
            let rootfsHost = plan.hostPath(forInJail: SandboxJailPlan.rootfsPathInJail)
            try await reflinkCopy(from: entry.rootfsPath, to: rootfsHost)
            let configHost = plan.hostPath(forInJail: SandboxJailPlan.configPathInJail)
            try configData.write(to: URL(fileURLWithPath: configHost))
            let snapshotDirHost = plan.hostPath(forInJail: SandboxJailPlan.snapshotDirInJail)
            try FileManager.default.createDirectory(
                atPath: snapshotDirHost, withIntermediateDirectories: true)
            // Copied (reflink where the filesystem supports it), not
            // hard-linked: the chown below would chown a link's shared inode
            // — the cache entry itself — and hard-linking would also bet on
            // Firecracker never opening the memory backend for write.
            // Sparse-aware copies keep the cost proportional to the
            // template's touched pages; revisit as an optimization once
            // load semantics are pinned down on a KVM host.
            try await reflinkCopy(
                from: entry.memoryPath,
                to: plan.hostPath(forInJail: SandboxJailPlan.snapshotMemoryPathInJail))
            try await reflinkCopy(
                from: entry.vmstatePath,
                to: plan.hostPath(forInJail: SandboxJailPlan.snapshotVmstatePathInJail))
            for path in [
                plan.jailRoot, plan.jailRoot + "/run", rootfsHost, configHost, snapshotDirHost,
                plan.hostPath(forInJail: SandboxJailPlan.snapshotMemoryPathInJail),
                plan.hostPath(forInJail: SandboxJailPlan.snapshotVmstatePathInJail),
            ] {
                try chownPath(path, uid: plan.uid, gid: plan.gid)
            }
            try await createNetns(plan.netnsName)

            let manager = try await client.restoreVM(
                vmId: sandboxId, jail: makeJailerOptions(plan: plan, guestMemoryBytes: spec.memoryBytes),
                snapshot: SnapshotLoadConfig(
                    snapshotPath: SandboxJailPlan.snapshotVmstatePathInJail,
                    memFilePath: SandboxJailPlan.snapshotMemoryPathInJail,
                    resumeVM: false,
                    networkOverrides: overrides))
            return ProvisionedMicroVM(
                rootfsPath: rootfsHost, configPath: configHost,
                vsockUdsPath: plan.vsockUDSHostPath, jail: plan, manager: manager)
        } catch {
            try? await client.destroyVM(vmId: sandboxId)
            // The caller falls back to a cold provision under this same id and
            // NIC, so the namespace and its devices have to survive.
            await removeJailArtifacts(plan, removingNetns: false)
            throw error
        }
    }

    /// Restore a user checkpoint into a new jailed sandbox and establish a
    /// hard identity boundary before exposing it as running (issue #427).
    /// Firecracker vmstate stores drive/vsock paths; distinct jail roots make
    /// its chroot-relative paths reusable without colliding with the source.
    func provisionFromSandboxSnapshot(
        sandboxId: String,
        spec: SandboxSpec,
        restoreFrom: SandboxSnapshotRef,
        networkAttachments: [ResolvedNetworkAttachment]
    ) async throws {
        guard jailNewSandboxes else {
            throw SandboxRuntimeError.warmStartFailed(
                "sandbox forks require the jailer because snapshot devices record their backing paths")
        }

        // The fork's own TAP, which the load repoints the checkpointed device
        // at (STR-104). Firecracker will not add a device on load, so a NIC
        // this host cannot remap is a permanent refusal here rather than a
        // sandbox published with an interface that opens the *source's* TAP.
        let targetNetwork = try guestNetwork(attachments: networkAttachments)
        let tapName = try sandboxTAPName(networkAttachments)
        let overrides = try await requiredNetworkOverrides(
            forTAP: tapName, operation: "forking a networked sandbox")

        let sourceSandboxId = restoreFrom.sourceSandboxId.uuidString
        let snapshotId = restoreFrom.snapshotId.uuidString
        // Local artifacts when the source sandbox lives here; otherwise the
        // exported copy is staged into the import cache from the signed
        // download descriptors the sync carried (issue #428).
        let archiveDir = try await stageSnapshotArchive(
            sourceSandboxId: sourceSandboxId, snapshotId: snapshotId,
            artifacts: restoreFrom.artifacts)
        let archiveMemory = archiveDir + "/" + SnapshotFile.memory
        let archiveVmstate = archiveDir + "/" + SnapshotFile.vmstate
        let archiveRootfs = archiveDir + "/" + SnapshotFile.rootfs
        let archiveConfig = archiveDir + "/" + SnapshotFile.configImage

        let sourceConfig = try SandboxConfigDrive.decode(
            fromBlockImage: Data(contentsOf: URL(fileURLWithPath: archiveConfig)))
        guard sourceConfig.sandboxId == sourceSandboxId else {
            throw GuestControlError.identityMismatch(
                expected: sourceSandboxId, got: sourceConfig.sandboxId)
        }

        // The checkpoint's device topology has to match the fork's, because a
        // load can remap devices but never add or drop them. The archived
        // config drive is the exact witness: the runtime writes its `network`
        // block precisely when it configures a Firecracker NIC, so the two
        // cannot disagree. Both directions are a refusal — a networked fork of
        // a network-free checkpoint has no device to address, and a
        // network-free fork of a networked one would restore a device pointing
        // at a TAP that no longer exists.
        guard (sourceConfig.network != nil) == (targetNetwork != nil) else {
            throw SandboxRuntimeError.networkingUnsupported(
                sourceConfig.network == nil
                    ? "the snapshot was captured without a network device, so the fork cannot have a NIC"
                    : "the snapshot was captured with a network device, so the fork must have a NIC")
        }

        let plan = try jailPlan(for: sandboxId)
        do {
            try? FileManager.default.removeItem(atPath: plan.jailDirectory)
            try FileManager.default.createDirectory(
                atPath: plan.jailRoot + "/run", withIntermediateDirectories: true)
            let rootfsHost = plan.hostPath(forInJail: SandboxJailPlan.rootfsPathInJail)
            let configHost = plan.hostPath(forInJail: SandboxJailPlan.configPathInJail)
            let snapshotDirHost = plan.hostPath(forInJail: SandboxJailPlan.snapshotDirInJail)
            try await reflinkCopy(from: archiveRootfs, to: rootfsHost)
            try await reflinkCopy(from: archiveConfig, to: configHost)
            try FileManager.default.createDirectory(
                atPath: snapshotDirHost, withIntermediateDirectories: true)
            try await reflinkCopy(
                from: archiveMemory,
                to: plan.hostPath(forInJail: SandboxJailPlan.snapshotMemoryPathInJail))
            try await reflinkCopy(
                from: archiveVmstate,
                to: plan.hostPath(forInJail: SandboxJailPlan.snapshotVmstatePathInJail))
            for path in [
                plan.jailRoot, plan.jailRoot + "/run", rootfsHost, configHost, snapshotDirHost,
                plan.hostPath(forInJail: SandboxJailPlan.snapshotMemoryPathInJail),
                plan.hostPath(forInJail: SandboxJailPlan.snapshotVmstatePathInJail),
            ] {
                try chownPath(path, uid: plan.uid, gid: plan.gid)
            }
            try await createNetns(plan.netnsName)

            // Loaded resumed, which opens a window: `reidentify` cannot be sent
            // until the restored guest's vsock listener is back, so for those
            // few hundred milliseconds the guest is running with the *source*
            // sandbox's MAC and IP and transmitting onto the fork's own OVS
            // port. What closes it is OVN `port_security` on that port, which
            // the agent sets unconditionally from the fork's own allocation
            // (`NetworkServiceLinux.createVMNetwork`): frames whose source
            // MAC/IP are not the fork's are dropped at the switch, so a
            // gratuitous ARP for a live source's address never reaches the L2
            // domain. It is the only thing standing there, so it is worth
            // naming — `NetworkConfiguration.portSecurity` exists on the wire
            // and is never consulted, and this is one of the places that would
            // quietly depend on it if it ever became real.
            let manager = try await client.restoreVM(
                vmId: sandboxId,
                jail: makeJailerOptions(plan: plan, guestMemoryBytes: spec.memoryBytes),
                snapshot: SnapshotLoadConfig(
                    snapshotPath: SandboxJailPlan.snapshotVmstatePathInJail,
                    memFilePath: SandboxJailPlan.snapshotMemoryPathInJail,
                    resumeVM: true,
                    networkOverrides: overrides))

            let sourceResponse = try await sendControl(
                .ping, udsPath: plan.vsockUDSHostPath, timeout: 20)
            guard
                identityMatches(
                    sourceResponse,
                    sandboxId: sourceConfig.sandboxId,
                    expectedNonce: sourceConfig.identityNonce)
            else {
                throw GuestControlError.identityMismatch(
                    expected: "\(sourceConfig.sandboxId)/\(sourceConfig.identityNonce)",
                    got: "\(sourceResponse)")
            }
            let nonce = UUID().uuidString
            let entropy = Self.freshEntropy()
            let hostname = SandboxConfigDrive.guestHostname(sandboxId: sandboxId)
            let response = try await sendControl(
                .reidentify(
                    GuestControlProtocol.ReidentifyRequest(
                        expectedSandboxId: sourceConfig.sandboxId,
                        expectedNonce: sourceConfig.identityNonce,
                        sandboxId: sandboxId,
                        identityNonce: nonce,
                        hostname: hostname,
                        entropy: entropy,
                        unixNanos: Int64(Date().timeIntervalSince1970 * 1_000_000_000),
                        network: targetNetwork)),
                udsPath: plan.vsockUDSHostPath,
                timeout: 20)
            guard case .reidentified = response else {
                throw GuestControlError.malformedResponse(
                    "expected reidentified, got \(response)")
            }
            let health = try await sendControl(
                .ping, udsPath: plan.vsockUDSHostPath, timeout: 20)
            guard identityMatches(health, sandboxId: sandboxId, expectedNonce: nonce) else {
                throw GuestControlError.identityMismatch(
                    expected: "\(sandboxId)/\(nonce)", got: "\(health)")
            }

            // Persist the new identity for adoption and for snapshots taken
            // from this fork. Firecracker retains the already-open source
            // config inode; replacing the path is safe and intentionally only
            // affects future host reads/copies.
            let targetConfig = SandboxConfigDrive(
                sandboxId: sandboxId,
                identityNonce: nonce,
                imageConfig: sourceConfig.imageConfig,
                overrides: sourceConfig.overrides,
                // The same name `reidentify` just gave the live guest, so the
                // persisted drive and the running sandbox agree.
                hostname: hostname,
                // Likewise the NIC: this drive is what a later checkpoint of
                // the fork archives, and the "a network block means a network
                // device" invariant is what the shape check above reads.
                network: targetNetwork)
            let originalConfigBytes = max(Int(fileSize(archiveConfig)), 512)
            try targetConfig.blockImage(minimumBytes: originalConfigBytes)
                .write(to: URL(fileURLWithPath: configHost), options: .atomic)
            try chownPath(configHost, uid: plan.uid, gid: plan.gid)

            sandboxes[sandboxId] = Managed(
                spec: spec, rootfsPath: rootfsHost, configPath: configHost,
                vsockUdsPath: plan.vsockUDSHostPath, identityNonce: nonce,
                guestControlProtocolVersion: health.controlProtocolVersion,
                jail: plan, networkAttachments: networkAttachments,
                manager: manager, lastExitCode: nil)
            startLogFollow(sandboxId: sandboxId)
            logger.info(
                "Sandbox fork restored and re-identified",
                metadata: [
                    "strato.sandbox.id": .string(sandboxId),
                    "strato.sandbox.source.id": .string(sourceSandboxId),
                    "snapshotId": .string(snapshotId),
                ])
        } catch {
            try? await client.destroyVM(vmId: sandboxId)
            await removeJailArtifacts(plan)
            throw error
        }
    }

    static func freshEntropy() -> Data {
        var generator = SystemRandomNumberGenerator()
        var entropy = Data(capacity: 32)
        while entropy.count < 32 {
            withUnsafeBytes(of: generator.next()) { entropy.append(contentsOf: $0) }
        }
        return entropy
    }

    /// The jailer options for one microVM's jail plan — shared by cold
    /// provisioning, warm restores, and checkpoint restores so isolation
    /// settings can never drift between the three spawn paths.
    func makeJailerOptions(plan: SandboxJailPlan, guestMemoryBytes: Int64) -> JailerOptions {
        let cgroups = jailerCgroups(guestMemoryBytes: guestMemoryBytes)
        return JailerOptions(
            jailerBinaryPath: jailerConfig.jailerBinaryPath,
            chrootBaseDir: jailerConfig.chrootBaseDir,
            uid: plan.uid,
            gid: plan.gid,
            netnsPath: plan.netnsPath,
            cgroupVersion: cgroups.version,
            cgroups: cgroups.entries)
    }

    func bootSandbox(sandboxId: String) async throws {
        do {
            try await bootSandbox(sandboxId: sandboxId, allowWarmLaunch: true)
        } catch {
            if let digest = sandboxes[sandboxId]?.unverifiedRootfsCacheDigest {
                // Clear before awaiting the cache actor: later retries of a
                // genuinely broken image must not turn into a pull loop.
                sandboxes[sandboxId]?.unverifiedRootfsCacheDigest = nil
                logger.warning(
                    "Cold sandbox boot failed; invalidating its source rootfs cache entry once",
                    metadata: [
                        "strato.sandbox.id": .string(sandboxId),
                        "digest": .string(digest),
                    ])
                await imageService.invalidateCachedRootfs(manifestDigest: digest)
            }
            throw error
        }
    }

    /// `allowWarmLaunch: false` is the post-demotion retry: the freshly
    /// cold-provisioned guest must answer with its own identity, and a
    /// mismatch is terminal rather than another warm-launch attempt — a
    /// structural bound on the demote/boot recursion.
    func bootSandbox(sandboxId: String, allowWarmLaunch: Bool) async throws {
        guard let managed = sandboxes[sandboxId] else {
            throw SandboxRuntimeError.sandboxNotFound(sandboxId)
        }
        guard !checkpointing.contains(sandboxId) else {
            throw SandboxRuntimeError.checkpointInProgress(sandboxId)
        }
        let bootStarted = Date()

        let info = try await managed.manager.getInstanceInfo()
        switch info.state {
        case .running:
            break  // already running — idempotent
        case .notStarted:
            logger.info("Booting sandbox", metadata: ["strato.sandbox.id": .string(sandboxId)])
            try await managed.manager.start()
        case .paused:
            logger.info("Resuming sandbox", metadata: ["strato.sandbox.id": .string(sandboxId)])
            try await managed.manager.resume()
        }

        // Wait for the guest control agent to answer, so "booted" means the
        // guest is actually up. A miss here is transient — the reconciler
        // re-drives boot on the next sync. `get_status` rather than `ping`:
        // the workload state matters too, because a guest can be `held`
        // regardless of which identity it echoes (see below).
        let response = try await sendControl(.getStatus, udsPath: managed.vsockUdsPath, timeout: 20)
        guard case .status(let echoedId, let echoedNonce, let guestState, _) = response else {
            throw GuestControlError.malformedResponse("expected status, got \(response)")
        }
        let identityOK = identityMatches(
            response, sandboxId: sandboxId, expectedNonce: managed.identityNonce)
        let mismatch = GuestControlError.identityMismatch(
            expected: "\(sandboxId)/\(managed.identityNonce)", got: "\(echoedId)/\(echoedNonce)")

        var needsWarmLaunch = false
        if identityOK {
            // A held guest already echoing this sandbox's identity is an
            // interrupted launch (delivered, never completed — e.g. an agent
            // crash mid-flow with an older guest that swapped identity
            // early). Without re-launching it here the sandbox would report
            // `starting` forever while boot kept "succeeding".
            needsWarmLaunch = guestState == .held
        } else {
            // Not this sandbox's identity. One legitimate way that happens: a
            // warm-provisioned guest still holding the *template's* identity,
            // waiting for its launch (issue #426). Anything else is the
            // classic stale-generation problem and must fail the boot.
            guard allowWarmLaunch, guestState == .held else { throw mismatch }
            // Bind the held responder to the template this sandbox was
            // provisioned from, so a workload can never be launched into
            // some other process answering on the deterministic UDS. For an
            // adopted sandbox the binding did not survive the restart; the
            // template id shape is the remaining gate.
            if let expected = managed.warmHeldIdentity {
                guard echoedId == expected.templateId, echoedNonce == expected.templateNonce else {
                    throw GuestControlError.identityMismatch(
                        expected: "\(expected.templateId)/\(expected.templateNonce)",
                        got: "\(echoedId)/\(echoedNonce)")
                }
            } else {
                guard echoedId.hasPrefix("warm-template-") else { throw mismatch }
            }
            needsWarmLaunch = true
        }

        var bootPath = "cold"
        if needsWarmLaunch {
            // A demoted (freshly cold-provisioned) guest can never be held;
            // reaching here without warm launch allowed means the demotion
            // itself produced a held guest — fail rather than loop.
            guard allowWarmLaunch else { throw mismatch }
            do {
                try await launchWarmHeldGuest(sandboxId: sandboxId, managed: managed)
                sandboxes[sandboxId]?.warmHeldIdentity = nil
                bootPath = "warm"
            } catch {
                // A warm launch that fails must not wedge convergence on this
                // sandbox: demote it to a freshly provisioned cold microVM
                // and boot that once, warm launch disallowed.
                logger.warning(
                    "Warm launch failed; demoting the sandbox to a cold boot",
                    metadata: [
                        "strato.sandbox.id": .string(sandboxId),
                        "error": .string(error.localizedDescription),
                    ])
                try await demoteWarmSandboxToCold(sandboxId)
                try await bootSandbox(sandboxId: sandboxId, allowWarmLaunch: false)
                return
            }
        }

        // Agent wire compatibility says nothing about a guest already running
        // inside this microVM. The decoder accepts only the current guest
        // protocol, so a stale installed image/checkpoint fails here before the
        // workload is reported healthy.
        let capability = try await sendControl(
            .ping, udsPath: managed.vsockUdsPath, timeout: 10)
        guard
            identityMatches(
                capability, sandboxId: sandboxId, expectedNonce: managed.identityNonce)
        else {
            throw GuestControlError.identityMismatch(
                expected: "\(sandboxId)/\(managed.identityNonce)", got: "\(capability)")
        }
        sandboxes[sandboxId]?.guestControlProtocolVersion =
            capability.controlProtocolVersion
        // This sandbox has now proved that the cache-derived rootfs boots.
        // A later runtime/control failure must not evict that known-good
        // shared artifact.
        sandboxes[sandboxId]?.unverifiedRootfsCacheDigest = nil

        logger.info(
            "Sandbox guest agent healthy",
            metadata: [
                "strato.sandbox.id": .string(sandboxId),
                "bootPath": .string(bootPath),
                "bootMillis": .stringConvertible(Int(Date().timeIntervalSince(bootStarted) * 1000)),
            ])

        // The guest is confirmed up: ship its workload output from here on
        // (resuming from the last seq this host saw, so a pause/resume cycle
        // doesn't drop or duplicate lines).
        startLogFollow(sandboxId: sandboxId)
    }

    /// Launch the real workload into a warm-held guest (issue #426): resync
    /// the wall clock (frozen at template-snapshot time), deliver the
    /// sandbox's identity + process + fresh entropy via `launch`, and verify
    /// the guest now answers as this sandbox. The launch payload is
    /// reconstructed from the staged config drive, so the flow survives agent
    /// restarts between create and boot with no extra persisted state.
    func launchWarmHeldGuest(sandboxId: String, managed: Managed) async throws {
        guard let data = FileManager.default.contents(atPath: managed.configPath),
            let drive = try? SandboxConfigDrive.decode(fromBlockImage: data),
            drive.sandboxId == sandboxId
        else {
            throw SandboxRuntimeError.warmStartFailed(
                "staged config drive at \(managed.configPath) is unreadable; cannot reconstruct the launch payload"
            )
        }

        // A cache entry may outlive a guest-image replacement. Verify its
        // checkpointed init speaks the one current control contract before
        // delivering launch, regardless of whether this sandbox has a NIC.
        let capability = try await sendControl(
            .ping, udsPath: managed.vsockUdsPath, timeout: 10)
        if let expected = managed.warmHeldIdentity,
            !identityMatches(
                capability, sandboxId: expected.templateId,
                expectedNonce: expected.templateNonce)
        {
            throw GuestControlError.identityMismatch(
                expected: "\(expected.templateId)/\(expected.templateNonce)", got: "\(capability)")
        }

        // Clock first, launch second: the workload should start with a sane
        // wall clock. Best-effort, mirroring the restore-in-place flow.
        await resyncGuestClock(sandboxId: sandboxId, udsPath: managed.vsockUdsPath)

        // Fresh randomness so N sandboxes launched from one template do not
        // share the snapshot's frozen RNG pool. Warm launch keeps this
        // best-effort; user-checkpoint fork re-identification requires it.
        let entropy = Self.freshEntropy()
        let launch = GuestControlProtocol.LaunchRequest(
            sandboxId: sandboxId, identityNonce: drive.identityNonce,
            imageConfig: drive.imageConfig, overrides: drive.overrides, entropy: entropy,
            // The template guest booted under the template's identity, so the
            // hostname travels with the launch — otherwise a warm-provisioned
            // sandbox would differ from a cold one by warm-cache state alone.
            hostname: drive.hostname,
            // Same argument for the NIC (STR-104): the template's device was
            // never addressed, because a template is shared across sandboxes.
            // The snapshot load pointed it at this sandbox's TAP; this is what
            // gives it this sandbox's MAC, address, routes and resolvers.
            network: drive.network)
        let response = try await sendControl(
            .launch(launch), udsPath: managed.vsockUdsPath, timeout: 20)
        guard case .launched = response else {
            throw GuestControlError.malformedResponse("expected launched, got \(response)")
        }

        let verify = try await sendControl(.ping, udsPath: managed.vsockUdsPath, timeout: 10)
        guard identityMatches(verify, sandboxId: sandboxId, expectedNonce: drive.identityNonce) else {
            throw GuestControlError.identityMismatch(
                expected: "\(sandboxId)/\(drive.identityNonce)", got: "\(verify)")
        }
    }

    /// Replace a warm-provisioned sandbox whose launch failed with a freshly
    /// cold-provisioned one under the same id and spec.
    ///
    /// The `checkpointing` guard makes the multi-await teardown/rebuild
    /// atomic with respect to the rest of the actor's surface — without it,
    /// a delete interleaving the awaits would complete against the removed
    /// entry and the demotion would then resurrect a deleted sandbox. All
    /// fallible acquisition (guest image, rootfs re-materialization — with
    /// the create-time credential, since the rootfs cache may have evicted a
    /// private image by now) happens *before* the old microVM is destroyed,
    /// so a failure leaves the held guest intact for the next boot retry.
    func demoteWarmSandboxToCold(_ sandboxId: String) async throws {
        guard let managed = sandboxes[sandboxId] else {
            throw SandboxRuntimeError.sandboxNotFound(sandboxId)
        }
        guard !checkpointing.contains(sandboxId) else {
            throw SandboxRuntimeError.checkpointInProgress(sandboxId)
        }
        checkpointing.insert(sandboxId)
        defer { checkpointing.remove(sandboxId) }

        let guestImage = try SandboxGuestImage.resolve(atDirectory: guestImagePath)
        let materialized = try await imageService.materializeRootfs(
            image: managed.spec.image, imageDigest: managed.spec.imageDigest,
            credential: managed.registryCredential)
        let nonce = UUID().uuidString
        let configDrive = SandboxConfigDrive(
            sandboxId: sandboxId, identityNonce: nonce,
            guestConfig: materialized.guestConfig, spec: managed.spec,
            network: try guestNetwork(attachments: managed.networkAttachments))
        let configData = try configDrive.blockImage(
            minimumBytes: SandboxConfigDrive.standardBlockImageBytes)

        try? await client.destroyVM(vmId: sandboxId)
        if let plan = managed.jail {
            // The namespace stays: it holds the veth, TAP and `tc` filters the
            // orchestrator realized for this sandbox's NIC, and the cold
            // provision below configures Firecracker against exactly that TAP.
            await removeJailArtifacts(plan, removingNetns: false)
        }
        removeArtifacts(sandboxId)
        sandboxes.removeValue(forKey: sandboxId)

        // The same device set, not a dropped one: since STR-104 a networked
        // sandbox can warm-start, so this path is reachable with a NIC and has
        // to rebuild it.
        try await coldProvisionAndRegister(
            sandboxId: sandboxId, spec: managed.spec, credential: managed.registryCredential,
            materialized: materialized, guestImage: guestImage, nonce: nonce, configData: configData,
            networkAttachments: managed.networkAttachments)
    }

    /// Best-effort wall-clock resync after a snapshot restore or warm
    /// launch: the guest's CLOCK_REALTIME froze at snapshot time. Guests
    /// that predate `sync_clock` answer `error`, which is logged and
    /// tolerated. Shared by restore-in-place and the warm-launch path.
    func resyncGuestClock(sandboxId: String, udsPath: String) async {
        let unixNanos = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        do {
            _ = try await sendControl(.syncClock(unixNanos: unixNanos), udsPath: udsPath, timeout: 5)
        } catch {
            logger.warning(
                "Guest did not accept clock resync (older guest image?)",
                metadata: [
                    "strato.sandbox.id": .string(sandboxId),
                    "error": .string(error.localizedDescription),
                ])
        }
    }

    func shutdownSandbox(sandboxId: String) async throws {
        guard let managed = sandboxes[sandboxId] else {
            throw SandboxRuntimeError.sandboxNotFound(sandboxId)
        }
        guard !checkpointing.contains(sandboxId) else {
            throw SandboxRuntimeError.checkpointInProgress(sandboxId)
        }
        // A paused guest can't serve exec sessions or the log follow stream:
        // end the former (terminal for their control-plane sessions) and stop
        // the latter. The log follow keeps its seq/partial-line state so a
        // later boot resumes cleanly.
        await closeExecSessions(sandboxId: sandboxId, reason: "sandbox stopped")
        await stopLogFollow(sandboxId: sandboxId, retire: false)

        // Firecracker cannot stop-and-keep-state, so a "stopped" sandbox is a
        // paused microVM. Only a running one needs pausing; a not-started or
        // already-paused sandbox is idempotently satisfied.
        let info = try await managed.manager.getInstanceInfo()
        if info.state == .running {
            logger.info("Stopping sandbox", metadata: ["strato.sandbox.id": .string(sandboxId)])
            try await managed.manager.pause()
        }
    }

    func deleteSandbox(sandboxId: String) async throws {
        let recordedUID = sandboxes[sandboxId]?.jail?.uid ?? jailUIDs.uid(for: sandboxId)
        try await deleteSandbox(sandboxId: sandboxId, jailUID: recordedUID)
    }

    func deleteSandbox(sandboxId: String, jailUID: UInt32?) async throws {
        // A delete interleaving with a checkpoint/restore (actor reentrancy
        // across their awaits) could tear the sandbox down mid-sequence and
        // leave the restore's freshly spawned process untracked. Refuse as
        // transient; the reconciler re-drives the delete once the
        // checkpoint/restore finishes.
        guard !checkpointing.contains(sandboxId) else {
            throw SandboxRuntimeError.checkpointInProgress(sandboxId)
        }
        logger.info("Deleting sandbox", metadata: ["strato.sandbox.id": .string(sandboxId)])
        // End interactive/log streams first: the guest is about to disappear,
        // and their control-plane sessions must learn why. Deleting is the
        // true end-of-stream for the workload's logs, so flush any partial
        // line the assembler is holding.
        await closeExecSessions(sandboxId: sandboxId, reason: "sandbox deleted")
        await stopLogFollow(sandboxId: sandboxId, retire: true)
        // The caller may release the durable UID immediately after this
        // returns, so teardown is deliberately not best effort.
        try await prepareJailUIDRelease(for: sandboxId, jailUID: jailUID)
    }

    func adoptSandbox(sandboxId: String, spec: SandboxSpec) async throws -> SandboxStatus {
        try await adoptSandbox(
            sandboxId: sandboxId, spec: spec, jailUID: jailUIDs.uid(for: sandboxId))
    }

    func adoptSandbox(
        sandboxId: String, spec: SandboxSpec, jailUID: UInt32?
    ) async throws -> SandboxStatus {
        if let managed = sandboxes[sandboxId] {
            // A replayed sync can race adoption; if already managed, adoption is
            // satisfied only after a running guest has passed the strict
            // current-protocol handshake. A prior failed adoption intentionally
            // leaves the entry routable for teardown, but must not make the next
            // adoption silently succeed.
            let status = try await getSandboxStatus(sandboxId: sandboxId)
            if managed.guestControlProtocolVersion == nil, status != .stopped {
                let capability = try await sendControl(
                    .ping, udsPath: managed.vsockUdsPath, timeout: 10)
                guard
                    identityMatches(
                        capability, sandboxId: sandboxId,
                        expectedNonce: managed.identityNonce)
                else {
                    throw GuestControlError.identityMismatch(
                        expected: "\(sandboxId)/\(managed.identityNonce)", got: "\(capability)")
                }
                sandboxes[sandboxId]?.guestControlProtocolVersion =
                    capability.controlProtocolVersion
            }
            return status
        }

        // A jailed orphan's socket lives inside its chroot, an unjailed one's
        // in the flat socket directory — and both files can exist at once (a
        // stale chroot left by a crashed jailed life beside a live unjailed
        // recreation, or vice versa). A running process keeps whatever barrier
        // it was born with, so every layout whose socket exists is *attempted*,
        // jail first; only a candidate whose socket is dead falls through to
        // the next, and existence alone never rules the live one out.
        var candidates: [(jailPlan: SandboxJailPlan?, jailOptions: JailerOptions?, socketPath: String)] = []
        let jailedSocketPath = JailerOptions.socketPath(
            chrootBaseDir: jailerConfig.chrootBaseDir,
            firecrackerBinaryPath: firecrackerBinaryPath,
            vmId: sandboxId)
        if FileManager.default.fileExists(atPath: jailedSocketPath) {
            guard let jailUID else {
                throw SandboxRuntimeError.jailIdentityUnavailable(
                    "sandbox \(sandboxId) has a jailed API socket but no recorded uid/gid")
            }
            let plan = try jailPlan(for: sandboxId, recordedUID: jailUID)
            candidates.append(
                (
                    plan,
                    JailerOptions(
                        jailerBinaryPath: jailerConfig.jailerBinaryPath,
                        chrootBaseDir: jailerConfig.chrootBaseDir,
                        uid: plan.uid, gid: plan.gid),
                    jailedSocketPath
                ))
        }
        let flatSocketPath = FirecrackerClient.socketPath(socketDirectory: socketDirectory, vmId: sandboxId)
        if FileManager.default.fileExists(atPath: flatSocketPath) {
            candidates.append((nil, nil, flatSocketPath))
        }
        guard !candidates.isEmpty else {
            try await confirmNoSandboxProcessBeforeReportingGone(
                sandboxId, jailUID: jailUID)
            throw SandboxRuntimeError.adoptionTargetGone(
                "sandbox \(sandboxId) has no Firecracker API socket at \(flatSocketPath) nor inside its jail")
        }

        var adoption: (manager: FirecrackerManager, info: InstanceInfo, jailPlan: SandboxJailPlan?)?
        var lastError: Error?
        for candidate in candidates {
            logger.info(
                "Re-adopting orphaned sandbox",
                metadata: [
                    "strato.sandbox.id": .string(sandboxId),
                    "socket": .string(candidate.socketPath),
                    "jailed": .stringConvertible(candidate.jailPlan != nil),
                ])
            do {
                let (manager, info) = try await client.adoptVM(vmId: sandboxId, jail: candidate.jailOptions)
                adoption = (manager, info, candidate.jailPlan)
                break
            } catch {
                // A live Firecracker always answers its API socket, so a failed
                // connect means this candidate's process is gone and its socket
                // merely outlived it — try the next layout.
                lastError = error
            }
        }
        guard let (manager, info, jailPlan) = adoption else {
            // An absent or unconnectable socket is not process-death proof.
            try await confirmNoSandboxProcessBeforeReportingGone(
                sandboxId, jailUID: jailUID)
            throw SandboxRuntimeError.adoptionTargetGone(
                "sandbox \(sandboxId) has no live Firecracker API socket: \(lastError?.localizedDescription ?? "unknown error")"
            )
        }

        let rootfsPath: String
        let configPath: String
        let vsockUdsPath: String
        if let plan = jailPlan {
            rootfsPath = plan.hostPath(forInJail: SandboxJailPlan.rootfsPathInJail)
            configPath = plan.hostPath(forInJail: SandboxJailPlan.configPathInJail)
            vsockUdsPath = plan.vsockUDSHostPath
        } else {
            let dir = sandboxDirectory(sandboxId)
            rootfsPath = dir + "/rootfs.ext4"
            configPath = dir + "/config.img"
            vsockUdsPath = vsockUDSPath(sandboxId)
        }
        // Recover the complete current-schema identity from the staged config
        // drive. An absent/legacy drive is not safe to adopt by id alone.
        let identityNonce = try recoverIdentityNonce(
            configPath: configPath, expectedSandboxId: sandboxId)
        sandboxes[sandboxId] = Managed(
            spec: spec, rootfsPath: rootfsPath, configPath: configPath,
            vsockUdsPath: vsockUdsPath, identityNonce: identityNonce, jail: jailPlan,
            manager: manager, lastExitCode: nil)

        let status = await mappedStatus(
            instance: info.state, udsPath: vsockUdsPath, sandboxId: sandboxId)
        if info.state == .running {
            let capability = try await sendControl(.ping, udsPath: vsockUdsPath, timeout: 10)
            guard
                identityMatches(
                    capability, sandboxId: sandboxId, expectedNonce: identityNonce)
            else {
                throw GuestControlError.identityMismatch(
                    expected: "\(sandboxId)/\(identityNonce)", got: "\(capability)")
            }
            sandboxes[sandboxId]?.guestControlProtocolVersion =
                capability.controlProtocolVersion
            // Same contract as boot: while the microVM runs, the guest serves
            // vsock and its retained ring buffer must ship — even when the
            // workload itself is still starting or has already exited (its
            // final output is still buffered guest-side). Seq state from a
            // previous incarnation is gone, so this resumes from the oldest
            // retained ring-buffer record.
            startLogFollow(sandboxId: sandboxId)
        }
        logger.info(
            "Sandbox re-adopted",
            metadata: ["strato.sandbox.id": .string(sandboxId), "status": .string(status.rawValue)])
        return status
    }

    func getSandboxStatus(sandboxId: String) async throws -> SandboxStatus {
        guard let managed = sandboxes[sandboxId] else {
            throw SandboxRuntimeError.sandboxNotFound(sandboxId)
        }
        let info: InstanceInfo
        do {
            info = try await managed.manager.getInstanceInfo()
        } catch {
            return .unknown
        }
        return await mappedStatus(instance: info.state, udsPath: managed.vsockUdsPath, sandboxId: sandboxId)
    }

    func exitCode(sandboxId: String) async -> Int? {
        sandboxes[sandboxId]?.lastExitCode
    }
}

#endif
