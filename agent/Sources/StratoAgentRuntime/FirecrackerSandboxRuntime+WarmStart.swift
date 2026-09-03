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
        var lease: SandboxJailUIDLease?
        var stagingDirectory: String?
        do {
            let templateLease = try jailUIDs.lease(for: templateId)
            lease = templateLease
            // Templates are absent from the workload manifest, so this tiny
            // durable record is their restart-survival identity.
            try persistWarmTemplateUID(templateLease.uid, templateId: templateId)

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
            stagingDirectory = staging
            try await captureSnapshot(
                manager: provisioned.manager, jail: provisioned.jail,
                memoryTarget: staging + "/" + WarmSandboxSnapshotCache.memoryFile,
                vmstateTarget: staging + "/" + WarmSandboxSnapshotCache.vmstateFile)
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
            try warmCache.publish(stagingDirectory: staging, for: key)
            stagingDirectory = nil

            try await teardownWarmTemplate(templateId: templateId, vm: vm, lease: lease)
            lease = nil
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
            let buildError = error
            var stagingCleanupError: (any Error)?
            if let stagingDirectory {
                do {
                    try removeItemIfPresent(atPath: stagingDirectory)
                } catch {
                    stagingCleanupError = error
                    logger.error(
                        "Warm-template staging cleanup is incomplete; retaining its jail UID",
                        metadata: [
                            "templateId": .string(templateId),
                            "stagingDirectory": .string(stagingDirectory),
                            "error": .string(error.localizedDescription),
                        ])
                }
            }
            warmBuildFailures[key.directoryName] = Date()
            logger.warning(
                "Warm-start template build failed; sandboxes for this image cold-boot until a later retry",
                metadata: [
                    "warmKey": .string(key.directoryName),
                    "error": .string(buildError.localizedDescription),
                ])
            do {
                try await teardownWarmTemplate(
                    templateId: templateId, vm: vm, lease: lease,
                    releaseUID: stagingCleanupError == nil)
            } catch {
                logger.error(
                    "Warm-template cleanup is incomplete; retaining its jail UID",
                    metadata: [
                        "templateId": .string(templateId),
                        "error": .string(error.localizedDescription),
                    ])
            }
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
        let plan = try jailPlan(for: templateId)
        // Same layout as a real sandbox's NIC, so the leak sweep's
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

    static let warmTemplateUIDFile = "jail-uid"

    func warmTemplateUIDPath(_ templateId: String) -> String {
        sandboxDirectory(templateId) + "/" + Self.warmTemplateUIDFile
    }

    func persistWarmTemplateUID(_ uid: UInt32, templateId: String) throws {
        let directory = sandboxDirectory(templateId)
        let directoryAlreadyExisted = FileManager.default.fileExists(atPath: directory)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        if !directoryAlreadyExisted {
            try synchronizeDirectory(atPath: sandboxStoragePath)
        }
        let path = warmTemplateUIDPath(templateId)
        try Data("\(uid)\n".utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.synchronize()
        try handle.close()
        try synchronizeDirectory(atPath: directory)
    }

    func synchronizeDirectory(atPath path: String) throws {
        let descriptor = Glibc.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw SandboxRuntimeError.jailSetupFailed(
                "could not open warm-template directory \(path) for synchronization: "
                    + String(cString: strerror(errno)))
        }
        var descriptorIsOpen = true
        defer {
            if descriptorIsOpen { _ = Glibc.close(descriptor) }
        }
        guard Glibc.fsync(descriptor) == 0 else {
            throw SandboxRuntimeError.jailSetupFailed(
                "could not synchronize warm-template directory \(path): "
                    + String(cString: strerror(errno)))
        }
        let closeResult = Glibc.close(descriptor)
        descriptorIsOpen = false
        guard closeResult == 0 else {
            throw SandboxRuntimeError.jailSetupFailed(
                "could not close synchronized warm-template directory \(path): "
                    + String(cString: strerror(errno)))
        }
    }

    static func isFileNotFound(_ error: any Error) -> Bool {
        var current: any Error = error
        while true {
            let candidate = current as NSError
            if candidate.domain == NSCocoaErrorDomain,
                candidate.code == NSFileNoSuchFileError
                    || candidate.code == NSFileReadNoSuchFileError
            {
                return true
            }
            if candidate.domain == NSPOSIXErrorDomain,
                candidate.code == POSIXErrorCode.ENOENT.rawValue
            {
                return true
            }
            guard let underlying = candidate.userInfo[NSUnderlyingErrorKey] as? any Error else {
                return false
            }
            current = underlying
        }
    }

    func directoryContentsIfPresent(atPath path: String) throws -> [String] {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: path)
        } catch  where Self.isFileNotFound(error) {
            return []
        } catch {
            throw SandboxRuntimeError.jailSetupFailed(
                "could not inspect warm-template cleanup root \(path): "
                    + error.localizedDescription)
        }
    }

    func recoveredWarmTemplateUID(
        _ templateId: String, processEffectiveUID: UInt32?
    ) throws -> UInt32 {
        do {
            let raw = try String(
                contentsOfFile: warmTemplateUIDPath(templateId), encoding: .utf8)
            guard
                let uid = UInt32(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                uid != 0, uid != UInt32.max
            else {
                throw SandboxRuntimeError.jailIdentityUnavailable(
                    "leaked warm template \(templateId) has an invalid jail UID sidecar")
            }
            return uid
        } catch  where Self.isFileNotFound(error) {
            // A pre-STR-290 build has no sidecar; inspect artifacts/processes.
        } catch let error as SandboxRuntimeError {
            throw error
        } catch {
            throw SandboxRuntimeError.jailSetupFailed(
                "could not read jail UID sidecar for leaked warm template \(templateId): "
                    + error.localizedDescription)
        }

        let jailDirectory = SandboxJailPlan.jailDirectory(
            sandboxId: templateId, chrootBaseDir: jailerConfig.chrootBaseDir,
            firecrackerBinaryPath: firecrackerBinaryPath)
        for path in [jailDirectory + "/root", jailDirectory + "/root/rootfs.ext4"] {
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try FileManager.default.attributesOfItem(atPath: path)
            } catch  where Self.isFileNotFound(error) {
                continue
            } catch {
                throw SandboxRuntimeError.jailSetupFailed(
                    "could not inspect ownership of leaked warm template artifact \(path): "
                        + error.localizedDescription)
            }
            if let owner = attributes[.ownerAccountID] as? NSNumber,
                owner.uint64Value > 0, owner.uint64Value < UInt64(UInt32.max)
            {
                return owner.uint32Value
            }
        }
        if let processEffectiveUID {
            guard processEffectiveUID != 0, processEffectiveUID != UInt32.max else {
                throw SandboxRuntimeError.jailIdentityUnavailable(
                    "leaked warm template \(templateId) is running under unusable uid \(processEffectiveUID)")
            }
            return processEffectiveUID
        }
        return try SandboxJailPlan.legacyUID(
            sandboxId: templateId, uidBase: legacyJailerUIDBase)
    }

    func ensureWarmTemplateSweep() async throws {
        if warmTemplateSweepDone { return }
        if let task = warmTemplateSweepTask {
            try await task.value
            return
        }
        let task = Task { try await self.sweepLeakedWarmTemplates() }
        warmTemplateSweepTask = task
        do {
            try await task.value
            warmTemplateSweepDone = true
            warmTemplateSweepTask = nil
        } catch {
            warmTemplateSweepTask = nil
            throw error
        }
    }

    /// Remove template debris a crash mid-build left behind. The recovered UID
    /// is reserved before the socket is touched and released only after process
    /// death is established.
    func sweepLeakedWarmTemplates() async throws {
        for failure in warmCache.removeAbandonedStaging(olderThan: 0) {
            logger.warning(
                "Abandoned warm-template staging cleanup failed; sandbox creation will continue",
                metadata: ["path": .string(failure.path), "error": .string(failure.reason)])
        }
        var leaked: Set<String> = []
        let storageNames = try directoryContentsIfPresent(atPath: sandboxStoragePath)
        leaked.formUnion(storageNames.filter { $0.hasPrefix("warm-template-") })
        let jailBase =
            jailerConfig.chrootBaseDir + "/" + (firecrackerBinaryPath as NSString).lastPathComponent
        let jailNames = try directoryContentsIfPresent(atPath: jailBase)
        leaked.formUnion(jailNames.filter { $0.hasPrefix("warm-template-") })
        let netnsNames = try directoryContentsIfPresent(atPath: SandboxJailPlan.netnsDirectory)
        leaked.formUnion(
            netnsNames.compactMap(SandboxJailPlan.sandboxId(fromNetnsName:))
                .filter { $0.hasPrefix("warm-template-") })

        let processes = try await client.discoverVMProcesses(idPrefix: "warm-template-")
        leaked.formUnion(processes.map(\.vmId))
        var processUIDs: [String: Set<UInt32>] = [:]
        for process in processes {
            guard let effectiveUID = process.effectiveUID else { continue }
            if effectiveUID != 0, effectiveUID != UInt32.max {
                processUIDs[process.vmId, default: []].insert(effectiveUID)
            }
        }
        for templateId in leaked.sorted() {
            logger.warning(
                "Sweeping leaked warm-template artifacts from a previous agent life",
                metadata: ["templateId": .string(templateId)])
            let liveUIDs = processUIDs[templateId, default: []]
            guard liveUIDs.count <= 1 else {
                throw SandboxRuntimeError.jailIdentityUnavailable(
                    "leaked warm template \(templateId) has processes under multiple jail UIDs: "
                        + liveUIDs.sorted().map(String.init).joined(separator: ", "))
            }
            let uid = try recoveredWarmTemplateUID(
                templateId, processEffectiveUID: liveUIDs.first)
            let reservation = jailUIDs.reserve(uid, for: templateId)
            if case .notAssignable = reservation {
                throw SandboxRuntimeError.jailIdentityUnavailable(
                    "leaked warm template \(templateId) records unusable uid 0")
            }
            if case .conflict(let holder) = reservation {
                logger.error(
                    "A leaked warm template shares a sandbox jail UID; keeping the UID poisoned until the template is gone",
                    metadata: [
                        "templateId": .string(templateId),
                        "jailUID": .stringConvertible(uid),
                        "holder": .string(holder),
                    ])
            }
            let plan = try jailPlan(for: templateId, recordedUID: uid)
            try await destroyLeakedWarmTemplateProcess(templateId, plan: plan)
            try removeWarmTemplateArtifacts(templateId, plan: plan)
            _ = jailUIDs.release(templateId)
        }
        let rangeEnd = jailerConfig.uidBase + SandboxJailerConfig.uidCount
        let rangeProcesses = try await client.discoverHostProcesses(
            effectiveUIDsIn: jailerConfig.uidBase..<rangeEnd)
        let unexplained = rangeProcesses.filter { process in
            jailUIDs.holder(of: process.effectiveUID) == nil
        }
        guard unexplained.isEmpty else {
            throw SandboxRuntimeError.jailIdentityUnavailable(
                "configured jail UID range contains unclaimed live process(es): "
                    + unexplained.map { "\($0.pid)@\($0.effectiveUID)" }.joined(separator: ", "))
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

    func destroyLeakedWarmTemplateProcess(
        _ templateId: String, plan: SandboxJailPlan
    ) async throws {
        let socketPath = JailerOptions.socketPath(
            chrootBaseDir: jailerConfig.chrootBaseDir,
            firecrackerBinaryPath: firecrackerBinaryPath,
            vmId: templateId)
        if FileManager.default.fileExists(atPath: socketPath) {
            do {
                _ = try await client.adoptVM(
                    vmId: templateId,
                    jail: JailerOptions(
                        jailerBinaryPath: jailerConfig.jailerBinaryPath,
                        chrootBaseDir: jailerConfig.chrootBaseDir,
                        uid: plan.uid, gid: plan.gid))
                try await client.destroyVM(vmId: templateId)
            } catch {
                logger.warning(
                    "Could not destroy leaked warm template through its API socket; scanning processes",
                    metadata: [
                        "templateId": .string(templateId),
                        "error": .string(error.localizedDescription),
                    ])
            }
        }
        do {
            try await client.destroyUntrackedVM(vmId: templateId)
        } catch {
            throw SandboxRuntimeError.jailSetupFailed(
                "could not prove leaked warm template \(templateId) is gone: "
                    + error.localizedDescription)
        }
        try await client.confirmNoHostProcess(inJailRoot: plan.jailRoot)
        if jailUIDs.isExclusive(plan.uid, to: templateId) {
            try await client.confirmNoHostProcess(effectiveUID: plan.uid)
        }
    }

    func removeWarmTemplateArtifacts(_ templateId: String, plan: SandboxJailPlan) throws {
        try removeItemIfPresent(atPath: plan.jailDirectory)
        let cgroupDirectory = JailerOptions.cgroupDirectory(
            firecrackerBinaryPath: firecrackerBinaryPath, vmId: templateId)
        if rmdir(cgroupDirectory) != 0, errno != ENOENT {
            throw SandboxRuntimeError.jailSetupFailed(
                "could not remove leaked warm-template cgroup \(cgroupDirectory): "
                    + String(cString: strerror(errno)))
        }
        if umount2(plan.netnsPath, Int32(MNT_DETACH)) != 0,
            errno != ENOENT, errno != EINVAL
        {
            throw SandboxRuntimeError.jailSetupFailed(
                "could not unmount leaked warm-template namespace \(plan.netnsPath): "
                    + String(cString: strerror(errno)))
        }
        if unlink(plan.netnsPath) != 0, errno != ENOENT {
            throw SandboxRuntimeError.jailSetupFailed(
                "could not remove leaked warm-template namespace \(plan.netnsPath): "
                    + String(cString: strerror(errno)))
        }
        try removeItemIfPresent(atPath: sandboxDirectory(templateId))
        try removeItemIfPresent(atPath: vsockUDSPath(templateId))
    }

    func removeItemIfPresent(atPath path: String) throws {
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch  where Self.isFileNotFound(error) {
            return
        } catch {
            throw SandboxRuntimeError.jailSetupFailed(
                "could not remove warm-template artifact \(path): "
                    + error.localizedDescription)
        }
    }

    /// Teardown of a template microVM and its staging artifacts.
    /// The jail layout is derived from the template id rather than trusting
    /// `vm`: a provisioning failure leaves `vm` nil with a partially staged
    /// jail, and — template ids being random, never retried — nothing else
    /// would ever clean it this agent life (the leak sweep already ran).
    func teardownWarmTemplate(
        templateId: String, vm: ProvisionedMicroVM?, lease: SandboxJailUIDLease?,
        releaseUID: Bool = true
    ) async throws {
        var trackedDestroyError: (any Error)?
        do {
            try await client.destroyVM(vmId: templateId)
        } catch {
            trackedDestroyError = error
        }
        do {
            try await client.destroyUntrackedVM(vmId: templateId)
        } catch {
            let trackedContext =
                trackedDestroyError.map {
                    " (tracked destroy also failed: \($0.localizedDescription))"
                } ?? ""
            throw SandboxRuntimeError.jailSetupFailed(
                "could not prove warm template \(templateId) is gone: "
                    + error.localizedDescription + trackedContext)
        }

        let plan: SandboxJailPlan
        if let jailedPlan = vm?.jail {
            plan = jailedPlan
        } else if let lease {
            plan = try jailPlan(for: templateId, recordedUID: lease.uid)
        } else if jailUIDs.uid(for: templateId) != nil {
            plan = try jailPlan(for: templateId)
        } else {
            try removeItemIfPresent(atPath: sandboxDirectory(templateId))
            try removeItemIfPresent(atPath: vsockUDSPath(templateId))
            return
        }
        try await client.confirmNoHostProcess(inJailRoot: plan.jailRoot)
        if jailUIDs.isExclusive(plan.uid, to: templateId) {
            try await client.confirmNoHostProcess(effectiveUID: plan.uid)
        }
        try removeWarmTemplateArtifacts(templateId, plan: plan)
        if releaseUID {
            if let lease {
                jailUIDs.rollBack(lease)
            } else {
                _ = jailUIDs.release(templateId)
            }
        }
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
