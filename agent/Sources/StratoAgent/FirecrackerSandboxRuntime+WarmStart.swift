import Foundation
import Logging
import StratoAgentCore
import StratoShared

#if os(Linux)
import Glibc
import SwiftFirecracker

/// Owns warm-template construction, caching, launch, and cleanup.
extension FirecrackerSandboxRuntime {
    // MARK: - Warm start (issue #426)

    /// The warm-snapshot cache key for one (image, guest, machine shape)
    /// combination on this host. Templates are always built with
    /// standard-capacity config drives, and only standard-capacity sandboxes
    /// are warm-eligible, so the capacity component is the constant.
    func warmSnapshotKey(
        imageDigest: String, guestImage: SandboxGuestImage, spec: SandboxSpec, nicCount: Int
    ) -> WarmSnapshotKey {
        WarmSnapshotKey(
            imageDigest: imageDigest,
            guestVersion: guestImage.version,
            arch: guestImage.arch,
            firecrackerFingerprint: firecrackerFingerprint,
            vcpus: spec.cpus,
            memoryMiB: spec.memoryBytes / (1024 * 1024),
            configCapacityBytes: SandboxConfigDrive.standardBlockImageBytes,
            jailed: jailNewSandboxes,
            cpuTemplate: spec.cpuTemplate,
            nicCount: nicCount)
    }

    /// Kick off a background warm-template build for `key`. Skipped — not
    /// failed — when any build is already running (one at a time host-wide:
    /// each build boots an unaccounted, guest-memory-sized microVM) or when
    /// this key failed within the retry interval; a later create re-triggers.
    func maybeStartWarmTemplateBuild(
        key: WarmSnapshotKey, materialized: MaterializedRootfs, guestImage: SandboxGuestImage,
        spec: SandboxSpec
    ) {
        guard warmStartActive, warmBuildsInFlight.isEmpty else { return }
        let token = key.directoryName
        if let failedAt = warmBuildFailures[token],
            Date().timeIntervalSince(failedAt) < Self.warmBuildRetryInterval
        {
            return
        }
        warmBuildsInFlight.insert(token)
        Task {
            await self.buildWarmTemplate(
                key: key, materialized: materialized, guestImage: guestImage, spec: spec)
        }
    }

