import Foundation
import Logging
import StratoAgentCore
import StratoShared

#if os(Linux)
import SwiftFirecracker

/// The concrete sandbox runtime (issue #421): OCI-image Firecracker microVMs.
///
/// A sandbox is a Firecracker microVM booted from the maintained guest kernel +
/// initramfs (issue #419), with the flattened container image (issue #418)
/// attached as its root disk and a small config drive telling the guest init
/// what to run. The host reaches the in-guest control agent over vsock (issue
/// #420) for health and exit-code reporting.
///
/// **Shares Firecracker process management with `FirecrackerService`.** Both are
/// handed the same `FirecrackerClient` by the `Agent`, so process spawning,
/// socket-directory layout, and re-adoption (issue #433) live in one place;
/// sandbox IDs and VM IDs are distinct UUIDs, so they never collide in the
/// shared process registry. Resource reservation is likewise shared at a higher
/// level: the `Agent` accounts for sandbox vCPU/memory straight from the
/// manifest, so this runtime intentionally exposes no `reservedResources()`.
///
/// **Lifecycle model.** A non-deleted sandbox always has a live Firecracker
/// process (Firecracker has no stop-that-keeps-state), so the states map onto
/// the microVM as: created ⇒ `Not started`, running ⇒ `Running`, stopped ⇒
/// `Paused`. Booting starts or resumes; stopping pauses; deleting tears the
/// process down. Keeping the process alive means NIC and vsock wiring are
/// configured exactly once (at create) and re-adoption after an agent restart
/// is uniform. A stopped sandbox therefore still holds its reserved memory —
/// consistent with the manifest-based, state-independent reservation model.
/// Cold-boot stop (releasing memory) is future work.
actor FirecrackerSandboxRuntime: SandboxRuntimeService {
    private let logger: Logger
    private let client: FirecrackerClient
    private let imageService: SandboxImageService
    private let socketDirectory: String
    private let sandboxStoragePath: String
    private let guestImagePath: String

    /// Guest context ID for the single vsock device. CIDs 0–2 are reserved, so
    /// 3 is the first usable guest CID.
    private static let guestCID: UInt32 = 3

    /// Everything the runtime tracks for one managed sandbox.
    private struct Managed {
        let spec: SandboxSpec
        /// Per-sandbox writable ext4 copy of the flattened image (the shared
        /// cache entry stays pristine and read-only).
        let rootfsPath: String
        /// The staged config block image.
        let configPath: String
        /// Host UDS backing the vsock device for host→guest control traffic.
        let vsockUdsPath: String
        /// The boot nonce stamped into the config drive, echoed by the guest.
        let identityNonce: String
        /// The live Firecracker session, present for the sandbox's whole life.
        var manager: FirecrackerManager
        /// The workload's exit code once it has ended, cached so it survives a
        /// guest that later stops answering.
        var lastExitCode: Int?
    }

    private var sandboxes: [String: Managed] = [:]

    init(
        logger: Logger,
        client: FirecrackerClient,
        imageService: SandboxImageService,
        socketDirectory: String,
        sandboxStoragePath: String,
        guestImagePath: String
    ) {
        self.logger = logger
        self.client = client
        self.imageService = imageService
        self.socketDirectory = socketDirectory
        self.sandboxStoragePath = sandboxStoragePath
        self.guestImagePath = guestImagePath

        logger.info(
            "Sandbox runtime initialized",
            metadata: [
                "socketDirectory": .string(socketDirectory),
                "guestImagePath": .string(guestImagePath),
            ])
    }

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

        // v1 has no in-guest networking: the guest init mounts the rootfs and
        // execs the workload without bringing up eth0 or DHCP, and the guest
        // kernel has no IP autoconfiguration. Attaching a TAP would leave the
        // workload with an unconfigured interface while the sandbox reported
        // running, so reject networked specs rather than mis-converging. (The
        // scheduler/IPAM path exists — #415/#416 — but the guest cannot yet use
        // it; enabling it is a guest-image change.)
        guard spec.network == nil, networkAttachments.isEmpty else {
            throw SandboxRuntimeError.networkingUnsupported
        }

        logger.info(
            "Creating sandbox",
            metadata: ["sandboxId": .string(sandboxId), "image": .string(spec.image)])

        let guestImage = try SandboxGuestImage.resolve(atDirectory: guestImagePath)

        // Materialize the flattened container rootfs (cache-owned, read-only),
        // then copy it to a per-sandbox writable image — container semantics
        // give the workload a writable root, and the cache entry must never be
        // written. (An overlay would avoid the copy; that is future work.)
        let materialized = try await imageService.materializeRootfs(
            image: spec.image, imageDigest: spec.imageDigest, credential: registryCredential)

        let dir = sandboxDirectory(sandboxId)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let rootfsPath = dir + "/rootfs.ext4"
        if FileManager.default.fileExists(atPath: rootfsPath) {
            try FileManager.default.removeItem(atPath: rootfsPath)
        }
        try FileManager.default.copyItem(atPath: materialized.rootfsPath, toPath: rootfsPath)

        // Stage the config drive the guest init reads at boot.
        let nonce = UUID().uuidString
        let configDrive = SandboxConfigDrive(
            sandboxId: sandboxId, identityNonce: nonce,
            guestConfig: materialized.guestConfig, spec: spec)
        let configPath = dir + "/config.img"
        try configDrive.blockImage().write(to: URL(fileURLWithPath: configPath))

        let vsockUdsPath = vsockUDSPath(sandboxId)

        // Spawn and fully configure the Firecracker microVM, leaving it in
        // `Not started` (== stopped). Roll the process back on any configuration
        // failure so a retry starts from a clean slate rather than
        // `vmAlreadyRunning`.
        let manager = try await client.createVM(vmId: sandboxId)
        do {
            try await manager.configureMachine(
                MachineConfig(
                    vcpuCount: spec.cpus,
                    memSizeMib: Int(spec.memoryBytes / (1024 * 1024))))

            let bootSource = SwiftFirecracker.BootSource(
                kernelImagePath: guestImage.kernelPath,
                initrdPath: guestImage.initramfsPath,
                bootArgs: guestImage.bootArgs + " strato.config=/dev/vdb")
            try await manager.configureBootSource(bootSource)

            // Drive order fixes device naming: rootfs first ⇒ /dev/vda (what the
            // config drive names), config second ⇒ /dev/vdb (what the guest
            // reads by default).
            try await manager.configureDrive(
                Drive.rootDrive(id: "rootfs", path: rootfsPath, readOnly: false))
            try await manager.configureDrive(
                Drive.dataDrive(id: "config", path: configPath, readOnly: true))

            // No network interface: networked specs are rejected above until the
            // guest image can configure one.

            try await manager.configureVsock(
                VsockConfig(guestCid: Self.guestCID, udsPath: vsockUdsPath))
        } catch {
            try? await client.destroyVM(vmId: sandboxId)
            throw error
        }

        sandboxes[sandboxId] = Managed(
            spec: spec, rootfsPath: rootfsPath, configPath: configPath,
            vsockUdsPath: vsockUdsPath, identityNonce: nonce, manager: manager, lastExitCode: nil)

        logger.info("Sandbox created", metadata: ["sandboxId": .string(sandboxId)])
    }

    func bootSandbox(sandboxId: String) async throws {
        guard let managed = sandboxes[sandboxId] else {
            throw SandboxRuntimeError.sandboxNotFound(sandboxId)
        }

        let info = try await managed.manager.getInstanceInfo()
        switch info.state {
        case .running:
            break  // already running — idempotent
        case .notStarted:
            logger.info("Booting sandbox", metadata: ["sandboxId": .string(sandboxId)])
            try await managed.manager.start()
        case .paused:
            logger.info("Resuming sandbox", metadata: ["sandboxId": .string(sandboxId)])
            try await managed.manager.resume()
        }

        // Wait for the guest control agent to answer, so "booted" means the
        // guest is actually up. A miss here is transient — the reconciler
        // re-drives boot on the next sync.
        let response = try await sendControl(.ping, udsPath: managed.vsockUdsPath, timeout: 20)
        guard case .pong(let echoedId, let echoedNonce) = response else {
            throw SandboxControlError.malformedResponse("expected pong, got \(response)")
        }
        // Confirm it is this sandbox's current generation answering, not a stale
        // process still bound to the deterministic vsock UDS.
        guard identityMatches(response, sandboxId: sandboxId, expectedNonce: managed.identityNonce) else {
            throw SandboxControlError.identityMismatch(
                expected: "\(sandboxId)/\(managed.identityNonce)", got: "\(echoedId)/\(echoedNonce)")
        }
        logger.info("Sandbox guest agent healthy", metadata: ["sandboxId": .string(sandboxId)])
    }

    func shutdownSandbox(sandboxId: String) async throws {
        guard let managed = sandboxes[sandboxId] else {
            throw SandboxRuntimeError.sandboxNotFound(sandboxId)
        }
        // Firecracker cannot stop-and-keep-state, so a "stopped" sandbox is a
        // paused microVM. Only a running one needs pausing; a not-started or
        // already-paused sandbox is idempotently satisfied.
        let info = try await managed.manager.getInstanceInfo()
        if info.state == .running {
            logger.info("Stopping sandbox", metadata: ["sandboxId": .string(sandboxId)])
            try await managed.manager.pause()
        }
    }

    func deleteSandbox(sandboxId: String) async throws {
        logger.info("Deleting sandbox", metadata: ["sandboxId": .string(sandboxId)])
        // Tear the Firecracker process down (idempotent — a sandbox whose
        // process the client no longer tracks throws, which we ignore), then
        // remove the per-sandbox artifacts.
        try? await client.destroyVM(vmId: sandboxId)
        removeArtifacts(sandboxId)
        sandboxes.removeValue(forKey: sandboxId)
    }

    func adoptSandbox(sandboxId: String, spec: SandboxSpec) async throws -> SandboxStatus {
        if sandboxes[sandboxId] != nil {
            // A replayed sync can race adoption; if already managed, adoption is
            // satisfied — just report the current status.
            return try await getSandboxStatus(sandboxId: sandboxId)
        }

        let socketPath = FirecrackerClient.socketPath(socketDirectory: socketDirectory, vmId: sandboxId)
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw SandboxRuntimeError.adoptionTargetGone(
                "sandbox \(sandboxId) has no Firecracker API socket at \(socketPath)")
        }

        logger.info(
            "Re-adopting orphaned sandbox",
            metadata: ["sandboxId": .string(sandboxId), "socket": .string(socketPath)])

        let manager: FirecrackerManager
        let info: InstanceInfo
        do {
            (manager, info) = try await client.adoptVM(vmId: sandboxId)
        } catch {
            // A live Firecracker always answers its API socket, so a failed
            // connect means the process is gone and the socket merely outlived
            // it. The Agent re-creates from the desired entry in that case.
            throw SandboxRuntimeError.adoptionTargetGone(
                "sandbox \(sandboxId) Firecracker API socket at \(socketPath) is dead: \(error.localizedDescription)"
            )
        }

        let dir = sandboxDirectory(sandboxId)
        // Recover the boot nonce from the staged config drive so post-adoption
        // identity checks can still distinguish this generation.
        let identityNonce = recoverIdentityNonce(sandboxId: sandboxId)
        sandboxes[sandboxId] = Managed(
            spec: spec, rootfsPath: dir + "/rootfs.ext4", configPath: dir + "/config.img",
            vsockUdsPath: vsockUDSPath(sandboxId), identityNonce: identityNonce, manager: manager,
            lastExitCode: nil)

        let status = await mappedStatus(
            instance: info.state, udsPath: vsockUDSPath(sandboxId), sandboxId: sandboxId)
        logger.info(
            "Sandbox re-adopted",
            metadata: ["sandboxId": .string(sandboxId), "status": .string(status.rawValue)])
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

    // MARK: - Status mapping

    /// Fold the Firecracker instance state and (when running) the guest agent's
    /// workload state into the observed `SandboxStatus`.
    private func mappedStatus(
        instance: InstanceState, udsPath: String, sandboxId: String
    ) async -> SandboxStatus {
        switch instance {
        case .notStarted:
            return .stopped
        case .paused:
            // A control-plane stop; a workload that had already exited is
            // remembered as such.
            return sandboxes[sandboxId]?.lastExitCode != nil ? .exited : .stopped
        case .running:
            do {
                let response = try await sendControl(.getStatus, udsPath: udsPath, timeout: 5)
                guard case .status(_, _, let state, let exitCode) = response else {
                    return .starting
                }
                // Ignore a response from a stale generation still bound to the
                // deterministic UDS rather than reporting another sandbox's
                // status/exit code and advancing convergence on it.
                let expectedNonce = sandboxes[sandboxId]?.identityNonce ?? ""
                guard identityMatches(response, sandboxId: sandboxId, expectedNonce: expectedNonce) else {
                    logger.warning(
                        "Ignoring sandbox control status from a mismatched guest identity",
                        metadata: ["sandboxId": .string(sandboxId)])
                    return .unknown
                }
                switch state {
                case .starting:
                    return .starting
                case .running:
                    return .running
                case .exited:
                    if let exitCode {
                        sandboxes[sandboxId]?.lastExitCode = exitCode
                    }
                    return .exited
                }
            } catch {
                // The microVM is up but the guest agent isn't answering yet
                // (still booting) or is momentarily busy — still converging.
                return .starting
            }
        }
    }

    // MARK: - Guest control channel

    /// Open a fresh vsock connection, send one control request, and read the
    /// single newline-delimited JSON response. Stateless per call: the guest
    /// serve loop accepts many short-lived connections, and re-opening avoids
    /// stale file descriptors across polls.
    ///
    /// The read phase is bounded by racing it against a timeout: `VsockConnection.read`
    /// wraps a blocking `read(2)`, so a guest that accepts the connection but
    /// then wedges before sending a full line would otherwise block forever.
    /// When the deadline wins, closing the socket aborts the in-flight blocking
    /// read, so the poll actually returns.
    private func sendControl(
        _ request: SandboxControlProtocol.Request, udsPath: String, timeout: TimeInterval
    ) async throws -> SandboxControlProtocol.Response {
        let connection = try await VsockConnection.connect(
            udsPath: udsPath, port: SandboxConfigDrive.defaultVsockPort, timeout: timeout, logger: logger)

        return try await withThrowingTaskGroup(of: SandboxControlProtocol.Response.self) { group in
            group.addTask { try await Self.exchange(request, on: connection) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                // Deadline hit: close the socket so any blocking read the other
                // task is parked in returns instead of hanging.
                await connection.close()
                throw SandboxControlError.timeout
            }
            defer { group.cancelAll() }
            do {
                let response = try await group.next()!
                await connection.close()
                return response
            } catch {
                await connection.close()
                throw error
            }
        }
    }

    /// Write one request and read the single newline-delimited response. A
    /// `static` (non-isolated) helper so it runs off the actor and its blocking
    /// read can be raced against a timeout (see `sendControl`).
    private static func exchange(
        _ request: SandboxControlProtocol.Request, on connection: VsockConnection
    ) async throws -> SandboxControlProtocol.Response {
        try await connection.write(request.encodedLine())

        var buffer = Data()
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                let response = try SandboxControlProtocol.Response.decode(line: line)
                if case .error(let message) = response {
                    throw SandboxControlError.guestError(message)
                }
                return response
            }
            let chunk = try await connection.read(maxLength: 4096)
            if chunk.isEmpty {
                throw SandboxControlError.malformedResponse("guest closed before sending a full response line")
            }
            buffer.append(chunk)
        }
    }

    /// Confirm a control response echoes this sandbox's identity, so a stale
    /// generation still serving the deterministic vsock UDS (a leaked process, a
    /// pre-adoption resume) cannot be mistaken for the current one. The nonce is
    /// checked when known; an empty expected nonce (not yet recovered) falls
    /// back to the id alone.
    private func identityMatches(
        _ response: SandboxControlProtocol.Response, sandboxId: String, expectedNonce: String
    ) -> Bool {
        let echoedId: String
        let echoedNonce: String
        switch response {
        case .pong(let id, let nonce):
            (echoedId, echoedNonce) = (id, nonce)
        case .status(let id, let nonce, _, _):
            (echoedId, echoedNonce) = (id, nonce)
        case .error:
            return false
        }
        guard echoedId == sandboxId else { return false }
        if !expectedNonce.isEmpty, echoedNonce != expectedNonce { return false }
        return true
    }

    /// Read the boot nonce back from a sandbox's staged config drive. Empty when
    /// the drive is missing or unreadable, in which case identity checks fall
    /// back to the sandbox id alone.
    private func recoverIdentityNonce(sandboxId: String) -> String {
        let configPath = sandboxDirectory(sandboxId) + "/config.img"
        guard let data = FileManager.default.contents(atPath: configPath),
            let drive = try? SandboxConfigDrive.decode(fromBlockImage: data)
        else {
            return ""
        }
        return drive.identityNonce
    }

    // MARK: - Paths

    private func sandboxDirectory(_ sandboxId: String) -> String {
        sandboxStoragePath + "/" + sandboxId
    }

    private func vsockUDSPath(_ sandboxId: String) -> String {
        socketDirectory + "/" + sandboxId + ".vsock"
    }

    private func removeArtifacts(_ sandboxId: String) {
        try? FileManager.default.removeItem(atPath: sandboxDirectory(sandboxId))
    }
}

