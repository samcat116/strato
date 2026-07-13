import Crypto
import Foundation
import Logging
import StratoShared

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(Glibc)
import Glibc
#endif

// MARK: - Install mode

/// How this agent process is installed on the host, deciding whether it may
/// replace its own binary.
public enum AgentInstallMode: Sendable, Equatable {
    /// A bare binary under a process supervisor (systemd, launchd, a shell):
    /// self-update may swap the executable and exit for the supervisor to
    /// restart it.
    case supervisedBinary
    /// Inside a container; `marker` names the evidence. The binary is part of
    /// an immutable image layer — updates ship as a new image — so self-update
    /// refuses.
    case container(marker: String)

    /// Detects the install mode. The explicit `STRATO_INSTALL_MODE` variable
    /// (baked into the agent's container image) wins in both directions;
    /// otherwise standard container fingerprints are checked, because agents
    /// deployed from images built before the marker existed must still refuse.
    public static func detect(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        initCGroup: () -> String? = { try? String(contentsOfFile: "/proc/1/cgroup", encoding: .utf8) }
    ) -> AgentInstallMode {
        if let explicit = environment["STRATO_INSTALL_MODE"] {
            return explicit == "container"
                ? .container(marker: "STRATO_INSTALL_MODE") : .supervisedBinary
        }
        if fileExists("/.dockerenv") {
            return .container(marker: "/.dockerenv")
        }
        if fileExists("/run/.containerenv") {
            return .container(marker: "/run/.containerenv")
        }
        if let cgroup = initCGroup(),
            cgroup.contains("docker") || cgroup.contains("containerd") || cgroup.contains("kubepods")
        {
            return .container(marker: "/proc/1/cgroup")
        }
        return .supervisedBinary
    }
}

// MARK: - Errors

public enum AgentUpdateError: Error, CustomStringConvertible, Equatable {
    /// The agent runs in a container; its binary is managed externally.
    case managedExternally(marker: String)
    case unresolvableBinaryPath
    case binaryDirectoryNotWritable(String)
    case invalidArtifactURL(String)
    case downloadFailed(String)
    case checksumMismatch(expected: String, actual: String)
    case extractionFailed(String)
    case probeFailed(String)
    case swapFailed(String)

    public var description: String {
        switch self {
        case .managedExternally(let marker):
            return
                "this agent runs in a container (detected via \(marker)); its binary is managed externally — update the image instead"
        case .unresolvableBinaryPath:
            return "could not resolve the running agent binary's path"
        case .binaryDirectoryNotWritable(let dir):
            return "binary directory \(dir) is not writable by the agent process"
        case .invalidArtifactURL(let url):
            return "invalid artifact URL: \(url)"
        case .downloadFailed(let detail):
            return "artifact download failed: \(detail)"
        case .checksumMismatch(let expected, let actual):
            return "artifact checksum mismatch: expected sha256 \(expected), got \(actual)"
        case .extractionFailed(let detail):
            return "artifact extraction failed: \(detail)"
        case .probeFailed(let detail):
            return "staged binary failed its execution probe: \(detail)"
        case .swapFailed(let detail):
            return "binary swap failed: \(detail)"
        }
    }
}

// MARK: - Updater

/// The result of a successful update: the new binary is live at `binaryPath`
/// and the replaced one is preserved at `previousBinaryPath` for manual
/// rollback of a crash-looping update.
public struct AgentUpdateOutcome: Sendable {
    public let binaryPath: String
    public let previousBinaryPath: String
}

/// Replaces the running agent's binary with a downloaded artifact (issue #432).
///
/// The sequence mirrors the staging + atomic-publish pattern of
/// `materializeDisk` and `FileAgentStateStore.save`: all work happens in a
/// hidden workspace inside the binary's own directory (same filesystem, so the
/// final `rename(2)` is atomic), the artifact's SHA-256 is verified before
/// anything is touched, the staged binary must prove it executes, and the old
/// binary survives as `<binary>.prev`. Any failure before the final rename
/// leaves the running binary untouched.
///
/// The updater deliberately does NOT restart anything: the caller replies to
/// the control plane, shuts the agent down cleanly, and exits with
/// `AgentUpdater.restartExitCode` for the supervisor to start the new binary.
public struct AgentUpdater: Sendable {
    /// Downloads `url` into the file at the given destination path.
    public typealias Downloader = @Sendable (URL, _ destination: String) async throws -> Void
    /// Proves a staged binary executes (default: run it with `--version` and
    /// require exit 0). Throwing fails the update with the old binary intact.
    public typealias BinaryProbe = @Sendable (_ stagedBinary: String) async throws -> Void

