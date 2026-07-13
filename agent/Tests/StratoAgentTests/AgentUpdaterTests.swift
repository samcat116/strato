import Crypto
import Foundation
import Logging
import StratoShared
import Testing

@testable import StratoAgentCore

@Suite("Agent Updater Tests")
struct AgentUpdaterTests {

    private let logger = Logger(label: "test.agent-updater")

    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "agent-updater-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ content: String, to path: String, executable: Bool = false) throws {
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
    }

    private func sha256Hex(of content: String) -> String {
        SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A downloader that "fetches" by copying a local fixture file.
    private func fixtureDownloader(from fixturePath: String) -> AgentUpdater.Downloader {
        { _, destination in
            try FileManager.default.copyItem(atPath: fixturePath, toPath: destination)
        }
    }

    private let noopProbe: AgentUpdater.BinaryProbe = { _ in }

    // MARK: - Install-mode detection

    @Test("Explicit container marker refuses in both directions")
    func installModeExplicitMarker() {
        let container = AgentInstallMode.detect(
            environment: ["STRATO_INSTALL_MODE": "container"],
            fileExists: { _ in false },
            initCGroup: { nil }
        )
        #expect(container == .container(marker: "STRATO_INSTALL_MODE"))

        // An explicit non-container value overrides fingerprints — the escape
        // hatch for hosts that look containerized but manage a real binary.
        let overridden = AgentInstallMode.detect(
            environment: ["STRATO_INSTALL_MODE": "binary"],
            fileExists: { path in path == "/.dockerenv" },
            initCGroup: { nil }
        )
        #expect(overridden == .supervisedBinary)
    }

    @Test("Container fingerprints are detected without the marker")
    func installModeFingerprints() {
        let docker = AgentInstallMode.detect(
            environment: [:],
            fileExists: { path in path == "/.dockerenv" },
            initCGroup: { nil }
        )
        #expect(docker == .container(marker: "/.dockerenv"))

        let kubernetes = AgentInstallMode.detect(
            environment: [:],
            fileExists: { _ in false },
            initCGroup: { "12:memory:/kubepods/besteffort/pod1234" }
        )
        #expect(kubernetes == .container(marker: "/proc/1/cgroup"))

        let bare = AgentInstallMode.detect(
            environment: [:],
            fileExists: { _ in false },
            initCGroup: { "0::/init.scope" }
        )
        #expect(bare == .supervisedBinary)
    }

    // MARK: - Refusals that leave the binary untouched

    @Test("Containerized agents refuse with a managed-externally error")
    func containerRefusal() async throws {
        let updater = AgentUpdater(
            logger: logger,
            installMode: .container(marker: "/.dockerenv"),
            binaryPath: "/irrelevant/strato-agent"
        )
        await #expect(throws: AgentUpdateError.managedExternally(marker: "/.dockerenv")) {
            _ = try await updater.applyUpdate(
                artifactURL: "https://example.com/a.tar.gz",
                sha256: String(repeating: "00", count: 32),
                artifactKind: .binary,
                tarballMember: nil
            )
        }
    }

    @Test("Checksum mismatch aborts with the old binary untouched")
    func checksumMismatchAborts() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let binaryPath = dir + "/strato-agent"
        try write("old build", to: binaryPath, executable: true)
        let fixture = dir + "/artifact-fixture"
        try write("new build", to: fixture)

        let updater = AgentUpdater(
            logger: logger,
            installMode: .supervisedBinary,
            binaryPath: binaryPath,
            download: fixtureDownloader(from: fixture),
            probe: noopProbe
        )

        let wrongDigest = String(repeating: "00", count: 32)
        do {
            _ = try await updater.applyUpdate(
                artifactURL: "https://example.com/strato-agent",
                sha256: wrongDigest,
                artifactKind: .binary,
                tarballMember: nil
            )
            Issue.record("expected checksumMismatch")
        } catch let error as AgentUpdateError {
            guard case .checksumMismatch(let expected, let actual) = error else {
                Issue.record("expected checksumMismatch, got \(error)")
                return
            }
            #expect(expected == wrongDigest)
            #expect(actual == sha256Hex(of: "new build"))
        }

        // The running binary is untouched, no .prev appeared, and the staging
        // workspace was cleaned up.
        let currentBinary = try String(contentsOfFile: binaryPath, encoding: .utf8)
        #expect(currentBinary == "old build")
        #expect(!FileManager.default.fileExists(atPath: binaryPath + ".prev"))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.hasPrefix(".strato-agent-update-") }
        #expect(leftovers.isEmpty)
    }

    @Test("Probe failure aborts with the old binary untouched")
    func probeFailureAborts() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let binaryPath = dir + "/strato-agent"
        try write("old build", to: binaryPath, executable: true)
        let fixture = dir + "/artifact-fixture"
        try write("corrupt build", to: fixture)

        let updater = AgentUpdater(
            logger: logger,
            installMode: .supervisedBinary,
            binaryPath: binaryPath,
            download: fixtureDownloader(from: fixture),
            probe: { _ in throw AgentUpdateError.probeFailed("simulated crash") }
        )

        await #expect(throws: AgentUpdateError.probeFailed("simulated crash")) {
            _ = try await updater.applyUpdate(
                artifactURL: "https://example.com/strato-agent",
                sha256: sha256Hex(of: "corrupt build"),
                artifactKind: .binary,
                tarballMember: nil
            )
        }
        let currentBinary = try String(contentsOfFile: binaryPath, encoding: .utf8)
        #expect(currentBinary == "old build")
        #expect(!FileManager.default.fileExists(atPath: binaryPath + ".prev"))
    }

    // MARK: - Successful swaps

    @Test("Bare-binary update swaps atomically and preserves .prev")
    func binarySwap() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let binaryPath = dir + "/strato-agent"
        try write("old build", to: binaryPath, executable: true)
        let fixture = dir + "/artifact-fixture"
        try write("new build", to: fixture)

        let updater = AgentUpdater(
            logger: logger,
            installMode: .supervisedBinary,
            binaryPath: binaryPath,
            download: fixtureDownloader(from: fixture),
            probe: noopProbe
        )

        let outcome = try await updater.applyUpdate(
            artifactURL: "https://example.com/strato-agent",
            sha256: sha256Hex(of: "new build").uppercased(),  // case-insensitive compare
            artifactKind: .binary,
            tarballMember: nil
        )

        #expect(outcome.binaryPath == binaryPath)
        #expect(outcome.previousBinaryPath == binaryPath + ".prev")
        let swappedBinary = try String(contentsOfFile: binaryPath, encoding: .utf8)
        #expect(swappedBinary == "new build")
        let preservedBinary = try String(contentsOfFile: binaryPath + ".prev", encoding: .utf8)
        #expect(preservedBinary == "old build")

        // The new binary is executable and the workspace is gone.
        let attributes = try FileManager.default.attributesOfItem(atPath: binaryPath)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        #expect(permissions & 0o111 != 0)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.hasPrefix(".strato-agent-update-") }
        #expect(leftovers.isEmpty)
    }

    @Test("Tarball update extracts the agent member before swapping")
    func tarballSwap() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let binaryPath = dir + "/strato-agent"
        try write("old build", to: binaryPath, executable: true)

        // Build a release-shaped tarball: the agent binary plus a sibling
        // member that must be ignored.
        let stage = dir + "/tar-stage"
        try FileManager.default.createDirectory(atPath: stage, withIntermediateDirectories: true)
        try write("new build", to: stage + "/strato-agent", executable: true)
        try write("not the agent", to: stage + "/strato-control-plane", executable: true)
        let tarball = dir + "/strato-test.tar.gz"
        let tar = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-czf", tarball, "-C", stage, "strato-agent", "strato-control-plane"]
        )
        #expect(tar.terminationStatus == 0)
        let tarballDigest = try AgentUpdater.sha256Hex(ofFileAt: tarball)

        let updater = AgentUpdater(
            logger: logger,
            installMode: .supervisedBinary,
            binaryPath: binaryPath,
            download: fixtureDownloader(from: tarball),
            probe: noopProbe
        )

        let outcome = try await updater.applyUpdate(
            artifactURL: "https://example.com/strato-test.tar.gz",
            sha256: tarballDigest,
            artifactKind: .tarball,
            tarballMember: "strato-agent"
        )

        let swappedBinary = try String(contentsOfFile: outcome.binaryPath, encoding: .utf8)
        #expect(swappedBinary == "new build")
        let preservedBinary = try String(contentsOfFile: outcome.previousBinaryPath, encoding: .utf8)
        #expect(preservedBinary == "old build")
    }

    @Test("Tarball missing the agent member fails cleanly")
    func tarballMissingMember() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let binaryPath = dir + "/strato-agent"
        try write("old build", to: binaryPath, executable: true)

        let stage = dir + "/tar-stage"
        try FileManager.default.createDirectory(atPath: stage, withIntermediateDirectories: true)
        try write("not the agent", to: stage + "/strato-control-plane", executable: true)
        let tarball = dir + "/strato-test.tar.gz"
        _ = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-czf", tarball, "-C", stage, "strato-control-plane"]
        )
        let tarballDigest = try AgentUpdater.sha256Hex(ofFileAt: tarball)

        let updater = AgentUpdater(
            logger: logger,
            installMode: .supervisedBinary,
            binaryPath: binaryPath,
            download: fixtureDownloader(from: tarball),
            probe: noopProbe
        )

        do {
            _ = try await updater.applyUpdate(
                artifactURL: "https://example.com/strato-test.tar.gz",
                sha256: tarballDigest,
                artifactKind: .tarball,
                tarballMember: "strato-agent"
            )
            Issue.record("expected extractionFailed")
        } catch let error as AgentUpdateError {
            guard case .extractionFailed = error else {
                Issue.record("expected extractionFailed, got \(error)")
                return
            }
        }
        let currentBinary = try String(contentsOfFile: binaryPath, encoding: .utf8)
        #expect(currentBinary == "old build")
    }

    @Test("The default probe rejects a binary that exits non-zero")
    func defaultProbeRejectsBrokenBinary() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let binaryPath = dir + "/strato-agent"
        try write("old build", to: binaryPath, executable: true)
        // A "binary" that runs but fails: exit 1 regardless of arguments.
        let fixture = dir + "/artifact-fixture"
        try write("#!/bin/sh\nexit 1\n", to: fixture, executable: true)

        let updater = AgentUpdater(
            logger: logger,
            installMode: .supervisedBinary,
            binaryPath: binaryPath,
            download: fixtureDownloader(from: fixture)
        )

        do {
            _ = try await updater.applyUpdate(
                artifactURL: "https://example.com/strato-agent",
                sha256: try AgentUpdater.sha256Hex(ofFileAt: fixture),
                artifactKind: .binary,
                tarballMember: nil
            )
            Issue.record("expected probeFailed")
        } catch let error as AgentUpdateError {
            guard case .probeFailed = error else {
                Issue.record("expected probeFailed, got \(error)")
                return
            }
        }
        let currentBinary = try String(contentsOfFile: binaryPath, encoding: .utf8)
        #expect(currentBinary == "old build")
    }

    @Test("file:// artifacts are copied by the default downloader (air-gapped path)")
    func fileURLArtifactSwaps() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let binaryPath = dir + "/strato-agent"
        try write("old build", to: binaryPath, executable: true)
        let fixture = dir + "/local-artifact"
        try write("new build", to: fixture)

        // Deliberately uses the DEFAULT downloader: file:// must be handled
        // by copy, since URLSession rejects file URLs on Linux.
        let updater = AgentUpdater(
            logger: logger,
            installMode: .supervisedBinary,
            binaryPath: binaryPath,
            probe: noopProbe
        )

        let outcome = try await updater.applyUpdate(
            artifactURL: "file://" + fixture,
            sha256: sha256Hex(of: "new build"),
            artifactKind: .binary,
            tarballMember: nil
        )
        let swappedBinary = try String(contentsOfFile: outcome.binaryPath, encoding: .utf8)
        #expect(swappedBinary == "new build")

        // A missing local artifact fails as a download error, not a crash.
        do {
            _ = try await updater.applyUpdate(
                artifactURL: "file://" + dir + "/does-not-exist",
                sha256: sha256Hex(of: "new build"),
                artifactKind: .binary,
                tarballMember: nil
            )
            Issue.record("expected downloadFailed")
        } catch let error as AgentUpdateError {
            guard case .downloadFailed = error else {
                Issue.record("expected downloadFailed, got \(error)")
                return
            }
        }
    }

    @Test("Invalid artifact URL is refused before any filesystem work")
    func invalidURLRefused() async throws {
        let updater = AgentUpdater(
            logger: logger,
            installMode: .supervisedBinary,
            binaryPath: "/irrelevant/strato-agent"
        )
        await #expect(throws: AgentUpdateError.invalidArtifactURL("not a url")) {
            _ = try await updater.applyUpdate(
                artifactURL: "not a url",
                sha256: String(repeating: "00", count: 32),
                artifactKind: .binary,
                tarballMember: nil
            )
        }
    }
}