    /// Boot a throwaway template microVM to the guest's held point, snapshot
    /// it, and publish the artifacts into the warm cache. The template rides
    /// the exact cold-provision path a real sandbox would, with `warm_hold`
    /// set in its config drive so the guest parks instead of launching a
    /// workload. Failures are logged and remembered, never surfaced — warm
    /// start is an optimization, and sandboxes keep cold-booting without it.
    func buildWarmTemplate(
        key: WarmSnapshotKey, materialized: MaterializedRootfs, guestImage: SandboxGuestImage,
        spec: SandboxSpec
    ) async {
        defer { warmBuildsInFlight.remove(key.directoryName) }
        let templateId = "warm-template-" + UUID().uuidString.lowercased()
        let started = Date()
        logger.info(
            "Building warm-start template snapshot",
            metadata: [
                "warmKey": .string(key.directoryName),
                "image": .string(spec.image),
                "templateId": .string(templateId),
            ])

        var vm: ProvisionedMicroVM?
        do {
            let nonce = UUID().uuidString
            let configDrive = SandboxConfigDrive(
                sandboxId: templateId,
                identityNonce: nonce,
                imageConfig: SandboxConfigDrive.ImageConfig(
                    env: materialized.guestConfig.env,
                    entrypoint: materialized.guestConfig.entrypoint,
                    cmd: materialized.guestConfig.cmd,
                    workingDir: materialized.guestConfig.workingDir ?? "",
                    user: materialized.guestConfig.user ?? ""),
                overrides: SandboxConfigDrive.ProcessOverrides(
                    entrypoint: nil, cmd: nil, env: [:], workdir: nil, user: nil),
                warmHold: true)
            let configData = try configDrive.blockImage(
                minimumBytes: SandboxConfigDrive.standardBlockImageBytes)
            guard configData.count == SandboxConfigDrive.standardBlockImageBytes else {
                throw SandboxRuntimeError.warmStartFailed(
                    "the image config exceeds the standard config-drive capacity")
            }

            // A template is per-(image, machine shape) and shared across
            // sandboxes, so it never carries a particular sandbox's NIC — but
            // a template for *networked* sandboxes must carry a network
            // **device**, because a snapshot load can repoint one and never
            // add one (STR-104). The device is backed by a throwaway TAP in
            // the template's own namespace, attached to nothing: the held
            // guest never addresses it, and the restore points it at the real
            // sandbox's TAP before the guest is ever launched.
            let templateAttachments = try await prepareTemplateNIC(
                templateId: templateId, nicCount: key.nicCount)
            let provisioned = try await provisionColdMicroVM(
                vmId: templateId, spec: spec, rootfsSourcePath: materialized.rootfsPath,
                configData: configData, guestImage: guestImage,
                networkAttachments: templateAttachments)
            vm = provisioned
            try await provisioned.manager.start()

            // The guest must actually honor `warm_hold`: an older guest
            // ignores the unknown field and execs the image's default
            // command — snapshotting that would capture a running workload
            // under the template's identity.
            let status = try await sendControl(
                .getStatus, udsPath: provisioned.vsockUdsPath, timeout: 30)
            guard case .status(let id, let echoedNonce, .held, _) = status,
                id == templateId, echoedNonce == nonce
            else {
                throw SandboxRuntimeError.warmStartFailed(
                    "the guest did not enter the held state (guest image predates warm start?)")
            }

            // A template freezes the guest init into a checkpoint, so validate
            // the exact current protocol before publishing it to the cache.
            let capability = try await sendControl(
                .ping, udsPath: provisioned.vsockUdsPath, timeout: 10)
            guard identityMatches(capability, sandboxId: templateId, expectedNonce: nonce) else {
                throw GuestControlError.identityMismatch(
                    expected: "\(templateId)/\(nonce)", got: "\(capability)")
            }

            try await provisioned.manager.pause()

            let staging = try warmCache.makeStagingDirectory()
            do {
                try await captureSnapshot(
                    manager: provisioned.manager, jail: provisioned.jail,
                    memoryTarget: staging + "/" + WarmSandboxSnapshotCache.memoryFile,
                    vmstateTarget: staging + "/" + WarmSandboxSnapshotCache.vmstateFile)
                // The template's rootfs AS OF the snapshot: the held guest
                // has it mounted, so restores must clone exactly these bytes
                // (the pristine image would no longer match the page cache).
                try await reflinkCopy(
                    from: provisioned.rootfsPath,
                    to: staging + "/" + WarmSandboxSnapshotCache.rootfsFile)
                let info = try await provisioned.manager.getInstanceInfo()
                let meta = WarmSandboxSnapshotCache.Meta(
                    templateId: templateId,
                    templateNonce: nonce,
                    imageDigest: key.imageDigest,
                    guestVersion: key.guestVersion,
                    firecrackerVersion: info.vmlinuxVersion,
                    createdAtUnixSeconds: Int64(Date().timeIntervalSince1970))
                try JSONEncoder().encode(meta).write(
                    to: URL(fileURLWithPath: staging + "/" + WarmSandboxSnapshotCache.metaFile))
            } catch {
                try? FileManager.default.removeItem(atPath: staging)
                throw error
            }
            try warmCache.publish(stagingDirectory: staging, for: key)

            await teardownWarmTemplate(templateId: templateId, vm: vm)
            warmBuildFailures.removeValue(forKey: key.directoryName)
            // The sweep walks and deletes multi-GB entries; run it off the
            // actor so it cannot stall sandbox operations. Sweep twice: once
            // now, and once after DiskCacheLRU's recent-use grace window has
            // passed — a burst of builds can land the cache over budget with
            // every entry still grace-protected, and without the re-sweep
            // nothing would enforce the cap until the next publish.
            let cache = warmCache
            let budget = warmCacheBudgetBytes
            let sweepLogger = logger
            Task.detached(priority: .utility) {
                cache.sweep(budgetBytes: budget, logger: sweepLogger)
                let regraceDelay = DiskCacheLRU.defaultGraceInterval + 60
                try? await Task.sleep(nanoseconds: UInt64(regraceDelay * 1_000_000_000))
                cache.sweep(budgetBytes: budget, logger: sweepLogger)
            }
            logger.info(
                "Warm-start template snapshot ready",
                metadata: [
                    "warmKey": .string(key.directoryName),
                    "buildMillis": .stringConvertible(Int(Date().timeIntervalSince(started) * 1000)),
                ])
        } catch {
            warmBuildFailures[key.directoryName] = Date()
            logger.warning(
                "Warm-start template build failed; sandboxes for this image cold-boot until a later retry",
                metadata: [
                    "warmKey": .string(key.directoryName),
                    "error": .string(error.localizedDescription),
                ])
            await teardownWarmTemplate(templateId: templateId, vm: vm)
        }
    }

