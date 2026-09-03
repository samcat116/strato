import Foundation
import Logging
import StratoAgentCore
import Synchronization

/// The host effects behind `ResolverSupervisor` (STR-40): files on disk, and one
/// CoreDNS in the *host* namespace serving every network on this hypervisor.
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
        let layout = ResolverDirectoryLayout(root: root)
        for file in resolver.files {
            let path = "\(layout.directory)/\(file.relativePath)"
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try Data(file.contents.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        // Sweep files the rendering dropped — a zone renamed or detached, or a
        // whole network's directory once it stops wanting a resolver. The
        // Corefile stops referencing them, so they are inert to CoreDNS, but a
        // stale zone file on the host is a name an operator reading the
        // directory will believe is still served.
        let expected = ResolverSupervisionPolicy.expectedRelativePaths(resolver)
        for relative in existingRelativePaths(under: layout.zonesDirectory, root: layout.directory)
        where !expected.contains(relative) {
            try? FileManager.default.removeItem(atPath: "\(layout.directory)/\(relative)")
        }
        pruneEmptyDirectories(under: layout.zonesDirectory)
    }

    func removeConfiguration(root: String) {
        try? FileManager.default.removeItem(atPath: ResolverDirectoryLayout(root: root).directory)
    }

    /// Every rendered file currently on disk, as paths relative to the resolver
    /// root — the same shape `expectedRelativePaths` returns, so the two can be
    /// differenced directly.
    private func existingRelativePaths(under zones: String, root: String) -> [String] {
        guard let walker = FileManager.default.enumerator(atPath: zones) else { return [] }
        var found: [String] = []
        for case let entry as String in walker {
            let full = "\(zones)/\(entry)"
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory),
                !isDirectory.boolValue
            else { continue }
            found.append(String(full.dropFirst(root.count + 1)))
        }
        return found
    }

    /// Removes per-network zone directories left empty by the sweep, so the
    /// directory listing keeps matching what is served.
    private func pruneEmptyDirectories(under zones: String) {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: zones)) ?? []
        for entry in entries {
            let path = "\(zones)/\(entry)"
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            if contents.isEmpty { try? FileManager.default.removeItem(atPath: path) }
        }
    }

    // MARK: - Process

    func spawn(
        root: String, onExit: @escaping @Sendable () async -> Void
    ) throws -> any ResolverHandle {
        let layout = ResolverDirectoryLayout(root: root)
        // No `ip netns exec`: the resolver runs in the *host* namespace, which
        // is the whole point — forwarding upstream is then the hypervisor's own
        // routing, which a chassis namespace could never provide.
        //
        // The exit *time* is stamped from the termination handler, which is the
        // only place that knows it. The same handler wakes the supervisor so a
        // crash-looping child schedules its next backoff without waiting for a
        // desired-state reconciliation.
        let exit = ExitStamp()
        let spawned = try ProcessRunner.spawn(
            executableURL: URL(fileURLWithPath: binaryPath),
            arguments: ["-conf", "Corefile"],
            workingDirectory: layout.directory,
            logPath: "\(layout.directory)/coredns.log",
            onExit: { _ in
                exit.stamp()
                Task { await onExit() }
            })
        try? Data(String(spawned.processIdentifier).utf8)
            .write(to: URL(fileURLWithPath: layout.pidFilePath), options: .atomic)
        return SpawnedResolverHandle(process: spawned, exit: exit)
    }

    /// A resolver a previous agent process left running.
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
    func adoptable(root: String) -> AdoptableResolver? {
        let layout = ResolverDirectoryLayout(root: root)
        guard let raw = try? String(contentsOfFile: layout.pidFilePath, encoding: .utf8),
            let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
            ProcessRunner.isAlive(pid: pid),
            commandLine(ofPID: pid).contains(binaryPath)
        else {
            // Nothing alive is serving. The directory is left for the reconcile
            // to rewrite rather than removed: unlike the per-network layout it
            // replaced, this one directory holds every network's zones, and the
            // next pass rewrites all of them from desired state anyway.
            return nil
        }
        return AdoptableResolver(pid: pid)
    }

    func isAlive(pid: Int32) -> Bool { ProcessRunner.isAlive(pid: pid) }

    /// Signal a process this agent did not fork, and so holds no handle for,
    /// with the same escalation `SpawnedProcess.terminate` uses.
    func terminate(pid: Int32) async {
        await ProcessRunner.terminateProcess(pid: pid) {
            ProcessRunner.isAlive(pid: pid)
        }
    }

    private func commandLine(ofPID pid: Int32) -> String {
        guard let data = FileManager.default.contents(atPath: "/proc/\(pid)/cmdline") else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// When a child exited, written once from its termination handler.
private final class ExitStamp: Sendable {
    private let value = Mutex<Date?>(nil)

    func stamp() {
        value.withLock { value in
            if value == nil { value = Date() }
        }
    }

    var date: Date? {
        value.withLock { $0 }
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
