import Foundation
import Logging

#if os(Linux)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Client for spawning and managing Firecracker processes
/// Handles the full lifecycle including process creation, socket management, and cleanup
public actor FirecrackerClient {
    private let firecrackerBinaryPath: String
    private let socketDirectory: String
    private let logger: Logger

    private var runningVMs: [String: RunningVM] = [:]

    /// How a tracked PID was identified, so it can be re-verified immediately
    /// before a signal is delivered.
    ///
    /// A PID discovered at spawn or adoption time is only a snapshot: if the
    /// VMM exits and the host recycles its pid before `destroyVM` runs, a bare
    /// `kill(pid, SIGTERM)` — and worse, the SIGKILL escalation — would land on
    /// an unrelated process. Re-checking `/proc/<pid>/cmdline` against the
    /// identity the pid was found by closes that window.
    enum PIDIdentity: Sendable {
        /// Discovered by the `--id <vmId>` argument (jailed VMs, which all
        /// share one in-chroot socket path).
        case vmId(String)
        /// Discovered by the `--api-sock <path>` argument pair (unjailed VMs).
        case socketPath(String)

        /// Whether `pid` still names the process this identity was resolved
        /// from. Returns false on any doubt — a missing or unreadable
        /// `/proc/<pid>/cmdline` means the process is gone or not ours.
        func matches(pid: Int32) -> Bool {
            #if os(Linux)
            guard let data = FileManager.default.contents(atPath: "/proc/\(pid)/cmdline") else {
                return false
            }
            let args = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            switch self {
            case .vmId(let id):
                guard let argv0 = args.first,
                    !URL(fileURLWithPath: argv0).lastPathComponent.contains("jailer")
                else { return false }
                return FirecrackerClient.argvCarriesVMId(args, vmId: id)
            case .socketPath(let path):
                guard let i = args.firstIndex(of: "--api-sock"), i + 1 < args.count else {
                    return false
                }
                return args[i + 1] == path
            }
            #else
            return false
            #endif
        }
    }

    /// Information about a running VM
    private struct RunningVM {
        /// The child process, when this client spawned it. `nil` for a VM
        /// re-adopted after an agent restart, whose process this client never
        /// spawned and can only reach by signalling `adoptedPID`.
        let process: Process?
        /// PID of a re-adopted Firecracker process, discovered from `/proc` at
        /// adoption time. `nil` for spawned VMs (use `process` instead).
        let adoptedPID: Int32?
        /// How `adoptedPID` was identified, for re-verification before
        /// signalling. `nil` when there is no adopted pid to signal.
        let pidIdentity: PIDIdentity?
        /// Fires when a spawned child exits, so teardown can suspend instead of
        /// blocking a thread in `waitUntilExit()`. `nil` for adopted VMs.
        let exitLatch: ExitLatch?
        /// Continuous drains on the child's stdout/stderr. Retained for the
        /// VM's lifetime: an undrained pipe wedges the VMM once its ~64KB
        /// kernel buffer fills, and a released read end leaves it writing into
        /// a broken pipe.
        let drains: [OutputDrain]
        let socketPath: String
        /// The per-VM jail directory (`<chroot base>/<exec name>/<id>`) for a
        /// jailed VM (issue #425), removed on destroy. `nil` for unjailed VMs.
        let jailDirectory: String?
        /// The per-VM cgroup directory the jailer may have created for a
        /// jailed VM, removed (best effort) on destroy — the jailer never
        /// cleans it up itself. `nil` for unjailed VMs.
        let cgroupDirectory: String?
        let manager: FirecrackerManager
    }

    /// The deterministic API socket path for an **unjailed** VM, shared by
    /// spawn and re-adoption so the two can never drift. Jailed VMs (issue
    /// #425) live under a per-VM chroot instead — see
    /// `JailerOptions.socketPath(chrootBaseDir:firecrackerBinaryPath:vmId:)`;
    /// `socketPath(vmId:jail:)` picks between the two layouts.
    public static func socketPath(socketDirectory: String, vmId: String) -> String {
        "\(socketDirectory)/\(vmId).sock"
    }

    /// The deterministic API socket path for a VM under this client, jailed or
    /// not — the single derivation both spawn and re-adoption (#433) use.
    public func socketPath(vmId: String, jail: JailerOptions?) -> String {
        if let jail {
            return JailerOptions.socketPath(
                chrootBaseDir: jail.chrootBaseDir,
                firecrackerBinaryPath: firecrackerBinaryPath,
                vmId: vmId)
        }
        return Self.socketPath(socketDirectory: socketDirectory, vmId: vmId)
    }

    /// Creates a new FirecrackerClient
    /// - Parameters:
    ///   - firecrackerBinaryPath: Path to the firecracker binary
    ///   - socketDirectory: Directory where Unix sockets will be created
    ///   - logger: Logger for debug output
    public init(
        firecrackerBinaryPath: String = "/usr/bin/firecracker",
        socketDirectory: String = "/tmp/firecracker",
        logger: Logger = Logger(label: "SwiftFirecracker.Client")
    ) {
        self.firecrackerBinaryPath = firecrackerBinaryPath
        self.socketDirectory = socketDirectory
        self.logger = logger
    }

    /// Creates a new microVM with the given configuration
    /// Returns a FirecrackerManager connected to the new VM
    public func createVM(vmId: String) async throws -> FirecrackerManager {
        try await createVM(vmId: vmId, jail: nil)
    }

    /// Creates a new microVM, optionally inside the jailer barrier (issue
    /// #425).
    ///
    /// When `jail` is set, the process is spawned through the `jailer` binary
    /// — chrooted, privilege-dropped, and (optionally) netns/cgroup-confined —
    /// and its API socket lives inside the chroot. The caller must have
    /// populated the jail root with every file the VM will reference
    /// **before** this call (the client never wipes an existing jail root, so
    /// pre-staged content survives), and must pass in-jail paths to the
    /// returned manager's configure calls.
    public func createVM(vmId: String, jail: JailerOptions?) async throws -> FirecrackerManager {
        // Check if VM already exists
        guard runningVMs[vmId] == nil else {
            throw FirecrackerError.vmAlreadyRunning(vmId)
        }

        // Verify the binaries are actually runnable — existence alone lets a
        // chmod problem surface later as an opaque spawn failure.
        guard FileManager.default.isExecutableFile(atPath: firecrackerBinaryPath) else {
            throw FirecrackerError.binaryNotFound(firecrackerBinaryPath)
        }
        if let jail {
            guard FileManager.default.isExecutableFile(atPath: jail.jailerBinaryPath) else {
                throw FirecrackerError.binaryNotFound(jail.jailerBinaryPath)
            }
        }

        // Create socket directory if needed
        try FileManager.default.createDirectory(
            atPath: socketDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let socketPath = self.socketPath(vmId: vmId, jail: jail)

        // Remove existing socket if present
        if FileManager.default.fileExists(atPath: socketPath) {
            try FileManager.default.removeItem(atPath: socketPath)
        }

        // Spawn the Firecracker process — directly, or through the jailer,
        // which sets up the barrier and then runs Firecracker. Without
        // `--new-pid-ns` the jailer execs in place, so the child handle *is*
        // the jailed Firecracker; with it the jailer forks and the parent
        // exits, so the VMM is tracked by pid instead (see below).
        let process = Process()
        if let jail {
            process.executableURL = URL(fileURLWithPath: jail.jailerBinaryPath)
            process.arguments = jail.arguments(vmId: vmId, firecrackerBinaryPath: firecrackerBinaryPath)
        } else {
            process.executableURL = URL(fileURLWithPath: firecrackerBinaryPath)
            process.arguments = [
                "--api-sock", socketPath,
                "--id", vmId,
                "--level", "Info",
            ]
        }

        // Capture output for logging. Both streams are drained continuously
        // for the VM's lifetime (see `OutputDrain`) — a Firecracker logging at
        // `Info` into a pipe nobody reads blocks in `write(2)` once the kernel
        // buffer fills, taking the microVM down with it.
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Installed before `run()` so an immediate exit cannot be missed.
        let exitLatch = ExitLatch()
        process.terminationHandler = { _ in exitLatch.signal() }

        logger.info(
            "Starting Firecracker process",
            metadata: [
                "vm_id": "\(vmId)",
                "socket": "\(socketPath)",
                "binary": "\(firecrackerBinaryPath)",
                "jailed": "\(jail != nil)",
            ])

        do {
            try process.run()
        } catch {
            throw FirecrackerError.processSpawnFailed(error.localizedDescription)
        }

        let stdoutDrain = OutputDrain(
            handle: outputPipe.fileHandleForReading, label: "stdout", logger: logger)
        let stderrDrain = OutputDrain(
            handle: errorPipe.fileHandleForReading, label: "stderr", logger: logger)
        let drains = [stdoutDrain, stderrDrain]

        // With `--new-pid-ns` the jailer forks the VMM into the new namespace
        // and the parent exits 0 straight away, so a dead child handle is the
        // expected steady state rather than a spawn failure.
        let parentExitsOnSuccess = jail?.newPidNamespace == true

        // Resolve which handle actually represents the VMM. Without
        // `--new-pid-ns` the jailer execs Firecracker in place, so the child
        // handle *is* the VMM and terminate/wait work directly. With it, that
        // handle is a parent that has already exited — track the forked VMM by
        // pid instead (the same discovery re-adoption uses), or destroy would
        // silently skip termination and leak a privileged process.
        var trackedProcess: Process? = process
        var trackedPID: Int32?
        if parentExitsOnSuccess {
            trackedProcess = nil
        }

        // Connect to the API socket, retrying until it answers. Retrying the
        // connect *is* the readiness test: the socket file appearing does not
        // mean Firecracker is listening yet, which is why this used to poll for
        // the file and then sleep a flat 100ms hoping the race had settled.
        let manager = FirecrackerManager(socketPath: socketPath, logger: logger)
        do {
            try await Self.connectWithRetry(manager: manager, socketPath: socketPath, timeout: .seconds(5))
        } catch {
            drains.forEach { $0.stop() }
            // The jailer exits immediately on a setup failure (bad cgroup
            // value, missing netns, unwritable chroot base); surface its
            // stderr instead of an opaque socket timeout. A `--new-pid-ns`
            // parent exiting 0 is normal, so only its *failure* status counts.
            if !process.isRunning && !(parentExitsOnSuccess && process.terminationStatus == 0) {
                // The drain is event-driven, so give it a moment to pick up
                // what the dying child wrote before reporting.
                try? await Task.sleep(for: .milliseconds(50))
                let stderr = stderrDrain.recentText()
                throw FirecrackerError.processSpawnFailed(
                    "process exited before its API socket appeared"
                        + (stderr.isEmpty ? "" : ": \(stderr)"))
            }
            // A live VMM that nothing is tracking yet would leak for the
            // agent's lifetime, so tear it back down.
            if let trackedProcess, trackedProcess.isRunning {
                trackedProcess.terminate()
            } else if parentExitsOnSuccess, let pid = await Self.offActor({ Self.discoverPID(vmId: vmId) }) {
                Self.terminate(pid: pid)
            }
            throw error
        }

        // Discover the forked VMM's pid only once the API answers — before
        // that the jailer may not have exec'd Firecracker yet.
        if parentExitsOnSuccess {
            trackedPID = await Self.offActor { Self.discoverPID(vmId: vmId) }
            if trackedPID == nil {
                logger.error(
                    "Could not resolve the jailed VMM pid after spawn; the process will survive destroy",
                    metadata: ["vm_id": "\(vmId)"])
            }
        }

        // Store VM info
        runningVMs[vmId] = RunningVM(
            process: trackedProcess,
            adoptedPID: trackedPID,
            pidIdentity: trackedPID.map { _ in .vmId(vmId) },
            exitLatch: trackedProcess.map { _ in exitLatch },
            drains: drains,
            socketPath: socketPath,
            jailDirectory: jail.map {
                JailerOptions.jailDirectory(
                    chrootBaseDir: $0.chrootBaseDir,
                    firecrackerBinaryPath: firecrackerBinaryPath,
                    vmId: vmId)
            },
            cgroupDirectory: jail.flatMap {
                $0.cgroups.isEmpty
                    ? nil
                    : JailerOptions.cgroupDirectory(
                        firecrackerBinaryPath: firecrackerBinaryPath, vmId: vmId)
            },
            manager: manager
        )

        logger.info("VM created successfully", metadata: ["vm_id": "\(vmId)"])
        return manager
    }

    /// Spawns a fresh Firecracker process and restores it from a snapshot
    /// (issue #426) — the restore counterpart of the boot flow. The snapshot
    /// carries the full device topology, so no configuration calls are made;
    /// the caller must have staged the memory/vmstate files and every drive
    /// file at the paths recorded in the vmstate (in-jail paths for a jailed
    /// VM, with a jail root laid out exactly as at snapshot time). A load
    /// failure tears the spawned process back down so a retry starts clean.
    public func restoreVM(
        vmId: String, jail: JailerOptions?, snapshot: SnapshotLoadConfig
    ) async throws -> FirecrackerManager {
        let manager = try await createVM(vmId: vmId, jail: jail)
        do {
            try await manager.loadSnapshot(snapshot)
        } catch {
            try? await destroyVM(vmId: vmId)
            throw error
        }
        return manager
    }

    /// Re-attaches to a Firecracker process that outlived the owning agent, by
    /// connecting to its existing API socket *without* spawning a new process
    /// (orphan re-adoption after an agent restart, issue #433). Returns the
    /// connected manager together with the microVM's current instance info.
    ///
    /// Throws `invalidSocketPath` when the deterministic socket is missing, and
    /// `connectionFailed` when it exists but no live Firecracker is listening
    /// (a stale socket left behind by a dead process). The caller leaves the VM
    /// orphaned in both cases.
    public func adoptVM(vmId: String) async throws -> (manager: FirecrackerManager, info: InstanceInfo) {
        try await adoptVM(vmId: vmId, jail: nil)
    }

    /// Jail-aware re-adoption (issue #425): pass the same `JailerOptions` the
    /// VM was created with so the API socket is looked up inside its chroot.
    /// Jailed processes share one in-chroot socket path, so the surviving
    /// PID is discovered by the `--id` argument instead of the socket path.
    public func adoptVM(
        vmId: String, jail: JailerOptions?
    ) async throws -> (manager: FirecrackerManager, info: InstanceInfo) {
        if let existing = runningVMs[vmId] {
            // Already managed (a replayed sync can race adoption): just report
            // the current instance info against the live manager.
            let info = try await existing.manager.getInstanceInfo()
            return (existing.manager, info)
        }

        let socketPath = self.socketPath(vmId: vmId, jail: jail)
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw FirecrackerError.invalidSocketPath(socketPath)
        }

        // connect() opens the Unix socket and a real GET proves a live
        // Firecracker is answering; a stale socket from a dead process refuses
        // the connection and surfaces as connectionFailed.
        let manager = FirecrackerManager(socketPath: socketPath, logger: logger)
        try await manager.connect()
        let info = try await manager.getInstanceInfo()

        // Learn the surviving process's PID so it can still be terminated on
        // delete despite this client never having spawned it.
        let pidIdentity: PIDIdentity = jail != nil ? .vmId(vmId) : .socketPath(socketPath)
        let pid = await Self.offActor {
            jail != nil ? Self.discoverPID(vmId: vmId) : Self.discoverPID(socketPath: socketPath)
        }

        runningVMs[vmId] = RunningVM(
            process: nil,
            adoptedPID: pid,
            pidIdentity: pid.map { _ in pidIdentity },
            exitLatch: nil,
            // An adopted VM's pipes belong to the process that spawned it,
            // which is gone; there is nothing for this client to drain.
            drains: [],
            socketPath: socketPath,
            jailDirectory: jail.map {
                JailerOptions.jailDirectory(
                    chrootBaseDir: $0.chrootBaseDir,
                    firecrackerBinaryPath: firecrackerBinaryPath,
                    vmId: vmId)
            },
            // Whether this adopted VM's creator passed cgroup limits is
            // unknowable here, so record the path unconditionally for jailed
            // VMs — removing a directory that was never created is a no-op.
            cgroupDirectory: jail.map { _ in
                JailerOptions.cgroupDirectory(firecrackerBinaryPath: firecrackerBinaryPath, vmId: vmId)
            },
            manager: manager
        )

        logger.info(
            "Re-adopted Firecracker VM via existing API socket",
            metadata: [
                "vm_id": "\(vmId)",
                "socket": "\(socketPath)",
                "state": "\(info.state.rawValue)",
                "pid": "\(pid.map(String.init) ?? "unknown")",
            ])
        return (manager, info)
    }

    /// Gets the manager for an existing VM
    public func getManager(vmId: String) async throws -> FirecrackerManager {
        guard let vm = runningVMs[vmId] else {
            throw FirecrackerError.vmNotFound(vmId)
        }
        return vm.manager
    }

    /// Destroys a VM and cleans up resources
    public func destroyVM(vmId: String) async throws {
        guard let vm = runningVMs[vmId] else {
            throw FirecrackerError.vmNotFound(vmId)
        }

        logger.info("Destroying VM", metadata: ["vm_id": "\(vmId)"])

        // Disconnect manager
        await vm.manager.disconnect()

        // Terminate the Firecracker process. Spawned VMs have a child Process
        // handle; re-adopted VMs (issue #433) do not, so signal the PID we
        // discovered at adoption time — Firecracker exits on SIGTERM. The
        // adopted path additionally waits (bounded) for the process to die:
        // the cgroup directory below cannot be removed while the process is
        // still inside it.
        if let process = vm.process {
            if process.isRunning {
                process.terminate()
                // Suspend rather than block: `waitUntilExit()` would hold this
                // actor — and a cooperative thread — for the whole teardown,
                // queueing every other VM's operations behind it.
                if let latch = vm.exitLatch {
                    _ = await latch.wait(upTo: .seconds(5))
                    if process.isRunning {
                        logger.warning(
                            "VMM ignored SIGTERM; escalating to SIGKILL",
                            metadata: ["vm_id": "\(vmId)"])
                        Self.forceKill(pid: process.processIdentifier)
                        _ = await latch.wait(upTo: .seconds(5))
                    }
                }
            }
        } else if let pid = vm.adoptedPID, let identity = vm.pidIdentity {
            // Re-verify before every signal. The pid was resolved at spawn or
            // adoption time; if the VMM has since exited and the host recycled
            // its pid, signalling blind would kill an unrelated process — and
            // the SIGKILL escalation below would make that unrecoverable.
            if identity.matches(pid: pid) {
                Self.terminate(pid: pid)
                await Self.waitForExit(pid: pid, identity: identity, timeout: .seconds(5))
                // Escalate rather than leak. A `--new-pid-ns` VMM is pid 1 of
                // its namespace, and the kernel drops an ancestor's SIGTERM to
                // a namespace init unless that process installed a handler —
                // SIGKILL is always delivered, and takes the namespace with it.
                if identity.matches(pid: pid) {
                    logger.warning(
                        "VMM ignored SIGTERM; escalating to SIGKILL",
                        metadata: ["vm_id": "\(vmId)", "pid": "\(pid)"])
                    Self.forceKill(pid: pid)
                    await Self.waitForExit(pid: pid, identity: identity, timeout: .seconds(5))
                }
            } else {
                logger.info(
                    "Tracked VMM pid no longer names this VM; skipping termination",
                    metadata: ["vm_id": "\(vmId)", "pid": "\(pid)"])
            }
        }

        // Stop draining only after the process is gone, so nothing it wrote on
        // the way out can block it.
        vm.drains.forEach { $0.stop() }

        // Remove socket
        if FileManager.default.fileExists(atPath: vm.socketPath) {
            try? FileManager.default.removeItem(atPath: vm.socketPath)
        }

        // A jailed VM's whole world lives under its jail directory (chroot
        // root, copied-in exec file, drives, sockets) — remove the subtree so
        // per-sandbox uids never inherit a predecessor's files.
        if let jailDirectory = vm.jailDirectory {
            try? FileManager.default.removeItem(atPath: jailDirectory)
        }

        // The jailer creates the per-VM cgroup but never removes it (cleanup
        // is the caller's responsibility), so churned sandboxes would pile up
        // stale cgroup directories. A populated cgroup dir can only be
        // rmdir(2)'d — never recursively deleted — and only once the process
        // has left it, so retry briefly to ride out the exit.
        if let cgroupDirectory = vm.cgroupDirectory {
            for _ in 0..<10 {
                if rmdir(cgroupDirectory) == 0 || errno == ENOENT { break }
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    break  // cancelled — stop rather than spin through the retries
                }
            }
        }

        // Remove from tracking
        runningVMs.removeValue(forKey: vmId)

        logger.info("VM destroyed", metadata: ["vm_id": "\(vmId)"])
    }

    /// Lists all running VMs
    public func listVMs() -> [String] {
        return Array(runningVMs.keys)
    }

    /// Checks if a VM is running
    public func isRunning(vmId: String) -> Bool {
        guard let vm = runningVMs[vmId] else {
            return false
        }
        if let process = vm.process {
            return process.isRunning
        }
        // Identity check rather than `kill(pid, 0)`: a recycled pid would
        // otherwise report a long-dead VM as still running.
        if let pid = vm.adoptedPID, let identity = vm.pidIdentity {
            return identity.matches(pid: pid)
        }
        return false
    }

    // MARK: - Adopted-process helpers

    /// Runs a `/proc` scan off the actor.
    ///
    /// The scan reads every process's `cmdline`, which on a busy host is
    /// hundreds of small blocking file reads. Performed inline it would hold
    /// this actor — and so every other VM's operations — for its duration.
    /// Bounded work, so parking a thread pool slot briefly is an acceptable
    /// trade for releasing the actor.
    private static func offActor<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated) { work() }.value
    }

    /// Finds the PID of the Firecracker process bound to `socketPath` by
    /// scanning `/proc` for the `--api-sock <socketPath>` argument pair the
    /// process was spawned with. Linux-only (Firecracker's only platform);
    /// returns `nil` when no match is found.
    static func discoverPID(socketPath: String) -> Int32? {
        #if os(Linux)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else {
            return nil
        }
        for entry in entries {
            guard let pid = Int32(entry),
                let data = FileManager.default.contents(atPath: "/proc/\(entry)/cmdline")
            else { continue }
            // /proc/<pid>/cmdline is NUL-separated argv.
            let args = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            if let i = args.firstIndex(of: "--api-sock"), i + 1 < args.count, args[i + 1] == socketPath {
                return pid
            }
        }
        return nil
        #else
        return nil
        #endif
    }

    /// Finds the PID of the Firecracker process spawned for `vmId` by scanning
    /// `/proc` for its `--id` argument. This is the jailed variant of
    /// `discoverPID(socketPath:)`: every jailed Firecracker sees the same
    /// in-chroot `--api-sock` path, but each carries its unique `--id`. Skips
    /// `jailer` processes themselves (a jailer that has not yet exec'd carries
    /// the same `--id`).
    static func discoverPID(vmId: String) -> Int32? {
        #if os(Linux)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else {
            return nil
        }
        for entry in entries {
            guard let pid = Int32(entry),
                let data = FileManager.default.contents(atPath: "/proc/\(entry)/cmdline")
            else { continue }
            // /proc/<pid>/cmdline is NUL-separated argv.
            let args = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            guard let argv0 = args.first,
                !URL(fileURLWithPath: argv0).lastPathComponent.contains("jailer")
            else { continue }
            if Self.argvCarriesVMId(args, vmId: vmId) {
                return pid
            }
        }
        return nil
        #else
        return nil
        #endif
    }

    /// Whether an argv carries `--id` naming `vmId`. Matches both spellings —
    /// the two-token `--id <id>` this client uses when spawning directly, and
    /// the single-token `--id=<id>` form the jailer passes to the exec'd
    /// Firecracker — so re-adopted jailed VMs stay killable on destroy.
    static func argvCarriesVMId(_ args: [String], vmId: String) -> Bool {
        if let i = args.firstIndex(of: "--id"), i + 1 < args.count, args[i + 1] == vmId {
            return true
        }
        return args.contains("--id=\(vmId)")
    }

    /// Sends SIGTERM to a re-adopted Firecracker process.
    static func terminate(pid: Int32) {
        #if os(Linux) || canImport(Darwin)
        _ = kill(pid, SIGTERM)
        #endif
    }

    /// Sends SIGKILL to a Firecracker process that ignored SIGTERM.
    static func forceKill(pid: Int32) {
        #if os(Linux) || canImport(Darwin)
        _ = kill(pid, SIGKILL)
        #endif
    }

    // A bare `kill(pid, 0)` liveness probe used to live here. It is deliberately
    // gone: it reports a *recycled* pid as alive, which is the same blind spot
    // that made signalling by remembered pid unsafe. Use
    // `PIDIdentity.matches(pid:)`, which confirms the process is still the VMM
    // it was resolved from.

    /// Waits (bounded, cancellation-aware) for a signalled process to leave the
    /// process table. Probes with the identity check rather than `kill(pid, 0)`
    /// so a recycled pid reads as "exited" instead of "still alive".
    static func waitForExit(pid: Int32, identity: PIDIdentity, timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if !identity.matches(pid: pid) { return }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return  // cancelled — stop rather than spin
            }
        }
    }

    /// Connects to a freshly spawned VM's API socket, retrying with backoff
    /// until it answers or the budget elapses.
    private static func connectWithRetry(
        manager: FirecrackerManager, socketPath: String, timeout: Duration
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        var delay = Duration.milliseconds(1)
        var lastError: Error?

        while ContinuousClock.now < deadline {
            do {
                try await manager.connect()
                return
            } catch {
                lastError = error
                try await Task.sleep(for: delay)
                delay = min(delay * 2, .milliseconds(50))
            }
        }

        throw FirecrackerError.timeout(
            "Waiting for API socket at \(socketPath)"
                + (lastError.map { ": \($0.localizedDescription)" } ?? ""))
    }

    /// Cleans up all VMs (called on shutdown)
    ///
    /// Destroys concurrently: each teardown can spend seconds waiting for a
    /// VMM to exit and its cgroup to empty, so doing them in series makes agent
    /// shutdown scale with the number of VMs on the host.
    public func cleanup() async {
        let vmIds = Array(runningVMs.keys)
        logger.info("Cleaning up all VMs", metadata: ["count": "\(vmIds.count)"])
        await withTaskGroup(of: Void.self) { group in
            for vmId in vmIds {
                group.addTask { [weak self] in
                    try? await self?.destroyVM(vmId: vmId)
                }
            }
        }
    }
}