    /// Create the throwaway NIC a networked warm template is snapshotted with
    /// (STR-104), and describe it the way `provisionColdMicroVM` expects.
    ///
    /// A bare TAP inside the template's own network namespace, wired to
    /// nothing: there is no logical port to bind it to (a template is not a
    /// sandbox and has no IPAM allocation), and it needs no connectivity — the
    /// guest parks `held` without ever addressing the device. All that has to
    /// survive into the snapshot is the *device*, since a load can repoint one
    /// but not add one. It dies with the namespace when the template is torn
    /// down.
    func prepareTemplateNIC(
        templateId: String, nicCount: Int
    ) async throws -> [ResolvedNetworkAttachment] {
        guard nicCount > 0 else { return [] }
        guard let ipBinaryPath = jailerConfig.ipBinaryPath else {
            throw SandboxRuntimeError.warmStartFailed(
                "the `ip` tool (iproute2) was not found on this host")
        }
        let plan = SandboxJailPlan(
            sandboxId: templateId, config: jailerConfig, firecrackerBinaryPath: firecrackerBinaryPath)
        // Same derivation as a real sandbox's NIC, so the leak sweep's
        // namespace removal is all the cleanup this ever needs.
        let tapName = sandboxNICDeviceNames(sandboxId: templateId, nicIndex: 0).tap
        try await createNetns(plan.netnsName)
        for arguments in [
            [
                "-n", plan.netnsName, "tuntap", "add", "dev", tapName, "mode", "tap",
                "user", String(plan.uid), "group", String(plan.gid),
            ],
            ["-n", plan.netnsName, "link", "set", tapName, "up"],
        ] {
            let result: ProcessResult
            do {
                result = try await ProcessRunner.run(
                    executableURL: URL(fileURLWithPath: ipBinaryPath), arguments: arguments)
            } catch {
                throw SandboxRuntimeError.warmStartFailed(
                    "spawning `\(ipBinaryPath) \(arguments.joined(separator: " "))` failed: "
                        + error.localizedDescription)
            }
            guard result.terminationStatus == 0 else {
                throw SandboxRuntimeError.warmStartFailed(
                    "`ip \(arguments.joined(separator: " "))` failed (exit \(result.terminationStatus)): "
                        + result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return [
            ResolvedNetworkAttachment(
                network: "warm-template",
                attachment: .tap(interface: tapName),
                macAddress: Self.templateMACAddress)
        ]
    }

    /// Remove template debris a crash mid-build left behind: destroy any
    /// still-running template microVM (best-effort adopt-then-destroy — the
    /// self-describing `warm-template-` id prefix is what makes this safe
    /// without manifest bookkeeping), then its jail, storage, and socket
    /// leftovers. Templates are jailed-only, so only the jail layout is
    /// probed for live processes.
    func sweepLeakedWarmTemplates() async {
        let fileManager = FileManager.default
        // Staging directories abandoned by a crash are excluded from the
        // budget sweep, so this is their only cleanup path — and it must not
        // age-gate: this call runs synchronously before this method's first
        // suspension, and the sweep precedes any template build this process
        // can start (first create, before maybeStartWarmTemplateBuild), so
        // no staging directory can be live here regardless of age. A restart
        // shortly after a crash would otherwise skip the debris forever.
        warmCache.removeAbandonedStaging(olderThan: 0)
        var leaked: Set<String> = []
        if let names = try? fileManager.contentsOfDirectory(atPath: sandboxStoragePath) {
            leaked.formUnion(names.filter { $0.hasPrefix("warm-template-") })
        }
        let jailBase =
            jailerConfig.chrootBaseDir + "/" + (firecrackerBinaryPath as NSString).lastPathComponent
        if let names = try? fileManager.contentsOfDirectory(atPath: jailBase) {
            leaked.formUnion(names.filter { $0.hasPrefix("warm-template-") })
        }
        // The namespace of a NIC-shaped template (STR-104), which is the
        // *first* artifact its build creates — before the jail root or the
        // storage directory the two scans above look at. A crash in that
        // window leaves a namespace with no other trace of the template, and
        // template ids are random and never retried, so nothing else would
        // ever reap it.
        if let names = try? fileManager.contentsOfDirectory(atPath: SandboxJailPlan.netnsDirectory) {
            leaked.formUnion(
                names.compactMap(SandboxJailPlan.sandboxId(fromNetnsName:))
                    .filter { $0.hasPrefix("warm-template-") })
        }
        for templateId in leaked.sorted() {
            logger.warning(
                "Sweeping leaked warm-template artifacts from a previous agent life",
                metadata: ["templateId": .string(templateId)])
            let plan = SandboxJailPlan(
                sandboxId: templateId, config: jailerConfig, firecrackerBinaryPath: firecrackerBinaryPath)
            let socketPath = JailerOptions.socketPath(
                chrootBaseDir: jailerConfig.chrootBaseDir,
                firecrackerBinaryPath: firecrackerBinaryPath,
                vmId: templateId)
            if fileManager.fileExists(atPath: socketPath),
                (try? await client.adoptVM(
                    vmId: templateId,
                    jail: JailerOptions(
                        jailerBinaryPath: jailerConfig.jailerBinaryPath,
                        chrootBaseDir: jailerConfig.chrootBaseDir,
                        uid: plan.uid, gid: plan.gid))) != nil
            {
                try? await client.destroyVM(vmId: templateId)
            }
            await teardownWarmTemplate(templateId: templateId, vm: nil)
        }
        // The previous life may also have left the cache over budget (its
        // post-publish sweeps could have been cut short); re-enforce once,
        // off-actor.
        let cache = warmCache
        let budget = warmCacheBudgetBytes
        let sweepLogger = logger
        Task.detached(priority: .utility) {
            cache.sweep(budgetBytes: budget, logger: sweepLogger)
        }
    }

    /// Best-effort teardown of a template microVM and its staging artifacts.
    /// The jail layout is derived from the template id rather than trusting
    /// `vm`: a provisioning failure leaves `vm` nil with a partially staged
    /// jail, and — template ids being random, never retried — nothing else
    /// would ever clean it this agent life (the leak sweep already ran).
    func teardownWarmTemplate(templateId: String, vm: ProvisionedMicroVM?) async {
        try? await client.destroyVM(vmId: templateId)
        let plan =
            vm?.jail
            ?? SandboxJailPlan(
                sandboxId: templateId, config: jailerConfig, firecrackerBinaryPath: firecrackerBinaryPath)
        await removeJailArtifacts(plan)
        removeArtifacts(templateId)
        try? FileManager.default.removeItem(atPath: vsockUDSPath(templateId))
    }

    /// `stat(2)` size of a file, 0 when unreadable (sizes are advisory —
    /// quota accounting — never load-bearing for correctness).
    func fileSize(_ path: String) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Move a file, replacing any existing target. `moveItem` falls back to
    /// copy+delete across filesystems, so this works whether or not the
    /// archive shares a filesystem with the jail chroot.
    func moveReplacingItem(from source: String, to target: String) throws {
        if FileManager.default.fileExists(atPath: target) {
            try FileManager.default.removeItem(atPath: target)
        }
        try FileManager.default.moveItem(atPath: source, toPath: target)
    }

    /// Copy a file via `cp --reflink=auto --sparse=auto`: a metadata-only
    /// clone on filesystems that support reflinks (btrfs, XFS, future ZFS
    /// pools — issue #350), a regular copy otherwise. Sparse regions of the
    /// memory file stay sparse either way.
    func reflinkCopy(from source: String, to target: String) async throws {
        let cpCandidates = ["/usr/bin/cp", "/bin/cp"]
        guard let cpBinary = cpCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else {
            // No cp binary — fall back to a plain (non-reflink) copy.
            if FileManager.default.fileExists(atPath: target) {
                try FileManager.default.removeItem(atPath: target)
            }
            try FileManager.default.copyItem(atPath: source, toPath: target)
            return
        }
        let result = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: cpBinary),
            arguments: ["--reflink=auto", "--sparse=auto", "--force", source, target])
        if result.terminationStatus != 0 {
            throw SandboxRuntimeError.snapshotIOFailed(
                "`cp --reflink=auto \(source) \(target)` failed (exit \(result.terminationStatus)): "
                    + result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

#endif
