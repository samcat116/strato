import Foundation
import Logging

#if os(Linux)
import CLinuxPidfd
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Client for spawning and managing Firecracker processes
/// Handles the full lifecycle including process creation, socket management, and cleanup
public actor FirecrackerClient {
    /// One live Firecracker or jailer process discovered in the Linux process
    /// table. `effectiveUID` is the second value from `/proc/<pid>/status`'s
    /// `Uid:` row — the host identity the process is actually running as.
    public struct VMProcessInfo: Sendable, Equatable {
        public let vmId: String
        public let pid: Int32
        public let effectiveUID: UInt32?

        public init(vmId: String, pid: Int32, effectiveUID: UInt32?) {
            self.vmId = vmId
            self.pid = pid
            self.effectiveUID = effectiveUID
        }
    }

    /// Kernel-owned process identity used to prove that an allocated jail UID
    /// is no longer executing anything, even if a compromised VMM rewrote its
    /// mutable argv after an agent restart.
    public struct HostProcessInfo: Sendable, Equatable {
        public let pid: Int32
        public let effectiveUID: UInt32

        public init(pid: Int32, effectiveUID: UInt32) {
            self.pid = pid
            self.effectiveUID = effectiveUID
        }
    }

    private let firecrackerBinaryPath: String
    private let socketDirectory: String
    private let logger: Logger

    private var runningVMs: [String: RunningVM] = [:]
    /// VM ids held across teardown's suspension points. Without this gate,
    /// actor reentrancy would let a create/adopt start after a clean final
    /// `/proc` scan but before the destroying call returns to its caller.
    private var destroyingVMIds: Set<String> = []

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
        /// A process observed at a specific Linux `/proc/<pid>/stat` start
        /// time. Once established, this stays valid even if the process execs
        /// and changes argv; pid reuse produces a different start time.
        case processStartTime(UInt64)

        /// Whether `pid` still names the process this identity was resolved
        /// from. Returns false on any doubt — a missing or unreadable
        /// `/proc/<pid>/cmdline` means the process is gone or not ours.
        func matches(pid: Int32) -> Bool {
            (try? checkedMatches(pid: pid)) ?? false
        }

        /// Throwing identity check for teardown. Unlike `matches`, an
        /// unreadable process entry is not collapsed into "gone": callers
        /// releasing isolation resources need proof of exit, not best effort.
        func checkedMatches(pid: Int32) throws -> Bool {
            #if os(Linux)
            if case .processStartTime(let expectedStartTime) = self {
                guard let stat = try FirecrackerClient.readProcFile("/proc/\(pid)/stat") else {
                    return false
                }
                guard
                    let startTime = FirecrackerClient.parseProcStartTime(
                        String(decoding: stat, as: UTF8.self))
                else {
                    throw FirecrackerError.processInspectionFailed(
                        "could not revalidate start time for tracked pid \(pid)")
                }
                return startTime == expectedStartTime
            }
            guard let data = try FirecrackerClient.readProcFile("/proc/\(pid)/cmdline") else {
                return false
            }
            let args = FirecrackerClient.parseCommandLine(data)
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
            case .processStartTime:
                preconditionFailure("handled before reading cmdline")
            }
            #else
            throw FirecrackerError.processInspectionFailed(
                "the Linux /proc process table is unavailable on this platform")
            #endif
        }
    }

    /// Information about a running VM
    private struct RunningVM {
        /// The child process, when this client spawned it. `nil` for a VM
        /// re-adopted after an agent restart, whose process this client never
        /// spawned and can only reach through `adoptedProcess`.
        let process: Process?
        /// Kernel handle for a Firecracker process this client did not spawn.
        /// The same pidfd is retained from discovery through TERM, wait, and
        /// KILL, so PID recycling can never redirect a teardown signal.
        let adoptedProcess: PinnedProcess?
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

    /// A kernel-pinned process identity. The descriptor, not the reusable PID,
    /// is the authority for signalling and exit observation.
    private final class PinnedProcess: @unchecked Sendable {
        let pid: Int32
        let pidfd: Int32

        init(pid: Int32, pidfd: Int32) {
            self.pid = pid
            self.pidfd = pidfd
        }

        deinit {
            #if os(Linux)
            _ = Glibc.close(pidfd)
            #endif
        }
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
    func socketPath(vmId: String, jail: JailerOptions?) -> String {
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
    public func createVM(
        vmId: String, httpAPIMaxPayloadSize: Int? = nil
    ) async throws -> FirecrackerManager {
        try await createVM(
            vmId: vmId, jail: nil,
            httpAPIMaxPayloadSize: httpAPIMaxPayloadSize)
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
    public func createVM(
        vmId: String, jail: JailerOptions?,
        httpAPIMaxPayloadSize: Int? = nil
    ) async throws -> FirecrackerManager {
        guard !destroyingVMIds.contains(vmId) else {
            throw FirecrackerError.vmTeardownInProgress(vmId)
        }
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
            process.arguments = jail.arguments(
                vmId: vmId, firecrackerBinaryPath: firecrackerBinaryPath,
                httpAPIMaxPayloadSize: httpAPIMaxPayloadSize)
        } else {
            process.executableURL = URL(fileURLWithPath: firecrackerBinaryPath)
            process.arguments = Self.firecrackerArguments(
                socketPath: socketPath, vmId: vmId,
                httpAPIMaxPayloadSize: httpAPIMaxPayloadSize)
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
                "strato.vm.id": "\(vmId)",
                "socket": "\(socketPath)",
                "binary": "\(firecrackerBinaryPath)",
                "jailed": "\(jail != nil)",
            ])

        do {
            try FirecrackerProcessLauncher.run(process)
        } catch let error as FirecrackerError {
            throw error
        } catch {
            throw FirecrackerError.processSpawnFailed(error.localizedDescription)
        }

        let stdoutDrain = OutputDrain(
            fileDescriptor: outputPipe.fileHandleForReading.fileDescriptor,
            label: "stdout", logger: logger)
        let stderrDrain = OutputDrain(
            fileDescriptor: errorPipe.fileHandleForReading.fileDescriptor,
            label: "stderr", logger: logger)
        let drains = [stdoutDrain, stderrDrain].compactMap { $0 }

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
        var pinnedProcess: PinnedProcess?
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
            // Draining must outlive everything below: the 50ms settle only
            // collects output if the source is still live, and a still-running
            // VMM signalled below would otherwise be writing into an undrained
            // pipe — the wedge `OutputDrain` exists to prevent. Stopped once at
            // the end, on every path out.
            defer { drains.forEach { $0.stop() } }

            // The jailer exits immediately on a setup failure (bad cgroup
            // value, missing netns, unwritable chroot base); surface its
            // stderr instead of an opaque socket timeout. A `--new-pid-ns`
            // parent exiting 0 is normal, so only its *failure* status counts.
            if !process.isRunning && !(parentExitsOnSuccess && process.terminationStatus == 0) {
                // The drain is event-driven, so give it a moment to pick up
                // what the dying child wrote before reporting.
                try? await Task.sleep(for: .milliseconds(50))
                let stderr = stderrDrain?.recentText() ?? ""
                throw FirecrackerError.processSpawnFailed(
                    "process exited before its API socket appeared"
                        + (stderr.isEmpty ? "" : ": \(stderr)"))
            }
            // A live VMM that nothing is tracking yet would leak for the
            // agent's lifetime, so tear it back down.
            if let trackedProcess, trackedProcess.isRunning {
                trackedProcess.terminate()
                await exitLatch.wait(upTo: .seconds(5))
            } else if parentExitsOnSuccess,
                let pid = await Self.offActor({ Self.discoverPID(vmId: vmId) }),
                let pinned = try? await Self.offActorThrowing({
                    try Self.pinProcess(pid: pid, identity: .vmId(vmId))
                })
            {
                if (try? await Self.signal(pinned, signal: SIGTERM, vmId: vmId)) == true {
                    _ = try? await Self.waitForExit(pinned, timeout: .seconds(5))
                }
            }
            throw error
        }

        // Discover the forked VMM's pid only once the API answers — before
        // that the jailer may not have exec'd Firecracker yet.
        if parentExitsOnSuccess {
            if let pid = await Self.offActor({ Self.discoverPID(vmId: vmId) }) {
                do {
                    pinnedProcess = try await Self.offActorThrowing {
                        try Self.pinProcess(pid: pid, identity: .vmId(vmId))
                    }
                } catch {
                    logger.warning(
                        "Could not open a stable process handle for the jailed VMM; teardown will use the fail-closed process-table sweep",
                        metadata: [
                            "strato.vm.id": "\(vmId)",
                            "error": "\(error.localizedDescription)",
                        ])
                }
            }
            if pinnedProcess == nil {
                logger.warning(
                    "Could not retain the jailed VMM pidfd after spawn; teardown will use the fail-closed process-table sweep",
                    metadata: ["strato.vm.id": "\(vmId)"])
            }
        }

        // Store VM info
        runningVMs[vmId] = RunningVM(
            process: trackedProcess,
            adoptedProcess: pinnedProcess,
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

        logger.info("VM created successfully", metadata: ["strato.vm.id": "\(vmId)"])
        return manager
    }

    /// Firecracker argv shared by production spawn and unit coverage. The
    /// payload ceiling is opt-in so callers that do not use MMDS preserve the
    /// VMM's own default.
    static func firecrackerArguments(
        socketPath: String, vmId: String, httpAPIMaxPayloadSize: Int?
    ) -> [String] {
        var arguments = [
            "--api-sock", socketPath,
            "--id", vmId,
            "--level", "Info",
        ]
        if let httpAPIMaxPayloadSize {
            arguments += ["--http-api-max-payload-size", String(httpAPIMaxPayloadSize)]
        }
        return arguments
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
        guard !destroyingVMIds.contains(vmId) else {
            throw FirecrackerError.vmTeardownInProgress(vmId)
        }
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
        let fallbackPIDIdentity: PIDIdentity = jail != nil ? .vmId(vmId) : .socketPath(socketPath)
        let pid = await Self.offActor {
            jail != nil ? Self.discoverPID(vmId: vmId) : Self.discoverPID(socketPath: socketPath)
        }
        var pinnedProcess: PinnedProcess?
        if let pid {
            do {
                pinnedProcess = try await Self.offActorThrowing {
                    try Self.pinProcess(pid: pid, identity: fallbackPIDIdentity)
                }
            } catch {
                logger.warning(
                    "Could not open a stable process handle for the adopted VMM; teardown will use the fail-closed process-table sweep",
                    metadata: [
                        "strato.vm.id": "\(vmId)",
                        "pid": "\(pid)",
                        "error": "\(error.localizedDescription)",
                    ])
            }
        }

        runningVMs[vmId] = RunningVM(
            process: nil,
            adoptedProcess: pinnedProcess,
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
                "strato.vm.id": "\(vmId)",
                "socket": "\(socketPath)",
                "state": "\(info.state.rawValue)",
                "pid": "\(pid.map(String.init) ?? "unknown")",
            ])
        return (manager, info)
    }

    /// Waits for a tracked Firecracker process to exit without signalling it.
    ///
    /// This is the confirmation half of a guest-initiated shutdown. Callers
    /// first ask the guest to quiesce through `SendCtrlAltDel`, then use this
    /// observation before reopening its disk in another VMM. Returning false
    /// means the process either remained live for the whole budget or has no
    /// process identity strong enough to prove that it exited.
    public func waitForVMExit(vmId: String, timeout: Duration) async throws -> Bool {
        guard let vm = runningVMs[vmId] else {
            throw FirecrackerError.vmNotFound(vmId)
        }

        if let process = vm.process {
            guard process.isRunning else { return true }
            guard let exitLatch = vm.exitLatch else { return false }
            _ = await exitLatch.wait(upTo: timeout)
            return !process.isRunning
        }

        guard let adoptedProcess = vm.adoptedProcess else { return false }
        return try await Self.waitForExit(adoptedProcess, timeout: timeout)
    }

    /// Destroys a VM and cleans up resources
    public func destroyVM(vmId: String) async throws {
        guard let vm = runningVMs[vmId] else {
            throw FirecrackerError.vmNotFound(vmId)
        }
        guard destroyingVMIds.insert(vmId).inserted else {
            throw FirecrackerError.vmTeardownInProgress(vmId)
        }
        defer { _ = destroyingVMIds.remove(vmId) }

        logger.info("Destroying VM", metadata: ["strato.vm.id": "\(vmId)"])

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
                    await latch.wait(upTo: .seconds(5))
                    if process.isRunning {
                        logger.warning(
                            "VMM ignored SIGTERM; escalating to SIGKILL",
                            metadata: ["strato.vm.id": "\(vmId)"])
                        Self.forceKill(pid: process.processIdentifier)
                        await latch.wait(upTo: .seconds(5))
                    }
                } else {
                    throw FirecrackerError.processExitUnconfirmed(
                        "VM \(vmId) has a live child process but no exit latch")
                }
                guard !process.isRunning else {
                    throw FirecrackerError.processExitUnconfirmed(
                        "VM \(vmId) process \(process.processIdentifier) remained live after SIGKILL")
                }
            }
        } else if let adoptedProcess = vm.adoptedProcess {
            // The pidfd was opened and validated when this process was
            // discovered. Keep using that same kernel handle through TERM,
            // wait, and KILL; reopening from a numeric pid here would restore
            // the PID-reuse race this handle exists to close.
            if try await Self.signal(adoptedProcess, signal: SIGTERM, vmId: vmId) {
                var exited = try await Self.waitForExit(
                    adoptedProcess, timeout: .seconds(5))
                // Escalate rather than leak. A `--new-pid-ns` VMM is pid 1 of
                // its namespace, and the kernel drops an ancestor's SIGTERM to
                // a namespace init unless that process installed a handler —
                // SIGKILL is always delivered, and takes the namespace with it.
                if !exited {
                    logger.warning(
                        "VMM ignored SIGTERM; escalating to SIGKILL",
                        metadata: [
                            "strato.vm.id": "\(vmId)",
                            "pid": "\(adoptedProcess.pid)",
                        ])
                    _ = try await Self.signal(adoptedProcess, signal: SIGKILL, vmId: vmId)
                    exited = try await Self.waitForExit(
                        adoptedProcess, timeout: .seconds(5))
                }
                guard exited else {
                    throw FirecrackerError.processExitUnconfirmed(
                        "VM \(vmId) process \(adoptedProcess.pid) remained live after SIGKILL")
                }
            } else {
                logger.info(
                    "Tracked VMM pidfd already reports exit; skipping termination",
                    metadata: [
                        "strato.vm.id": "\(vmId)",
                        "pid": "\(adoptedProcess.pid)",
                    ])
            }
            guard try await Self.waitForExit(adoptedProcess, timeout: .zero) else {
                throw FirecrackerError.processExitUnconfirmed(
                    "VM \(vmId) process \(adoptedProcess.pid) is still live")
            }
        }

        // The remembered child or adopted pid is not sufficient proof for a
        // jailed VM: the jailer can fork, exec, or outlive the particular pid
        // originally observed. Scan for every exact `--id` match, terminate
        // identities that are still the processes we inspected, and require a
        // clean second scan before any artifacts or tracking are removed.
        try await terminateDiscoveredVMProcesses(vmId: vmId)

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

        logger.info("VM destroyed", metadata: ["strato.vm.id": "\(vmId)"])
    }

    /// Terminates a Firecracker/jailer process that may not be present in this
    /// client's in-memory tracking (for example, a failed spawn or an orphan
    /// left by an agent restart). A retained entry means a prior tracked
    /// teardown failed, so retry that authoritative path before falling back
    /// to process discovery. The exact `--id` value, managed-process argv
    /// shape, and Linux process start time are all revalidated before a signal
    /// is sent. Success means a final `/proc` scan found no matching process.
    public func destroyUntrackedVM(vmId: String) async throws {
        if runningVMs[vmId] != nil {
            try await destroyVM(vmId: vmId)
            return
        }
        guard destroyingVMIds.insert(vmId).inserted else {
            throw FirecrackerError.vmTeardownInProgress(vmId)
        }
        defer { _ = destroyingVMIds.remove(vmId) }
        try await terminateDiscoveredVMProcesses(vmId: vmId)
    }

    /// Returns every live Firecracker or jailer process whose exact `--id`
    /// value begins with `idPrefix`. Inspection fails closed if `/proc` or a
    /// visible process entry cannot be read reliably.
    public func discoverVMProcesses(idPrefix: String) async throws -> [VMProcessInfo] {
        try await Self.offActorThrowing {
            let snapshots = try Self.scanVMProcesses(idPrefix: idPrefix)
            defer { Self.closePIDFDs(snapshots) }
            return snapshots.map(\.info)
        }
    }

    /// Returns every host process whose kernel-reported effective uid lies in
    /// `range`. Unlike VM discovery, this does not trust argv at all.
    public func discoverHostProcesses(
        effectiveUIDsIn range: Range<UInt32>
    ) async throws -> [HostProcessInfo] {
        try await Self.offActorThrowing {
            let snapshots = try Self.scanHostProcesses(effectiveUIDsIn: range)
            defer { Self.closePIDFDs(snapshots) }
            return snapshots.map(\.info)
        }
    }

    /// Fails unless no process still executes under `effectiveUID`. Callers
    /// use this only for an exclusively claimed jail identity; a legacy
    /// duplicate remains poisoned instead of requiring its live peer to exit.
    public func confirmNoHostProcess(effectiveUID: UInt32) async throws {
        let upperBound = effectiveUID.addingReportingOverflow(1)
        guard !upperBound.overflow else {
            throw FirecrackerError.processInspectionFailed(
                "cannot inspect the invalid terminal uid_t value")
        }
        let remaining = try await Self.offActorThrowing {
            try Self.scanHostProcesses(
                effectiveUIDsIn: effectiveUID..<upperBound.partialValue)
        }
        defer { Self.closePIDFDs(remaining) }
        guard remaining.isEmpty else {
            throw FirecrackerError.processExitUnconfirmed(
                "host uid \(effectiveUID) still has process ids "
                    + remaining.map { String($0.info.pid) }.joined(separator: ", "))
        }
    }

    /// Fails unless no process remains rooted in this jail. `/proc/<pid>/root`
    /// is kernel-owned and continues to identify a deleted chroot as
    /// `<path> (deleted)`, so an argv-rewriting VMM cannot hide from a
    /// target-specific legacy-duplicate cleanup.
    public func confirmNoHostProcess(inJailRoot jailRoot: String) async throws {
        let remaining = try await Self.offActorThrowing {
            try Self.scanHostProcesses(inJailRoot: jailRoot)
        }
        defer { Self.closePIDFDs(remaining) }
        guard remaining.isEmpty else {
            throw FirecrackerError.processExitUnconfirmed(
                "jail root \(jailRoot) still has process ids "
                    + remaining.map { String($0.info.pid) }.joined(separator: ", "))
        }
    }

    // MARK: - Adopted-process helpers

    /// A `/proc` snapshot strong enough to reject a recycled pid before a
    /// signal is sent. Linux field 22 (`starttime`) is stable for the lifetime
    /// of a process even when its argv later changes.
    private struct VMProcessSnapshot: Sendable {
        let info: VMProcessInfo
        let startTime: UInt64
        let pidfd: Int32
    }

    private struct HostProcessSnapshot: Sendable {
        let info: HostProcessInfo
        let startTime: UInt64
        let pidfd: Int32
    }

    private static func closePIDFDs(_ snapshots: [VMProcessSnapshot]) {
        #if os(Linux)
        for snapshot in snapshots { _ = Glibc.close(snapshot.pidfd) }
        #endif
    }

    private static func closePIDFDs(_ snapshots: [HostProcessSnapshot]) {
        #if os(Linux)
        for snapshot in snapshots { _ = Glibc.close(snapshot.pidfd) }
        #endif
    }

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

    /// Throwing counterpart to `offActor`, used by fail-closed `/proc`
    /// inspection. Errors must reach the caller rather than collapsing to an
    /// empty process list, because "could not inspect" is not proof of exit.
    private static func offActorThrowing<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }

    /// Terminates the exact process identities currently carrying `vmId`,
    /// then proves no managed process with that id remains. A process that
    /// appears after the first scan is not signalled — it was not one of the
    /// inspected identities — but it still makes confirmation fail closed.
    private func terminateDiscoveredVMProcesses(vmId: String) async throws {
        let discovered = try await Self.offActorThrowing {
            try Self.scanExactVMProcesses(vmId: vmId)
        }
        defer { Self.closePIDFDs(discovered) }

        if !discovered.isEmpty {
            try await Self.signal(discovered, signal: SIGTERM, vmId: vmId)
            var survivors = try await Self.waitForExit(discovered, timeout: .seconds(5))

            if !survivors.isEmpty {
                logger.warning(
                    "Firecracker processes ignored SIGTERM; escalating to SIGKILL",
                    metadata: [
                        "strato.vm.id": "\(vmId)",
                        "pids": "\(survivors.map { String($0.info.pid) }.joined(separator: ","))",
                    ])
                try await Self.signal(survivors, signal: SIGKILL, vmId: vmId)
                survivors = try await Self.waitForExit(survivors, timeout: .seconds(5))
            }

            guard survivors.isEmpty else {
                throw FirecrackerError.processExitUnconfirmed(
                    "VM \(vmId) still has process ids "
                        + survivors.map { String($0.info.pid) }.joined(separator: ", "))
            }
        }

        let remaining = try await Self.offActorThrowing {
            try Self.scanExactVMProcesses(vmId: vmId)
        }
        defer { Self.closePIDFDs(remaining) }
        guard remaining.isEmpty else {
            throw FirecrackerError.processExitUnconfirmed(
                "VM \(vmId) still has process ids "
                    + remaining.map { String($0.info.pid) }.joined(separator: ", "))
        }
    }

    /// Revalidates a process snapshot immediately before signalling. The
    /// Linux start time closes the pid-reuse gap left by argv matching alone.
    private static func signal(
        _ snapshots: [VMProcessSnapshot], signal: Int32, vmId: String
    ) async throws {
        try await offActorThrowing {
            #if os(Linux)
            for snapshot in snapshots {
                if swift_firecracker_pidfd_send_signal(snapshot.pidfd, signal) != 0,
                    errno != ESRCH
                {
                    let savedErrno = errno
                    throw FirecrackerError.processSignalFailed(
                        "signal \(signal) to VM \(vmId) pid \(snapshot.info.pid) failed "
                            + "with errno \(savedErrno)")
                }
            }
            #else
            throw FirecrackerError.processInspectionFailed(
                "process signalling is only supported on Linux")
            #endif
        }
    }

    /// Signals a remembered process through the pidfd retained at discovery.
    private static func signal(
        _ process: PinnedProcess, signal: Int32, vmId: String
    ) async throws -> Bool {
        try await offActorThrowing {
            #if os(Linux)
            guard try !pidfdHasExited(process.pidfd) else { return false }
            if swift_firecracker_pidfd_send_signal(process.pidfd, signal) != 0,
                errno != ESRCH
            {
                let savedErrno = errno
                throw FirecrackerError.processSignalFailed(
                    "signal \(signal) to VM \(vmId) pid \(process.pid) failed with errno \(savedErrno)")
            }
            return true
            #else
            throw FirecrackerError.processInspectionFailed(
                "process signalling is only supported on Linux")
            #endif
        }
    }

    /// Opens the process handle before validating mutable `/proc` metadata.
    /// If the numeric PID recycles between discovery and this call, the
    /// supplied identity cannot validate the replacement through the pinned
    /// handle's lifetime and no handle is returned.
    private static func pinProcess(pid: Int32, identity: PIDIdentity) throws -> PinnedProcess? {
        #if os(Linux)
        guard let pidfd = try openPIDFD(pid: pid) else { return nil }
        var transferred = false
        defer {
            if !transferred { _ = Glibc.close(pidfd) }
        }
        guard try !pidfdHasExited(pidfd) else { return nil }
        guard try identity.checkedMatches(pid: pid) else { return nil }
        guard try !pidfdHasExited(pidfd) else { return nil }
        transferred = true
        return PinnedProcess(pid: pid, pidfd: pidfd)
        #else
        throw FirecrackerError.processInspectionFailed(
            "pidfd process handles are only supported on Linux")
        #endif
    }

    private static func openPIDFD(pid: Int32) throws -> Int32? {
        #if os(Linux)
        let descriptor = swift_firecracker_pidfd_open(pid)
        guard descriptor >= 0 else {
            let savedErrno = errno
            if savedErrno == ESRCH || savedErrno == ENOENT { return nil }
            throw FirecrackerError.processInspectionFailed(
                "pidfd_open for pid \(pid) failed with errno \(savedErrno)")
        }
        return descriptor
        #else
        throw FirecrackerError.processInspectionFailed(
            "pidfd process handles are only supported on Linux")
        #endif
    }

    private static func pidfdHasExited(_ descriptor: Int32) throws -> Bool {
        #if os(Linux)
        var descriptorState = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let result = Glibc.poll(&descriptorState, 1, 0)
        guard result >= 0 else {
            let savedErrno = errno
            throw FirecrackerError.processInspectionFailed(
                "poll on pidfd \(descriptor) failed with errno \(savedErrno)")
        }
        return result > 0
            && descriptorState.revents & Int16(POLLIN | POLLHUP | POLLERR) != 0
        #else
        throw FirecrackerError.processInspectionFailed(
            "pidfd process handles are only supported on Linux")
        #endif
    }

    /// Waits for all inspected identities to disappear. Cancellation returns
    /// the identities still live so teardown fails closed instead of claiming
    /// success from an interrupted observation.
    private static func waitForExit(
        _ snapshots: [VMProcessSnapshot], timeout: Duration
    ) async throws -> [VMProcessSnapshot] {
        let deadline = ContinuousClock.now + timeout
        var survivors = snapshots
        while ContinuousClock.now < deadline {
            survivors = try await offActorThrowing {
                try snapshots.filter { try !pidfdHasExited($0.pidfd) }
            }
            if survivors.isEmpty { return [] }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return survivors
            }
        }
        return try await offActorThrowing {
            try snapshots.filter { try !pidfdHasExited($0.pidfd) }
        }
    }

    /// Waits on the same process handle retained at discovery. A cancelled or
    /// expired wait returns false unless the pidfd itself already reports
    /// exit, so callers cannot mistake interruption for a cleanup proof.
    private static func waitForExit(
        _ process: PinnedProcess, timeout: Duration
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while true {
            let exited = try await offActorThrowing {
                try pidfdHasExited(process.pidfd)
            }
            if exited { return true }
            if ContinuousClock.now >= deadline { return false }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return try await offActorThrowing {
                    try pidfdHasExited(process.pidfd)
                }
            }
        }
    }

    /// Scans Linux `/proc` for Firecracker or jailer processes. The directory
    /// and every visible cmdline must be readable: silently treating a denied
    /// entry as absent would make an untrusted workload's uid reusable while
    /// its VMM may still be alive.
    private static func scanVMProcesses(idPrefix: String) throws -> [VMProcessSnapshot] {
        #if os(Linux)
        let entries: [String]
        do {
            entries = try FileManager.default.contentsOfDirectory(atPath: "/proc")
        } catch {
            throw FirecrackerError.processInspectionFailed(
                "could not enumerate /proc: \(error.localizedDescription)")
        }

        var matches: [VMProcessSnapshot] = []
        var transferringPIDFDOwnership = false
        defer {
            if !transferringPIDFDOwnership { closePIDFDs(matches) }
        }
        for entry in entries {
            guard let pid = Int32(entry), pid > 0 else { continue }
            guard let pidfd = try openPIDFD(pid: pid) else { continue }
            var retainPIDFD = false
            defer {
                if !retainPIDFD { _ = Glibc.close(pidfd) }
            }
            guard try !pidfdHasExited(pidfd) else { continue }
            guard let stat = try readProcFile("/proc/\(entry)/stat") else { continue }
            guard let startTime = parseProcStartTime(String(decoding: stat, as: UTF8.self)) else {
                throw FirecrackerError.processInspectionFailed(
                    "could not parse start time for pid \(pid)")
            }
            guard let commandLine = try readProcFile("/proc/\(entry)/cmdline") else {
                continue
            }
            let arguments = parseCommandLine(commandLine)
            guard let vmId = vmIDForManagedProcess(arguments: arguments), vmId.hasPrefix(idPrefix)
            else { continue }

            guard let status = try readProcFile("/proc/\(entry)/status") else { continue }
            guard let effectiveUID = parseEffectiveUID(String(decoding: status, as: UTF8.self)) else {
                throw FirecrackerError.processInspectionFailed(
                    "could not parse effective uid for matching pid \(pid)")
            }
            guard let confirmedStat = try readProcFile("/proc/\(entry)/stat") else { continue }
            guard
                let confirmedStartTime = parseProcStartTime(
                    String(decoding: confirmedStat, as: UTF8.self))
            else {
                throw FirecrackerError.processInspectionFailed(
                    "could not re-parse start time for matching pid \(pid)")
            }
            guard confirmedStartTime == startTime else { continue }

            let snapshot = VMProcessSnapshot(
                info: VMProcessInfo(vmId: vmId, pid: pid, effectiveUID: effectiveUID),
                startTime: startTime, pidfd: pidfd)
            // The pidfd was opened before any mutable metadata was read. If it
            // is still live now, `/proc/<pid>` could not have recycled to a
            // different process between those reads.
            guard try !pidfdHasExited(pidfd) else { continue }
            matches.append(snapshot)
            retainPIDFD = true
        }
        transferringPIDFDOwnership = true
        return matches.sorted { $0.info.pid < $1.info.pid }
        #else
        throw FirecrackerError.processInspectionFailed(
            "the Linux /proc process table is unavailable on this platform")
        #endif
    }

    private static func scanExactVMProcesses(vmId: String) throws -> [VMProcessSnapshot] {
        let candidates = try scanVMProcesses(idPrefix: vmId)
        var matches: [VMProcessSnapshot] = []
        for candidate in candidates {
            if candidate.info.vmId == vmId {
                matches.append(candidate)
            } else {
                #if os(Linux)
                _ = Glibc.close(candidate.pidfd)
                #endif
            }
        }
        return matches
    }

    /// Scans the kernel-owned effective uid field for every visible process.
    /// A process that exits during the scan is ignored; every other read or
    /// parse failure is uncertainty and therefore fails the release proof.
    private static func scanHostProcesses(
        effectiveUIDsIn range: Range<UInt32>
    ) throws -> [HostProcessSnapshot] {
        #if os(Linux)
        let entries: [String]
        do {
            entries = try FileManager.default.contentsOfDirectory(atPath: "/proc")
        } catch {
            throw FirecrackerError.processInspectionFailed(
                "could not enumerate /proc: \(error.localizedDescription)")
        }

        var matches: [HostProcessSnapshot] = []
        var transferringPIDFDOwnership = false
        defer {
            if !transferringPIDFDOwnership { closePIDFDs(matches) }
        }
        for entry in entries {
            guard let pid = Int32(entry), pid > 0 else { continue }
            guard let pidfd = try openPIDFD(pid: pid) else { continue }
            var retainPIDFD = false
            defer {
                if !retainPIDFD { _ = Glibc.close(pidfd) }
            }
            guard try !pidfdHasExited(pidfd) else { continue }
            guard let initialStat = try readProcFile("/proc/\(entry)/stat") else { continue }
            guard
                let startTime = parseProcStartTime(
                    String(decoding: initialStat, as: UTF8.self))
            else {
                throw FirecrackerError.processInspectionFailed(
                    "could not parse start time for pid \(pid)")
            }
            guard let status = try readProcFile("/proc/\(entry)/status") else { continue }
            guard
                let effectiveUID = parseEffectiveUID(
                    String(decoding: status, as: UTF8.self))
            else {
                throw FirecrackerError.processInspectionFailed(
                    "could not parse effective uid for pid \(pid)")
            }
            guard range.contains(effectiveUID) else { continue }
            guard let confirmedStat = try readProcFile("/proc/\(entry)/stat") else { continue }
            guard
                parseProcStartTime(String(decoding: confirmedStat, as: UTF8.self))
                    == startTime
            else { continue }
            let snapshot = HostProcessSnapshot(
                info: HostProcessInfo(pid: pid, effectiveUID: effectiveUID),
                startTime: startTime, pidfd: pidfd)
            guard try !pidfdHasExited(pidfd) else { continue }
            matches.append(snapshot)
            retainPIDFD = true
        }
        transferringPIDFDOwnership = true
        return matches.sorted { $0.info.pid < $1.info.pid }
        #else
        throw FirecrackerError.processInspectionFailed(
            "the Linux /proc process table is unavailable on this platform")
        #endif
    }

    private static func scanHostProcesses(
        inJailRoot jailRoot: String
    ) throws -> [HostProcessSnapshot] {
        #if os(Linux)
        let entries: [String]
        do {
            entries = try FileManager.default.contentsOfDirectory(atPath: "/proc")
        } catch {
            throw FirecrackerError.processInspectionFailed(
                "could not enumerate /proc: \(error.localizedDescription)")
        }
        // `/proc/<pid>/root` reports the kernel-resolved path. Resolve a
        // symlinked chroot base too, or string comparison could miss the very
        // process this release proof is meant to find.
        let normalizedRoot =
            URL(fileURLWithPath: jailRoot).resolvingSymlinksInPath().standardizedFileURL.path
        let deletedRoot = normalizedRoot + " (deleted)"
        var matches: [HostProcessSnapshot] = []
        var transferringPIDFDOwnership = false
        defer {
            if !transferringPIDFDOwnership { closePIDFDs(matches) }
        }
        for entry in entries {
            guard let pid = Int32(entry), pid > 0 else { continue }
            guard let pidfd = try openPIDFD(pid: pid) else { continue }
            var retainPIDFD = false
            defer {
                if !retainPIDFD { _ = Glibc.close(pidfd) }
            }
            guard try !pidfdHasExited(pidfd) else { continue }
            guard let initialStat = try readProcFile("/proc/\(entry)/stat") else { continue }
            guard
                let startTime = parseProcStartTime(
                    String(decoding: initialStat, as: UTF8.self))
            else {
                throw FirecrackerError.processInspectionFailed(
                    "could not parse start time for pid \(pid)")
            }
            guard let processRoot = try readProcLink("/proc/\(entry)/root") else {
                continue
            }
            guard processRoot == normalizedRoot || processRoot == deletedRoot else {
                continue
            }
            guard let status = try readProcFile("/proc/\(entry)/status") else { continue }
            guard
                let effectiveUID = parseEffectiveUID(
                    String(decoding: status, as: UTF8.self))
            else {
                throw FirecrackerError.processInspectionFailed(
                    "could not parse effective uid for pid \(pid)")
            }
            guard try !pidfdHasExited(pidfd) else { continue }
            matches.append(
                HostProcessSnapshot(
                    info: HostProcessInfo(pid: pid, effectiveUID: effectiveUID),
                    startTime: startTime, pidfd: pidfd))
            retainPIDFD = true
        }
        transferringPIDFDOwnership = true
        return matches.sorted { $0.info.pid < $1.info.pid }
        #else
        throw FirecrackerError.processInspectionFailed(
            "the Linux /proc process table is unavailable on this platform")
        #endif
    }

    /// Reads one procfs file. A disappearing process is a normal `nil`; all
    /// other failures are inspection errors and therefore fail closed.
    private static func readProcFile(_ path: String) throws -> Data? {
        #if os(Linux)
        let descriptor = Glibc.open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            let savedErrno = errno
            if savedErrno == ENOENT || savedErrno == ESRCH { return nil }
            throw FirecrackerError.processInspectionFailed(
                "could not open \(path) (errno \(savedErrno))")
        }
        defer { _ = Glibc.close(descriptor) }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Glibc.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                return data
            } else if errno != EINTR {
                let savedErrno = errno
                throw FirecrackerError.processInspectionFailed(
                    "could not read \(path) (errno \(savedErrno))")
            }
        }
        #else
        throw FirecrackerError.processInspectionFailed(
            "the Linux /proc process table is unavailable on this platform")
        #endif
    }

    /// Reads one procfs symlink without following it. A disappearing process
    /// is normal; permission and I/O failures are not proof of absence.
    private static func readProcLink(_ path: String) throws -> String? {
        #if os(Linux)
        var buffer = [CChar](repeating: 0, count: 65_536)
        let count = path.withCString { pointer in
            Glibc.readlink(pointer, &buffer, buffer.count - 1)
        }
        guard count >= 0 else {
            let savedErrno = errno
            if savedErrno == ENOENT || savedErrno == ESRCH { return nil }
            throw FirecrackerError.processInspectionFailed(
                "could not read \(path) (errno \(savedErrno))")
        }
        guard count < buffer.count - 1 else {
            throw FirecrackerError.processInspectionFailed(
                "procfs link \(path) exceeded the inspection buffer")
        }
        return buffer.withUnsafeBytes { bytes in
            String(decoding: bytes.prefix(Int(count)), as: UTF8.self)
        }
        #else
        throw FirecrackerError.processInspectionFailed(
            "the Linux /proc process table is unavailable on this platform")
        #endif
    }

    private static func processStillMatches(_ snapshot: VMProcessSnapshot) throws -> Bool {
        try processStillMatches(pid: snapshot.info.pid, startTime: snapshot.startTime)
    }

    private static func processStillMatches(pid: Int32, startTime expectedStartTime: UInt64) throws -> Bool {
        guard let stat = try readProcFile("/proc/\(pid)/stat") else { return false }
        guard let observedStartTime = parseProcStartTime(String(decoding: stat, as: UTF8.self)) else {
            throw FirecrackerError.processInspectionFailed(
                "could not revalidate start time for pid \(pid)")
        }
        return observedStartTime == expectedStartTime
    }

    static func parseCommandLine(_ data: Data) -> [String] {
        data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Extracts an id only from argv that has a Firecracker/jailer executable
    /// name or its characteristic option shape. This prevents an arbitrary
    /// process that merely happens to use an `--id` flag from being signalled.
    static func vmIDForManagedProcess(arguments: [String]) -> String? {
        guard let executable = arguments.first else { return nil }
        let basename = URL(fileURLWithPath: executable).lastPathComponent.lowercased()
        let recognizedName =
            basename == "firecracker" || basename.hasPrefix("firecracker-")
            || basename == "jailer" || basename.hasPrefix("jailer-")
        let firecrackerShape = arguments.contains("--api-sock")
        let jailerShape =
            arguments.contains("--exec-file") && arguments.contains("--uid")
            && arguments.contains("--gid") && arguments.contains("--chroot-base-dir")
        guard recognizedName || firecrackerShape || jailerShape else { return nil }

        if let index = arguments.firstIndex(of: "--id"), index + 1 < arguments.count {
            return arguments[index + 1]
        }
        return arguments.first(where: { $0.hasPrefix("--id=") }).map {
            String($0.dropFirst("--id=".count))
        }
    }

    /// Parses Linux `/proc/<pid>/stat` field 22. The command name in field 2
    /// may contain spaces or parentheses, so fields are counted only after its
    /// final closing parenthesis.
    static func parseProcStartTime(_ stat: String) -> UInt64? {
        guard let closeParenthesis = stat.lastIndex(of: ")") else { return nil }
        let fields = stat[stat.index(after: closeParenthesis)...].split { $0.isWhitespace }
        guard fields.count > 19 else { return nil }
        return UInt64(fields[19])
    }

    /// Parses the effective uid (the second numeric value) from Linux
    /// `/proc/<pid>/status`.
    static func parseEffectiveUID(_ status: String) -> UInt32? {
        for line in status.split(whereSeparator: \.isNewline) {
            let fields = line.split { $0.isWhitespace }
            if fields.first == "Uid:", fields.count >= 3 {
                return UInt32(fields[2])
            }
        }
        return nil
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

}
