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
        /// Bumped whenever this sandbox's exec sessions are swept (stop or
        /// delete). `startExec` snapshots it before its awaits and re-checks
        /// after, so a session whose handshake raced a sweep is refused
        /// instead of being registered against a stopped sandbox (where it
        /// would never receive a terminal event).
        var execSweepEpoch: UInt64 = 0
    }

    private var sandboxes: [String: Managed] = [:]

    // MARK: Exec/log state (issue #423)

    /// One live exec session: a dedicated guest connection plus the detached
    /// reader task draining its output. Keyed by the control plane's
    /// sessionId in `execSessions`; `sandboxId` lets a sandbox teardown find
    /// its sessions.
    private struct ExecSession {
        let sandboxId: String
        let connection: VsockConnection
        let events: @Sendable (SandboxExecEvent) -> Void
        var reader: Task<Void, Never>?
    }

    private var execSessions: [String: ExecSession] = [:]

    /// Per-sandbox log follow state. The entry outlives individual follow
    /// tasks (shutdown stops the task, boot starts a new one) so `lastSeq`
    /// resumes delivery where it left off and a partial line buffered in
    /// `assembler` is completed rather than split across a pause.
    private struct LogFollow {
        /// Monotonic ownership token: every (re)started follow task gets a
        /// fresh generation, and only the current generation may register a
        /// connection or record records — a superseded loop that limps past
        /// its cancellation cannot corrupt its successor's state.
        var generation: UInt64
        var task: Task<Void, Never>?
        /// The loop's live connection, registered so a stop can close it and
        /// unblock the loop's blocking read.
        var connection: VsockConnection?
        /// Highest ring-buffer seq recorded; the next connect resumes at
        /// `lastSeq + 1`.
        var lastSeq: UInt64
        var assembler: SandboxLogLineAssembler
    }

    private var logFollows: [String: LogFollow] = [:]
    private var logHandler: (@Sendable (String, String, String) -> Void)?

    /// Wall-clock budget for opening an exec/log connection and for the exec
    /// spawn handshake.
    private static let execConnectTimeout: TimeInterval = 10

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

        // The guest is confirmed up: ship its workload output from here on
        // (resuming from the last seq this host saw, so a pause/resume cycle
        // doesn't drop or duplicate lines).
        startLogFollow(sandboxId: sandboxId)
    }

    func shutdownSandbox(sandboxId: String) async throws {
        guard let managed = sandboxes[sandboxId] else {
            throw SandboxRuntimeError.sandboxNotFound(sandboxId)
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
            logger.info("Stopping sandbox", metadata: ["sandboxId": .string(sandboxId)])
            try await managed.manager.pause()
        }
    }

    func deleteSandbox(sandboxId: String) async throws {
        logger.info("Deleting sandbox", metadata: ["sandboxId": .string(sandboxId)])
        // End interactive/log streams first: the guest is about to disappear,
        // and their control-plane sessions must learn why. Deleting is the
        // true end-of-stream for the workload's logs, so flush any partial
        // line the assembler is holding.
        await closeExecSessions(sandboxId: sandboxId, reason: "sandbox deleted")
        await stopLogFollow(sandboxId: sandboxId, retire: true)
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
        if info.state == .running {
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

    // MARK: - Exec sessions (issue #423)

    func startExec(
        sandboxId: String,
        sessionId: String,
        request: SandboxExecRequest,
        events: @escaping @Sendable (SandboxExecEvent) -> Void
    ) async throws {
        guard let managed = sandboxes[sandboxId] else {
            throw SandboxRuntimeError.sandboxNotFound(sandboxId)
        }
        guard execSessions[sessionId] == nil else {
            // Session ids are minted per attach by the control plane; a
            // duplicate start is a stream replay we must not double-bridge.
            return
        }

        logger.info(
            "Starting sandbox exec session",
            metadata: [
                "sandboxId": .string(sandboxId),
                "sessionId": .string(sessionId),
                "tty": .stringConvertible(request.tty),
            ])

        // Snapshot the sweep epoch before suspending: a concurrent stop or
        // delete sweeps `execSessions` while this session is still mid-
        // handshake and would miss it.
        let sweepEpoch = managed.execSweepEpoch

        // A dedicated connection per session: its first line (`exec`) turns it
        // into the session's channel, and closing it later kills the exec
        // process group guest-side.
        let connection = try await VsockConnection.connect(
            udsPath: managed.vsockUdsPath, port: SandboxConfigDrive.defaultVsockPort,
            timeout: Self.execConnectTimeout, logger: logger)

        // Wait (bounded) for the guest to confirm the spawn. Bytes the guest
        // sent after `exec_started` in the same chunk are handed to the reader
        // so no early output is lost.
        let leftover: Data
        do {
            leftover = try await Self.withConnectionDeadline(connection, timeout: Self.execConnectTimeout) {
                try await Self.awaitExecStarted(.exec(request.guestRequest), on: connection)
            }
        } catch {
            await connection.close()
            throw error
        }

        // Back on the actor: re-check that no teardown raced the awaits above.
        // If the sandbox was deleted, or a stop/delete swept its exec sessions
        // (epoch bumped) before this one was registered, registering now would
        // bind the session to a stopped/deleted sandbox that can never deliver
        // a terminal event — refuse instead; the thrown error becomes the
        // control plane's `sandboxExecClosed`.
        guard let current = sandboxes[sandboxId], current.execSweepEpoch == sweepEpoch else {
            await connection.close()
            throw SandboxRuntimeError.sandboxNotFound(
                "\(sandboxId) (stopped or deleted while the exec session was starting)")
        }

        // Confirmed: report `.started` before any output, then drain the
        // session on a detached reader (its reads block between output chunks,
        // which must never park the actor).
        events(.started)
        var session = ExecSession(sandboxId: sandboxId, connection: connection, events: events, reader: nil)
        session.reader = Task.detached { [weak self, logger] in
            await Self.runExecReader(
                sessionId: sessionId, connection: connection, initial: leftover,
                events: events, runtime: self, logger: logger)
        }
        execSessions[sessionId] = session
    }

    func sendExecInput(sessionId: String, data: Data?, eof: Bool) async throws {
        guard let session = execSessions[sessionId] else {
            throw SandboxRuntimeError.execSessionNotFound(sessionId)
        }
        if let data, !data.isEmpty {
            try await session.connection.write(SandboxControlProtocol.Request.stdin(data).encodedLine())
        }
        if eof {
            try await session.connection.write(SandboxControlProtocol.Request.stdinEof.encodedLine())
        }
    }

    func resizeExec(sessionId: String, rows: Int, cols: Int) async throws {
        guard let session = execSessions[sessionId] else {
            throw SandboxRuntimeError.execSessionNotFound(sessionId)
        }
        try await session.connection.write(
            SandboxControlProtocol.Request.resize(rows: rows, cols: cols).encodedLine())
    }

    func closeExec(sessionId: String) async {
        guard let session = execSessions.removeValue(forKey: sessionId) else { return }
        logger.info(
            "Closing sandbox exec session",
            metadata: ["sandboxId": .string(session.sandboxId), "sessionId": .string(sessionId)])
        // Closing the connection kills the exec process group guest-side and
        // unblocks the reader, whose end-of-session callback finds the session
        // already deregistered and stays silent — the closer needs no event.
        await session.connection.close()
        session.reader?.cancel()
    }

    /// Terminal teardown of every live exec session of one sandbox (stop or
    /// delete): each session's control-plane side gets a `.closed` with the
    /// reason. Bumps the sandbox's sweep epoch so a `startExec` still awaiting
    /// its handshake refuses to register a session this sweep could not see.
    private func closeExecSessions(sandboxId: String, reason: String) async {
        sandboxes[sandboxId]?.execSweepEpoch += 1
        for (sessionId, session) in execSessions where session.sandboxId == sandboxId {
            execSessions.removeValue(forKey: sessionId)
            await session.connection.close()
            session.reader?.cancel()
            session.events(.closed(reason: reason))
        }
    }

    /// The reader's end-of-session callback: emits the terminal event unless
    /// the session was already deregistered (an explicit `closeExec` or a
    /// sandbox teardown, which speak for themselves).
    private func execSessionEnded(sessionId: String, terminal: SandboxExecEvent) async {
        guard let session = execSessions.removeValue(forKey: sessionId) else { return }
        await session.connection.close()
        logger.info(
            "Sandbox exec session ended",
            metadata: [
                "sandboxId": .string(session.sandboxId),
                "sessionId": .string(sessionId),
                "terminal": .string(String(describing: terminal)),
            ])
        session.events(terminal)
    }

    /// Write the `exec` line and read until the guest confirms `exec_started`.
    /// Returns any bytes read past the confirmation line (early output for the
    /// reader). A guest `error` line (spawn failure) throws.
    private static func awaitExecStarted(
        _ request: SandboxControlProtocol.Request, on connection: VsockConnection
    ) async throws -> Data {
        try await connection.write(request.encodedLine())

        var reader = VsockLineReader(readSize: 4096)
        guard let line = try await reader.nextLine(on: connection) else {
            throw SandboxControlError.malformedResponse("guest closed before confirming exec start")
        }
        let response = try SandboxControlProtocol.Response.decode(line: line)
        if case .error(let message) = response {
            throw SandboxControlError.guestError(message)
        }
        guard case .execStarted = response else {
            throw SandboxControlError.malformedResponse("expected exec_started, got \(response)")
        }
        return reader.leftover
    }

    /// Drains one exec session's connection for its whole life: decodes
    /// `output` records into `.output` events and finishes the session on
    /// `exec_exit`, a guest `error`, or the channel dying. Runs detached — the
    /// reads block between output chunks (fine off-actor: they park on
    /// `DispatchQueue.global()`, not the cooperative pool).
    private static func runExecReader(
        sessionId: String,
        connection: VsockConnection,
        initial: Data,
        events: @escaping @Sendable (SandboxExecEvent) -> Void,
        runtime: FirecrackerSandboxRuntime?,
        logger: Logger
    ) async {
        var reader = VsockLineReader(initial: initial, readSize: 65536)

        func finish(_ terminal: SandboxExecEvent) async {
            await runtime?.execSessionEnded(sessionId: sessionId, terminal: terminal)
        }

        while true {
            let line: String?
            do {
                line = try await reader.nextLine(on: connection)
            } catch {
                // A read failure on a session we tore down ourselves is the
                // expected wakeup; `execSessionEnded` stays silent then.
                await finish(.closed(reason: "sandbox exec channel failed: \(error.localizedDescription)"))
                return
            }
            guard let line else {
                await finish(.closed(reason: "sandbox exec channel closed"))
                return
            }

            let response: SandboxControlProtocol.Response
            do {
                response = try SandboxControlProtocol.Response.decode(line: line)
            } catch {
                await finish(.closed(reason: "malformed exec record from guest"))
                return
            }
            switch response {
            case .output(let stream, let data):
                events(.output(stream: stream, data: data))
            case .execExit(let exitCode):
                await finish(.exited(code: exitCode))
                return
            case .error(let message):
                await finish(.closed(reason: "guest error: \(message)"))
                return
            default:
                await finish(.closed(reason: "unexpected exec record from guest"))
                return
            }
        }
    }

    // MARK: - Control-plane connectivity (issue #423)

    func controlPlaneDisconnected() async {
        // Exec sessions: their frontends are unreachable and the control plane
        // cannot send sandboxExecClose over the dead socket. Closing the guest
        // connections kills the exec process groups; the .closed events this
        // emits are dropped by the (dead) send path, which is fine — the
        // control plane tears its side down in its own agent-close handler.
        let sandboxIds = Set(execSessions.values.map(\.sandboxId))
        for sandboxId in sandboxIds {
            await closeExecSessions(sandboxId: sandboxId, reason: "control plane disconnected")
        }

        // Log follows: suspend, keeping seq/partial-line state. Output the
        // workload produces during the gap stays in the guest ring buffer for
        // the resumed follow; only records consumed in the instant before the
        // drop was noticed can be lost (the delivery path has no acks).
        for sandboxId in Array(logFollows.keys) {
            await stopLogFollow(sandboxId: sandboxId, retire: false)
        }
    }

    func controlPlaneConnected() async {
        for (sandboxId, managed) in sandboxes {
            guard let info = try? await managed.manager.getInstanceInfo(), info.state == .running else {
                continue
            }
            startLogFollow(sandboxId: sandboxId)
        }
    }

    // MARK: - Workload log shipping (issue #423)

    func setSandboxLogHandler(_ handler: @escaping @Sendable (String, String, String) -> Void) async {
        logHandler = handler
    }

    /// Start (or restart) the sandbox's log follow loop. Idempotent while a
    /// loop is live; seq/partial-line state carries over from a previous loop
    /// so delivery resumes without loss or duplication.
    private func startLogFollow(sandboxId: String) {
        guard logHandler != nil else { return }
        guard let managed = sandboxes[sandboxId] else { return }
        if logFollows[sandboxId]?.task != nil { return }

        var follow =
            logFollows[sandboxId]
            ?? LogFollow(generation: 0, task: nil, connection: nil, lastSeq: 0, assembler: SandboxLogLineAssembler())
        follow.generation += 1
        let generation = follow.generation
        let udsPath = managed.vsockUdsPath

        logger.debug(
            "Starting sandbox log follow",
            metadata: ["sandboxId": .string(sandboxId), "sinceSeq": .stringConvertible(follow.lastSeq + 1)])

        follow.task = Task.detached { [weak self, logger] in
            await Self.runLogFollowLoop(
                sandboxId: sandboxId, generation: generation, udsPath: udsPath,
                runtime: self, logger: logger)
        }
        logFollows[sandboxId] = follow
    }

    /// Stop the sandbox's log follow loop. `retire: true` (delete) is the
    /// workload's end-of-stream: any buffered partial line is flushed and the
    /// state dropped; `retire: false` (stop/pause) keeps seq and partial-line
    /// state for the next boot.
    private func stopLogFollow(sandboxId: String, retire: Bool) async {
        guard var follow = logFollows[sandboxId] else { return }
        // Bump the generation so a loop iteration already past its
        // cancellation check can no longer register connections or records.
        follow.generation += 1
        follow.task?.cancel()
        follow.task = nil
        if let connection = follow.connection {
            // Unblocks the loop's in-flight blocking read.
            await connection.close()
            follow.connection = nil
        }
        if retire {
            logFollows.removeValue(forKey: sandboxId)
            for line in follow.assembler.flush() {
                logHandler?(sandboxId, line.stream, line.text)
            }
        } else {
            logFollows[sandboxId] = follow
        }
    }

    /// The follow loop's per-connect checkpoint: the seq to resume from, or
    /// nil once this loop generation has been superseded or retired.
    private func logFollowSinceSeq(sandboxId: String, generation: UInt64) -> UInt64? {
        guard let follow = logFollows[sandboxId], follow.generation == generation else { return nil }
        return follow.lastSeq + 1
    }

    /// Adopt `connection` as the follow loop's live connection so a stop can
    /// close it. Returns false when the loop generation was superseded — the
    /// caller must close the connection and exit.
    private func registerLogConnection(
        sandboxId: String, generation: UInt64, connection: VsockConnection
    ) -> Bool {
        guard var follow = logFollows[sandboxId], follow.generation == generation else { return false }
        follow.connection = connection
        logFollows[sandboxId] = follow
        return true
    }

    private func unregisterLogConnection(sandboxId: String, generation: UInt64) {
        guard var follow = logFollows[sandboxId], follow.generation == generation else { return }
        follow.connection = nil
        logFollows[sandboxId] = follow
    }

    /// Record one ring-buffer record: advance the resume seq, feed the line
    /// assembler, and hand every completed line to the log handler (in order —
    /// the follow loop awaits each record, so this runs sequentially).
    private func recordLog(
        sandboxId: String, generation: UInt64, seq: UInt64, stream: String, data: Data
    ) {
        guard var follow = logFollows[sandboxId], follow.generation == generation else { return }
        follow.lastSeq = max(follow.lastSeq, seq)
        let lines = follow.assembler.append(stream: stream, data: data)
        logFollows[sandboxId] = follow
        for line in lines {
            logHandler?(sandboxId, line.stream, line.text)
        }
    }

    /// The guest reported log end-of-stream (`log_eof`): every workload stdio
    /// pipe hit EOF and every retained record was delivered. Flush a partial
    /// final line now (output that ended without a trailing newline would
    /// otherwise be held until delete), but keep the seq checkpoint — a later
    /// boot's follow reconnects, is told EOF again, and ends just as quietly,
    /// without replaying records as duplicates.
    private func finishLogFollow(sandboxId: String, generation: UInt64) {
        guard var follow = logFollows[sandboxId], follow.generation == generation else { return }
        follow.task = nil
        follow.connection = nil
        let lines = follow.assembler.flush()
        logFollows[sandboxId] = follow
        for line in lines {
            logHandler?(sandboxId, line.stream, line.text)
        }
    }

    /// The long-lived follow loop for one sandbox: connect, send
    /// `stream_logs` resuming after the last recorded seq, and feed records to
    /// the actor until the connection dies; then reconnect with 1s..30s
    /// exponential backoff for as long as the loop generation stays current.
    /// A paused sandbox surfaces as connect timeouts, so the loop idles at the
    /// backoff cap instead of spinning. Runs detached: the follow read blocks
    /// indefinitely between records, which is fine off-actor.
    private static func runLogFollowLoop(
        sandboxId: String,
        generation: UInt64,
        udsPath: String,
        runtime: FirecrackerSandboxRuntime?,
        logger: Logger
    ) async {
        var backoff: TimeInterval = 1

        while !Task.isCancelled {
            guard let runtime else { return }
            guard let sinceSeq = await runtime.logFollowSinceSeq(sandboxId: sandboxId, generation: generation)
            else { return }

            do {
                let connection = try await VsockConnection.connect(
                    udsPath: udsPath, port: SandboxConfigDrive.defaultVsockPort,
                    timeout: execConnectTimeout, logger: logger)
                guard
                    await runtime.registerLogConnection(
                        sandboxId: sandboxId, generation: generation, connection: connection)
                else {
                    await connection.close()
                    return
                }

                var streamComplete = false
                do {
                    try await connection.write(
                        SandboxControlProtocol.Request.streamLogs(sinceSeq: sinceSeq).encodedLine())
                    streamComplete = try await Self.followLogStream(
                        sandboxId: sandboxId, generation: generation, connection: connection,
                        runtime: runtime, backoff: &backoff)
                } catch {
                    logger.debug(
                        "Sandbox log follow stream ended",
                        metadata: [
                            "sandboxId": .string(sandboxId),
                            "error": .string(error.localizedDescription),
                        ])
                }
                await runtime.unregisterLogConnection(sandboxId: sandboxId, generation: generation)
                await connection.close()
                if streamComplete {
                    // The guest declared end-of-stream: nothing will ever
                    // arrive again, so the loop ends instead of reconnecting.
                    return
                }
            } catch {
                logger.debug(
                    "Sandbox log follow connect failed",
                    metadata: [
                        "sandboxId": .string(sandboxId),
                        "error": .string(error.localizedDescription),
                    ])
            }

            if Task.isCancelled { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            } catch {
                return  // cancelled during backoff
            }
            backoff = min(backoff * 2, 30)
        }
    }

    /// Read one follow connection to exhaustion, decoding `log` records and
    /// recording each with the actor. Any delivered record resets the caller's
    /// reconnect backoff (the guest is demonstrably healthy). Returns true when
    /// the guest sent `log_eof` — the stream is complete and the caller must
    /// stop reconnecting — and false when the connection merely closed.
    private static func followLogStream(
        sandboxId: String,
        generation: UInt64,
        connection: VsockConnection,
        runtime: FirecrackerSandboxRuntime,
        backoff: inout TimeInterval
    ) async throws -> Bool {
        var reader = VsockLineReader(readSize: 65536)
        while true {
            guard let line = try await reader.nextLine(on: connection) else {
                return false  // guest closed; the loop reconnects
            }
            switch try SandboxControlProtocol.Response.decode(line: line) {
            case .log(let seq, let stream, let data):
                await runtime.recordLog(
                    sandboxId: sandboxId, generation: generation, seq: seq, stream: stream, data: data)
                backoff = 1
            case .logEof:
                await runtime.finishLogFollow(sandboxId: sandboxId, generation: generation)
                return true
            default:
                throw SandboxControlError.malformedResponse(line)
            }
        }
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

        do {
            let response = try await Self.withConnectionDeadline(connection, timeout: timeout) {
                try await Self.exchange(request, on: connection)
            }
            await connection.close()
            return response
        } catch {
            await connection.close()
            throw error
        }
    }

    /// Race `operation` against a deadline. When the deadline wins, the
    /// connection is closed so any blocking read the operation is parked in
    /// returns instead of hanging (`VsockConnection.close()` shuts the socket
    /// down before closing it, which is what actually wakes a parked
    /// `read(2)`), and `SandboxControlError.timeout` is thrown. The caller
    /// still owns closing the connection on success.
    private static func withConnectionDeadline<T: Sendable>(
        _ connection: VsockConnection, timeout: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await connection.close()
                throw SandboxControlError.timeout
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// Write one request and read the single newline-delimited response. A
    /// `static` (non-isolated) helper so it runs off the actor and its blocking
    /// read can be raced against a timeout (see `sendControl`).
    private static func exchange(
        _ request: SandboxControlProtocol.Request, on connection: VsockConnection
    ) async throws -> SandboxControlProtocol.Response {
        try await connection.write(request.encodedLine())

        var reader = VsockLineReader(readSize: 4096)
        guard let line = try await reader.nextLine(on: connection) else {
            throw SandboxControlError.malformedResponse("guest closed before sending a full response line")
        }
        let response = try SandboxControlProtocol.Response.decode(line: line)
        if case .error(let message) = response {
            throw SandboxControlError.guestError(message)
        }
        return response
    }

    // MARK: - Guest identity

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
        default:
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

/// Incremental newline framing over a vsock connection, shared by every read
/// loop in the runtime (control exchange, exec handshake, exec reader, log
/// follow) so buffering and line-splitting behavior cannot drift between them.
///
/// `nextLine` returns complete lines (without the `\n`) one at a time, reading
/// more from the connection only when no complete line is buffered; `nil`
/// means the guest closed the connection (EOF). Read errors and timeouts
/// propagate from `VsockConnection.read` untouched, so callers keep their own
/// EOF/error semantics and any external deadline racing (`withConnectionDeadline`)
/// works exactly as it does against a bare read.
private struct VsockLineReader {
    /// Bytes received but not yet returned: everything past the last returned
    /// line's newline.
    private(set) var buffer: Data
    /// Per-read chunk size (small for one-line control exchanges, large for
    /// streaming loops).
    private let readSize: Int

    init(initial: Data = Data(), readSize: Int) {
        self.buffer = initial
        self.readSize = readSize
    }

    /// Bytes buffered past the last returned line (e.g. early exec output
    /// received in the same chunk as the `exec_started` confirmation).
    var leftover: Data { buffer }

    /// The next complete line, or nil once the guest closes the connection.
    mutating func nextLine(on connection: VsockConnection) async throws -> String? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer = Data(buffer[buffer.index(after: newline)...])
                return line
            }
            let chunk = try await connection.read(maxLength: readSize)
            if chunk.isEmpty {
                return nil
            }
            buffer.append(chunk)
        }
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

    func startExec(
        sandboxId: String, sessionId: String, request: SandboxExecRequest,
        events: @escaping @Sendable (SandboxExecEvent) -> Void
    ) async throws {
        throw HypervisorServiceError.notSupported("sandboxes are only available on Linux")
    }

    func sendExecInput(sessionId: String, data: Data?, eof: Bool) async throws {
        throw HypervisorServiceError.notSupported("sandboxes are only available on Linux")
    }

    func resizeExec(sessionId: String, rows: Int, cols: Int) async throws {
        throw HypervisorServiceError.notSupported("sandboxes are only available on Linux")
    }

    func closeExec(sessionId: String) async {
        // No sessions can exist on non-Linux hosts.
    }

    func setSandboxLogHandler(_ handler: @escaping @Sendable (String, String, String) -> Void) async {
        // No sandboxes can run on non-Linux hosts, so no logs will flow.
    }

    func controlPlaneDisconnected() async {
        // No sessions or follows can exist on non-Linux hosts.
    }

    func controlPlaneConnected() async {
        // No sessions or follows can exist on non-Linux hosts.
    }
}
#endif