    /// Exit code the agent process ends with after a successful swap, chosen
    /// non-zero so a systemd unit with `Restart=on-failure` (what
    /// `deploy/agent/install.sh` writes) restarts it into the new binary.
    /// 75 is EX_TEMPFAIL: "temporary failure, retry" — the closest sysexits
    /// semantic to "start me again".
    public static let restartExitCode: Int32 = 75

    private let logger: Logger
    private let installMode: AgentInstallMode
    private let binaryPathOverride: String?
    private let download: Downloader
    private let probe: BinaryProbe?
    private let runSubprocess: SubprocessRunner

    public init(
        logger: Logger,
        installMode: AgentInstallMode = .detect(),
        binaryPath: String? = nil,
        download: @escaping Downloader = AgentUpdater.defaultDownload,
        probe: BinaryProbe? = nil,
        runSubprocess: @escaping SubprocessRunner = { try await ProcessRunner.run(executableURL: $0, arguments: $1) }
    ) {
        self.logger = logger
        self.installMode = installMode
        self.binaryPathOverride = binaryPath
        self.download = download
        self.probe = probe
        self.runSubprocess = runSubprocess
    }

    /// Downloads, verifies, and atomically installs a new agent binary.
    /// On return the file at the running binary's path is the new build; the
    /// caller still needs to exit and be restarted for it to take effect.
    public func applyUpdate(
        artifactURL: String,
        sha256: String,
        artifactKind: AgentUpdateArtifactKind,
        tarballMember: String?
    ) async throws -> AgentUpdateOutcome {
        if case .container(let marker) = installMode {
            throw AgentUpdateError.managedExternally(marker: marker)
        }
        guard let url = URL(string: artifactURL), let scheme = url.scheme,
            ["https", "http", "file"].contains(scheme.lowercased())
        else {
            // Redacted: the error travels into logs on both sides, and the
            // URL's query string may be a presigned credential.
            throw AgentUpdateError.invalidArtifactURL(AgentUpdateMessage.redactURL(artifactURL))
        }

        let binaryPath = try resolveBinaryPath()
        let directory = (binaryPath as NSString).deletingLastPathComponent
        // Fail before downloading anything if the swap could never succeed.
        guard FileManager.default.isWritableFile(atPath: directory) else {
            throw AgentUpdateError.binaryDirectoryNotWritable(directory)
        }

        // All staging lives in a hidden workspace next to the binary: same
        // filesystem as the final path (the rename below stays atomic) and one
        // directory to clean up on any exit path.
        let workspace = directory + "/.strato-agent-update-" + UUID().uuidString
        try FileManager.default.createDirectory(
            atPath: workspace, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: workspace) }

        logger.info(
            "Downloading agent update artifact",
            metadata: [
                "url": .string(AgentUpdateMessage.redactURL(artifactURL)),
                "kind": .string(artifactKind.rawValue),
            ])
        let artifactPath = workspace + "/artifact"
        try await download(url, artifactPath)

        let actualDigest = try Self.sha256Hex(ofFileAt: artifactPath)
        let expectedDigest = sha256.lowercased()
        guard actualDigest == expectedDigest else {
            throw AgentUpdateError.checksumMismatch(expected: expectedDigest, actual: actualDigest)
        }