#else

/// Stub sandbox runtime for non-Linux platforms. Sandboxes are Firecracker/KVM
/// workloads (Linux only); the `Agent` never constructs this off Linux, but the
/// type must exist so `StratoAgent` compiles everywhere.
actor FirecrackerSandboxRuntime: SandboxRuntimeService {
    init(
        logger: Logger,
        socketDirectory: String,
        sandboxStoragePath: String,
        guestImagePath: String
    ) {
        // No-op: never constructed on non-Linux hosts.
    }

    func createSandbox(
        sandboxId: String, spec: SandboxSpec, registryCredential: RegistryCredential?,
        networkAttachments: [ResolvedNetworkAttachment]
    ) async throws {
        throw HypervisorServiceError.notSupported("sandboxes are only available on Linux")
    }

    func bootSandbox(sandboxId: String) async throws {
        throw HypervisorServiceError.notSupported("sandboxes are only available on Linux")
    }

    func shutdownSandbox(sandboxId: String) async throws {
        throw HypervisorServiceError.notSupported("sandboxes are only available on Linux")
    }

    func deleteSandbox(sandboxId: String) async throws {
        throw HypervisorServiceError.notSupported("sandboxes are only available on Linux")
    }

    func adoptSandbox(sandboxId: String, spec: SandboxSpec) async throws -> SandboxStatus {
        throw HypervisorServiceError.notSupported("sandboxes are only available on Linux")
    }

    func getSandboxStatus(sandboxId: String) async throws -> SandboxStatus {
        throw HypervisorServiceError.notSupported("sandboxes are only available on Linux")
    }

    func exitCode(sandboxId: String) async -> Int? {
        nil
    }
}
#endif
