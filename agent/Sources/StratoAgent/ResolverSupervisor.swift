import Foundation
import Logging
import StratoAgentCore
import StratoShared

/// Runs one CoreDNS per network that publishes a resolver (STR-40).
///
/// The impure half of the resolver. Everything with a decision in it —
/// what to render, when to restart, how long to back off — lives in
/// `CoreDNSZoneRenderer` and `ResolverSupervisionPolicy`, where tests can reach
/// it; this writes files, starts processes, and reaps them.
///
/// ## Why a process per network
///
/// The resolver terminates in the network's chassis namespace
/// (`ChassisServicePlan`), which is where reply routing to an overlapping tenant
/// address works. `setns(2)` is per-thread and does not compose with Swift's
/// concurrency runtime, which schedules continuations across a shared pool, so a
/// listener inside the agent would have to pin a thread per namespace and never
/// let a continuation move. ADR 0003 anticipated this and named the alternative:
/// a helper process per namespace, which is what OpenStack runs for the same
/// problem. CoreDNS is that helper.
///
/// The cost is real — a process per network with a local NIC, not per VM — and
/// bounded by networks-per-chassis. ADR 0007 records why it is the trade taken.
///
/// ## Why this is not part of the network reconcile's authority half
///
/// A resolver serves the guests on *this* host, so it runs wherever they do,
/// including on agents that may not author topology. Its input is the same
/// per-NIC opt-out the chassis namespace uses, and it converges alongside it —
/// before the authority guard.
actor ResolverSupervisor {
    private let root: String
    private let binaryPath: String
    private let ipBinaryPath: String?
    private let logger: Logger

    /// What this supervisor believes about each network it serves. Rebuilt from
    /// disk on the first pass after a restart — see `adoptFromDisk`.
    private var state: [UUID: ResolverState] = [:]
    private var adopted = false

    private struct ResolverState {
        var process: ProcessRunner.SpawnedProcess?
        /// A process this agent did not fork — one a previous incarnation
        /// started and this one adopted. There is no `Process` handle for it,
        /// so liveness is probed by pid instead.
        var adoptedPID: Int32?
        var configurationDigest: String?
        var consecutiveFailures = 0
        /// When a restart may next be attempted. Nil means immediately.
        var nextStartAllowedAt: Date?

        /// Whether something is serving this network right now.
        ///
        /// The adopted arm is load-bearing: without it an adopted CoreDNS reads
        /// as "not running" on the first reconcile after an agent restart, and
        /// the supervisor starts a **second** one into the same namespace —
        /// which then fails to bind :53 and crash-loops beside a perfectly
        /// healthy resolver.
        var isRunning: Bool {
            if let process { return process.isRunning }
            if let adoptedPID { return ProcessRunner.isAlive(pid: adoptedPID) }
            return false
        }
    }

    init(root: String, binaryPath: String, ipBinaryPath: String?, logger: Logger) {
        self.root = root
        self.binaryPath = binaryPath
        self.ipBinaryPath = ipBinaryPath
        self.logger = logger
    }

    /// Converge this host's resolvers toward `desired`.
    ///
    /// Nil ≙ a sync with no opinion, which stops nothing — the contract every
    /// other level-triggered list in the agent carries, and the one that matters
    /// most here: a control plane rolled back below v37 must not take DNS away
    /// from every network on the host on its way past.
    func reconcile(_ desired: [DesiredResolver]?) async {
        guard let desired else { return }
        if !adopted {
            await adoptFromDisk()
            adopted = true
        }

        let observed = state.map { networkId, current in
            ObservedResolver(
                networkId: networkId,
                pid: current.process?.processIdentifier ?? current.adoptedPID,
                running: current.isRunning,
                configurationDigest: current.configurationDigest,
                consecutiveFailures: current.consecutiveFailures)
        }
        let byNetwork = Dictionary(
            desired.map { ($0.networkId, $0) }, uniquingKeysWith: { first, _ in first })

        for action in ResolverSupervisionPolicy.actions(desired: desired, observed: observed) {
            switch action {
            case .writeConfiguration(let networkId):
                guard let resolver = byNetwork[networkId] else { continue }
                write(resolver)
            case .start(let networkId):
                guard let resolver = byNetwork[networkId] else { continue }
                await start(resolver)
            case .stop(let networkId):
                await stop(networkId: networkId)
            }
        }
    }

    /// Stops every resolver, for agent shutdown. Without this a restarted agent
    /// would adopt processes whose configuration it is about to rewrite, which
    /// is fine, but a *stopping* agent leaving them behind means a host draining
    /// its workloads keeps answering for networks it no longer serves.
    func shutdown() async {
        for networkId in state.keys { await stop(networkId: networkId) }
    }

    // MARK: - Effects

    /// Writes the rendered files, then deletes any zone file the rendering no
    /// longer contains.
    ///
    /// Writes are atomic per file, the `VMManifestStore` idiom: CoreDNS's `file`
    /// plugin watches these for changes and would otherwise be racing a partial
    /// write, which costs it the zone until the next edit rather than until the
    /// write finishes.
    private func write(_ resolver: DesiredResolver) {
        let layout = ResolverDirectoryLayout(root: root, networkId: resolver.networkId)
        do {
            try FileManager.default.createDirectory(
                atPath: layout.zonesDirectory, withIntermediateDirectories: true)
            for file in resolver.files {
                let path = "\(layout.directory)/\(file.relativePath)"
                try Data(file.contents.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            }
            // Sweep zone files the rendering dropped — a zone renamed, detached,
            // or deleted. The Corefile stops referencing them, so they are inert
            // to CoreDNS, but a stale zone file on the host is a name an
            // operator reading the directory will believe is still served.
            let expected = ResolverSupervisionPolicy.expectedRelativePaths(resolver)
            let existing =
                (try? FileManager.default.contentsOfDirectory(atPath: layout.zonesDirectory)) ?? []
            for name in existing where !expected.contains("zones/\(name)") {
                try? FileManager.default.removeItem(atPath: "\(layout.zonesDirectory)/\(name)")
            }
            state[resolver.networkId, default: ResolverState()].configurationDigest =
                resolver.configurationDigest
            for diagnostic in resolver.diagnostics {
                logger.warning(
                    "Resolver zone rendering skipped a record",
                    metadata: [
                        "networkId": .string(resolver.networkId.uuidString),
                        "detail": .string(diagnostic),
                    ])
            }
        } catch {
            logger.error(
                "Failed to write resolver configuration",
                metadata: [
                    "networkId": .string(resolver.networkId.uuidString),
                    "error": .string(error.localizedDescription),
                ])
            // Leave the digest unset so the next pass rewrites and retries
            // rather than believing the files on disk match what was rendered.
            state[resolver.networkId, default: ResolverState()].configurationDigest = nil
        }
    }

    private func start(_ resolver: DesiredResolver) async {
        let networkId = resolver.networkId
        var current = state[networkId] ?? ResolverState()
        if let allowed = current.nextStartAllowedAt, allowed > Date() {
            // Still inside the backoff window. Returning silently is deliberate:
            // this runs on every sync, and a log line per suppressed retry would
            // drown the one that explains the failure.
            state[networkId] = current
            return
        }
        // Nothing was written for this network yet — the write failed, and
        // starting CoreDNS against a missing or half-written Corefile is how a
        // crash loop starts.
        guard current.configurationDigest != nil else {
            state[networkId] = current
            return
        }

        let layout = ResolverDirectoryLayout(root: root, networkId: networkId)
        // `ip netns exec` rather than entering the namespace ourselves, for the
        // reason in the type doc: `setns` is per-thread and Swift concurrency
        // moves continuations between threads.
        guard let ipBinaryPath else {
            logger.warning(
                "The per-network resolver needs the iproute2 `ip` tool, which was not found",
                metadata: ["networkId": .string(networkId.uuidString)])
            return
        }
        do {
            // The pid is not known until `spawn` returns, and the exit handler
            // may fire before then for a child that dies immediately — so the
            // handler defers to `recordExit`, which re-checks the recorded pid
            // and ignores an exit for a process this supervisor has already
            // replaced or stopped.
            let spawned = try ProcessRunner.spawn(
                executableURL: URL(fileURLWithPath: ipBinaryPath),
                arguments: [
                    "netns", "exec", ChassisServicePlan.netnsName(networkId: networkId),
                    binaryPath, "-conf", "Corefile",
                ],
                workingDirectory: layout.directory,
                logPath: "\(layout.directory)/coredns.log",
                onExit: { [weak self] status in
                    Task { await self?.recordExit(networkId: networkId, status: status) }
                })
            try? Data(String(spawned.processIdentifier).utf8)
                .write(to: URL(fileURLWithPath: layout.pidFilePath), options: .atomic)
            current.process = spawned
            current.adoptedPID = nil
            current.nextStartAllowedAt = nil
            // "Since the last successful run" is what `consecutiveFailures`
            // claims to count. Without this reset it counts lifetime exits
            // instead, so a normal restart during a zone edit days later reports
            // a crash loop and the backoff ratchets to the cap and stays there.
            current.consecutiveFailures = 0
            state[networkId] = current
            logger.info(
                "Started per-network resolver",
                metadata: [
                    "networkId": .string(networkId.uuidString),
                    "pid": .stringConvertible(spawned.processIdentifier),
                ])
        } catch {
            current.consecutiveFailures += 1
            current.nextStartAllowedAt = Date().addingTimeInterval(
                delaySeconds(current.consecutiveFailures))
            state[networkId] = current
            log(failure: error.localizedDescription, networkId: networkId, state: current)
        }
    }

    /// Records a child's exit, so the next sync restarts it.
    ///
    /// The restart is driven by the reconcile pass rather than from here: a sync
    /// arrives at least every `desired_state_full_refetch_seconds`, so a dead
    /// resolver is picked up without this actor having to own a timer, and the
    /// backoff stays a property of the state it is stored beside.
    private func recordExit(networkId: UUID, status: Int32) {
        // An exit for a process this supervisor has already replaced or stopped
        // is not this network's current failure. `isRunning` is the test rather
        // than a pid compare: the handler can fire before `spawn` returns, so
        // the pid may not have been recorded yet.
        guard var current = state[networkId], current.process?.isRunning == false else { return }
        current.process = nil
        current.consecutiveFailures += 1
        current.nextStartAllowedAt = Date().addingTimeInterval(delaySeconds(current.consecutiveFailures))
        state[networkId] = current
        log(failure: "exited with status \(status)", networkId: networkId, state: current)
    }

    private func stop(networkId: UUID) async {
        // The pid this call is stopping, captured before the suspensions below.
        // `terminate` sleeps through its SIGTERM→SIGKILL grace, and a reconcile
        // can interleave in that window: if it re-desires the network it will
        // see `isRunning == false` and start a fresh CoreDNS, whose handle this
        // call would then discard along with its config directory — leaving an
        // unsupervised process holding :53 that nothing can ever find again.
        let stopping = state[networkId]?.process?.processIdentifier ?? state[networkId]?.adoptedPID
        if let process = state[networkId]?.process {
            await process.terminate()
        } else if let pid = state[networkId]?.adoptedPID, ProcessRunner.isAlive(pid: pid) {
            // No `Process` handle for an adopted child, so signal it by pid with
            // the same escalation. Without this a drained host keeps answering
            // for networks it no longer converges — and the directory removal
            // below would leave that process serving files that are gone.
            kill(pid, SIGTERM)
            try? await Task.sleep(for: ProcessRunner.signalEscalationGrace)
            if ProcessRunner.isAlive(pid: pid) { kill(pid, SIGKILL) }
        }
        // Re-read after the suspension: if the entry now names a different
        // process, a reconcile started one while this call was sleeping and it
        // is not ours to reap.
        let current = state[networkId]?.process?.processIdentifier ?? state[networkId]?.adoptedPID
        guard current == stopping else { return }
        state[networkId] = nil
        let layout = ResolverDirectoryLayout(root: root, networkId: networkId)
        try? FileManager.default.removeItem(atPath: layout.directory)
        logger.info(
            "Stopped per-network resolver", metadata: ["networkId": .string(networkId.uuidString)])
    }

    // MARK: - Restart adoption

    /// Rebuilds state from disk on the first pass after an agent restart.
    ///
    /// A CoreDNS started by a previous agent process is still serving its
    /// network, and killing it to start an identical one would cost that network
    /// its resolver for the length of a process start — for nothing. So a
    /// recorded pid that is still alive is *adopted*: left running, and its
    /// configuration rewritten in place if the desired state has moved.
    ///
    /// Adoption is deliberately weak. The agent cannot re-parent a process it
    /// did not fork, so it holds no `Process` handle for an adopted child and
    /// cannot observe its exit; what it records instead is "something is serving
    /// this network", which the next reconcile re-checks. A pid that has been
    /// recycled onto an unrelated process is the failure mode, and the
    /// `/proc/<pid>/cmdline` check below is what makes that vanishingly
    /// unlikely — a recycled pid running *this* agent's CoreDNS binary in *this*
    /// network's directory is a process that would be doing the right thing
    /// anyway.
    private func adoptFromDisk() async {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        for entry in entries {
            guard let networkId = UUID(uuidString: entry) else { continue }
            let layout = ResolverDirectoryLayout(root: root, networkId: networkId)
            guard let raw = try? String(contentsOfFile: layout.pidFilePath, encoding: .utf8),
                let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                ProcessRunner.isAlive(pid: pid),
                commandLine(ofPID: pid).contains(binaryPath)
            else {
                // Nothing alive is serving this network. Remove the directory
                // outright rather than leaving it for the reconcile: if the
                // network is still wanted the next pass rewrites it from desired
                // state, and if it is not, this is the only thing that would
                // ever have swept it.
                try? FileManager.default.removeItem(atPath: layout.directory)
                continue
            }
            // No digest recorded: the adopted process's configuration is
            // whatever the previous agent wrote, and the first reconcile should
            // rewrite it rather than assume it still matches desired state. The
            // rewrite costs no restart — the Corefile's `reload` and the `file`
            // plugin's watch are what the adopted process picks it up with.
            state[networkId] = ResolverState(process: nil, adoptedPID: pid, configurationDigest: nil)
            logger.info(
                "Adopted a running per-network resolver",
                metadata: [
                    "networkId": .string(networkId.uuidString), "pid": .stringConvertible(pid),
                ])
        }
    }

    private nonisolated func commandLine(ofPID pid: Int32) -> String {
        guard let data = FileManager.default.contents(atPath: "/proc/\(pid)/cmdline") else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Helpers

    private nonisolated func delaySeconds(_ failures: Int) -> TimeInterval {
        let delay = ResolverSupervisionPolicy.restartDelay(consecutiveFailures: failures)
        return TimeInterval(delay.components.seconds)
    }

    private func log(failure: String, networkId: UUID, state current: ResolverState) {
        let metadata: Logger.Metadata = [
            "networkId": .string(networkId.uuidString),
            "failures": .stringConvertible(current.consecutiveFailures),
            "detail": .string(failure),
        ]
        // Below the threshold this is what a restart during a zone edit looks
        // like; above it, something is wrong that a retry will not fix.
        if ResolverSupervisionPolicy.isCrashLooping(consecutiveFailures: current.consecutiveFailures) {
            logger.error("Per-network resolver is crash-looping", metadata: metadata)
        } else {
            logger.warning("Per-network resolver exited; will restart", metadata: metadata)
        }
    }
}