        let stagedBinary: String
        switch artifactKind {
        case .binary:
            stagedBinary = artifactPath
        case .tarball:
            let member = tarballMember ?? "strato-agent"
            let result = try await runSubprocess(
                URL(fileURLWithPath: "/usr/bin/tar"),
                ["-xzf", artifactPath, "-C", workspace, member])
            guard result.terminationStatus == 0 else {
                throw AgentUpdateError.extractionFailed(
                    "tar exited \(result.terminationStatus): \(result.combinedOutput)")
            }
            stagedBinary = workspace + "/" + member
            guard FileManager.default.fileExists(atPath: stagedBinary) else {
                throw AgentUpdateError.extractionFailed("tarball did not contain member '\(member)'")
            }
        }

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: stagedBinary)

        // A checksum only proves we got the file the control plane pointed at,
        // not that the file is a working binary for this host — a wrong-arch
        // or truncated artifact would otherwise crash-loop under the
        // supervisor. Require the staged binary to actually execute.
        if let probe {
            try await probe(stagedBinary)
        } else {
            let result: ProcessResult
            do {
                result = try await runSubprocess(URL(fileURLWithPath: stagedBinary), ["--version"])
            } catch {
                throw AgentUpdateError.probeFailed("could not execute staged binary: \(error)")
            }
            guard result.terminationStatus == 0 else {
                throw AgentUpdateError.probeFailed(
                    "--version exited \(result.terminationStatus): \(result.combinedOutput)")
            }
        }

        // Preserve the current binary as .prev via a hard link (no window with
        // a missing binary: the old inode stays reachable while the rename
        // atomically replaces the path). Falls back to a copy on filesystems
        // without hard links.
        let previousPath = binaryPath + ".prev"
        try? FileManager.default.removeItem(atPath: previousPath)
        do {
            try FileManager.default.linkItem(atPath: binaryPath, toPath: previousPath)
        } catch {
            do {
                try FileManager.default.copyItem(atPath: binaryPath, toPath: previousPath)
            } catch {
                throw AgentUpdateError.swapFailed("could not preserve current binary: \(error)")
            }
        }

        // Raw rename(2), like FileAgentStateStore.save: atomic replacement of
        // an existing destination on both Linux and macOS.
        let renameResult = stagedBinary.withCString { staged in
            binaryPath.withCString { destination in
                rename(staged, destination)
            }
        }
        guard renameResult == 0 else {
            let detail = String(cString: strerror(errno))
            // The swap never happened; drop the redundant .prev so a retry
            // starts from the pre-attempt state.
            try? FileManager.default.removeItem(atPath: previousPath)
            throw AgentUpdateError.swapFailed("rename to \(binaryPath): \(detail)")
        }

        logger.notice(
            "Agent binary replaced; previous build preserved",
            metadata: [
                "binaryPath": .string(binaryPath),
                "previousBinaryPath": .string(previousPath),
            ])
        return AgentUpdateOutcome(binaryPath: binaryPath, previousBinaryPath: previousPath)
    }

    // MARK: - Helpers

    private func resolveBinaryPath() throws -> String {
        if let binaryPathOverride { return binaryPathOverride }
        #if os(Linux)
        if let resolved = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe") {
            return resolved
        }
        #endif
        if let path = Bundle.main.executablePath { return path }
        throw AgentUpdateError.unresolvableBinaryPath
    }

    /// Streaming SHA-256 so a multi-hundred-MB artifact is never held in memory.
    static func sha256Hex(ofFileAt path: String) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw AgentUpdateError.downloadFailed("downloaded artifact missing at \(path)")
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @Sendable
    public static func defaultDownload(from url: URL, to destination: String) async throws {
        // Local file artifacts (air-gapped hosts: the operator copies the
        // artifact onto the node and passes a file:// override). URLSession
        // rejects file URLs on Linux, so copy directly — the checksum is
        // still verified against the copy before anything is swapped.
        if url.isFileURL {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw AgentUpdateError.downloadFailed("no file at \(url.path)")
            }
            do {
                try FileManager.default.copyItem(atPath: url.path, toPath: destination)
            } catch {
                throw AgentUpdateError.downloadFailed("could not copy local artifact: \(error)")
            }
            return
        }

        let temporaryURL: URL
        let response: URLResponse
        do {
            (temporaryURL, response) = try await URLSession.shared.download(from: url)
        } catch {
            throw AgentUpdateError.downloadFailed("\(error)")
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw AgentUpdateError.downloadFailed(
                "HTTP \(http.statusCode) from \(AgentUpdateMessage.redactURL(url.absoluteString))")
        }
        do {
            try FileManager.default.moveItem(atPath: temporaryURL.path, toPath: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw AgentUpdateError.downloadFailed("could not move download into staging: \(error)")
        }
    }
}
