import Foundation
import Logging
import StratoAgentCore

/// The host effects behind `ResolverSupervisor` (STR-40): files on disk, and a
/// CoreDNS forked into a network's chassis namespace.
///
/// Split from the supervisor so the lifecycle above it can be asserted without a
/// namespace or a process, the shape `MetadataServerProcessSpawner` takes for
/// `MetadataServerSupervisor`. Everything here is the part a test would have had
/// to fake anyway.
struct ResolverProcessHost: ResolverHosting {
    let binaryPath: String
    let ipBinaryPath: String
    let logger: Logger

    // MARK: - Configuration

    /// Writes the rendered files, then deletes any zone file the rendering no
    /// longer contains.
    ///
    /// Writes are atomic per file, the `VMManifestStore` idiom: CoreDNS's `file`
    /// plugin watches these for changes and would otherwise be racing a partial
    /// write, which costs it the zone until the next edit rather than until the
    /// write finishes.
    func writeConfiguration(_ resolver: DesiredResolver, root: String) throws {
        let layout = ResolverDirectoryLayout(root: root, networkId: resolver.networkId)
        try FileManager.default.createDirectory(
            atPath: layout.zonesDirectory, withIntermediateDirectories: true)
        for file in resolver.files {
            let path = "\(layout.directory)/\(file.relativePath)"
            try Data(file.contents.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        // Sweep zone files the rendering dropped — a zone renamed, detached, or
        // deleted. The Corefile stops referencing them, so they are inert to
        // CoreDNS, but a stale zone file on the host is a name an operator
        // reading the directory will believe is still served.
        let expected = ResolverSupervisionPolicy.expectedRelativePaths(resolver)
        let existing =
            (try? FileManager.default.contentsOfDirectory(atPath: layout.zonesDirectory)) ?? []
        for name in existing where !expected.contains("zones/\(name)") {
            try? FileManager.default.removeItem(atPath: "\(layout.zonesDirectory)/\(name)")
        }
    }

    func removeConfiguration(networkId: UUID, root: String) {
        let layout = ResolverDirectoryLayout(root: root, networkId: networkId)
        try? FileManager.default.removeItem(atPath: layout.directory)
    }

    // MARK: - Process

    func spawn(networkId: UUID, root: String) throws -> any ResolverHandle {
        let layout = ResolverDirectoryLayout(root: root, networkId: networkId)
        // `ip netns exec` rather than entering the namespace ourselves: `setns`
        // is per-thread and Swift concurrency moves continuations between
        // threads.
        // The exit *time* is stamped from the termination handler, which is the
        // only place that knows it: the supervisor notices exits on its next
        // reconcile, which may be minutes later, and it judges a run by how long
        // it lasted rather than by how long ago it was noticed.
        let exit = ExitStamp()
        let spawned = try ProcessRunner.spawn(
            executableURL: URL(fileURLWithPath: ipBinaryPath),
            arguments: [
                "netns", "exec", ChassisServicePlan.netnsName(networkId: networkId),
                binaryPath, "-conf", "Corefile",
            ],
            workingDirectory: layout.directory,
            logPath: "\(layout.directory)/coredns.log",
            onExit: { _ in exit.stamp() })
        try? Data(String(spawned.processIdentifier).utf8)
            .write(to: URL(fileURLWithPath: layout.pidFilePath), options: .atomic)
        return SpawnedResolverHandle(process: spawned, exit: exit)
    }

    /// Resolvers a previous agent process left running.
    ///
    /// A pid file whose process is gone — or has been recycled onto something
    /// else — is not adoptable, and its directory is removed rather than left
    /// for the reconcile: if the network is still wanted the next pass rewrites
    /// it from desired state, and if it is not, this is the only thing that
    /// would ever have swept it.
    ///
    /// The `/proc/<pid>/cmdline` check is what makes pid recycling
    /// vanishingly unlikely to matter: a recycled pid running *this* agent's
    /// CoreDNS binary is a process that would be doing the right thing anyway.
    func adoptable(root: String) -> [AdoptableResolver] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        var found: [AdoptableResolver] = []
        for entry in entries.sorted() {
            guard let networkId = UUID(uuidString: entry) else { continue }
            let layout = ResolverDirectoryLayout(root: root, networkId: networkId)
            guard let raw = try? String(contentsOfFile: layout.pidFilePath, encoding: .utf8),
                let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                ProcessRunner.isAlive(pid: pid),
                commandLine(ofPID: pid).contains(binaryPath)
            else {
                try? FileManager.default.removeItem(atPath: layout.directory)
                continue
            }
            found.append(AdoptableResolver(networkId: networkId, pid: pid))
        }
        return found
    }

    func isAlive(pid: Int32) -> Bool { ProcessRunner.isAlive(pid: pid) }

    /// Signal a process this agent did not fork, and so holds no handle for,
    /// with the same escalation `SpawnedProcess.terminate` uses.
    func terminate(pid: Int32) async {
        guard ProcessRunner.isAlive(pid: pid) else { return }
        kill(pid, SIGTERM)
        try? await Task.sleep(for: ProcessRunner.signalEscalationGrace)
        if ProcessRunner.isAlive(pid: pid) { kill(pid, SIGKILL) }
    }

    private func commandLine(ofPID pid: Int32) -> String {
        guard let data = FileManager.default.contents(atPath: "/proc/\(pid)/cmdline") else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// When a child exited, written once from its termination handler.
private final class ExitStamp: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date?

    func stamp() {
        lock.lock()
        if value == nil { value = Date() }
        lock.unlock()
    }

    var date: Date? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// A CoreDNS this agent forked.
private struct SpawnedResolverHandle: ResolverHandle {
    let process: ProcessRunner.SpawnedProcess
    let exit: ExitStamp

    var isRunning: Bool { process.isRunning }
    var processIdentifier: Int32 { process.processIdentifier }
    var exitedAt: Date? { exit.date }
    func terminate() async { await process.terminate() }
}
