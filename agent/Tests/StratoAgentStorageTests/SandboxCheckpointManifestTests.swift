import Foundation
import StratoShared
import Testing

@testable import StratoAgentCore

@Suite("Sandbox checkpoint local durability and integrity")
struct SandboxCheckpointManifestTests {
    private let sandboxId = UUID().uuidString
    private let snapshotId = UUID().uuidString

    private func withArchive(_ body: (String) throws -> Void) throws {
        let directory = NSTemporaryDirectory() + "checkpoint-integrity-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        for kind in SandboxSnapshotArtifactKind.allCases {
            try Data("\(kind.rawValue)-checkpoint".utf8).write(
                to: URL(fileURLWithPath: directory + "/" + kind.filename))
        }
        try body(directory)
    }

    @discardableResult
    private func publish(_ directory: String) throws -> SandboxCheckpointManifest {
        try SandboxCheckpointManifest.publish(
            directory: directory, sandboxId: sandboxId, snapshotId: snapshotId,
            identityNonce: "nonce", firecrackerVersion: "1.13.1", guestControlProtocolVersion: 4)
    }

    private func verify(_ directory: String) throws -> SandboxCheckpointManifest? {
        try SandboxCheckpointManifest.verifyIfPresent(
            directory: directory, sandboxId: sandboxId, snapshotId: snapshotId, identityNonce: "nonce")
    }

    @Test func reopenAfterPublish() throws {
        try withArchive { directory in
            let expected = try publish(directory)
            let actual = try verify(directory)
            #expect(actual == expected)
            #expect(expected.artifacts.count == 4)
            #expect(expected.artifacts.allSatisfy { $0.sha256.count == 64 && $0.sizeBytes > 0 })
            let files = try FileManager.default.contentsOfDirectory(atPath: directory)
            #expect(files.count == 5)
        }
    }

    @Test func legacyHasNoEvidence() throws {
        try withArchive { directory in
            let actual = try verify(directory)
            #expect(actual == nil)
        }
    }

    @Test(arguments: SandboxSnapshotArtifactKind.allCases)
    func corruptionFailsClosed(_ kind: SandboxSnapshotArtifactKind) throws {
        try withArchive { directory in
            try publish(directory)
            let path = URL(fileURLWithPath: directory + "/" + kind.filename)
            var bytes = try Data(contentsOf: path)
            bytes[0] ^= 0x01
            try bytes.write(to: path)
            #expect(throws: SandboxCheckpointManifest.CheckpointError.integrityMismatch) {
                try verify(directory)
            }
        }
    }

    @Test(arguments: SandboxSnapshotArtifactKind.allCases)
    func missingArtifactPreventsPublish(_ kind: SandboxSnapshotArtifactKind) throws {
        try withArchive { directory in
            try FileManager.default.removeItem(atPath: directory + "/" + kind.filename)
            #expect(throws: (any Error).self) { try publish(directory) }
            #expect(
                !FileManager.default.fileExists(
                    atPath: directory + "/" + SandboxCheckpointManifest.filename))
        }
    }

    @Test func identityIsBoundToArchive() throws {
        try withArchive { directory in
            try publish(directory)
            for (sandbox, snapshot, nonce) in [
                (UUID().uuidString, snapshotId, "nonce"),
                (sandboxId, UUID().uuidString, "nonce"),
                (sandboxId, snapshotId, "other"),
            ] {
                #expect(throws: SandboxCheckpointManifest.CheckpointError.identityMismatch) {
                    try SandboxCheckpointManifest.verifyIfPresent(
                        directory: directory, sandboxId: sandbox, snapshotId: snapshot, identityNonce: nonce)
                }
            }
        }
    }

    @Test func malformedSidecarDoesNotBecomeLegacy() throws {
        try withArchive { directory in
            try Data("{}".utf8).write(
                to: URL(fileURLWithPath: directory + "/" + SandboxCheckpointManifest.filename))
            #expect(throws: (any Error).self) { try verify(directory) }
        }
    }

    @Test func duplicateArtifactSetIsRejected() throws {
        try withArchive { directory in
            let expected = try publish(directory)
            let invalid = SandboxCheckpointManifest(
                version: 1, sandboxId: sandboxId, snapshotId: snapshotId, identityNonce: "nonce",
                firecrackerVersion: "1.13.1", guestControlProtocolVersion: 4,
                artifacts: Array(repeating: expected.artifacts[0], count: 4))
            try JSONEncoder().encode(invalid).write(
                to: URL(fileURLWithPath: directory + "/" + SandboxCheckpointManifest.filename))
            #expect(throws: SandboxCheckpointManifest.CheckpointError.invalidManifest) { try verify(directory) }
        }
    }

    @Test func oversizedSidecarIsRejected() throws {
        try withArchive { directory in
            try Data(repeating: 0, count: 65_537).write(
                to: URL(fileURLWithPath: directory + "/" + SandboxCheckpointManifest.filename))
            #expect(throws: SandboxCheckpointManifest.CheckpointError.invalidManifest) { try verify(directory) }
        }
    }

    @Test(arguments: SandboxSnapshotArtifactKind.allCases)
    func symlinkArtifactIsRejected(_ kind: SandboxSnapshotArtifactKind) throws {
        try withArchive { directory in
            let path = directory + "/" + kind.filename
            let target = directory + "/target"
            try FileManager.default.moveItem(atPath: path, toPath: target)
            try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
            #expect(throws: (any Error).self) { try publish(directory) }
        }
    }

    @Test func symlinkSidecarIsRejected() throws {
        try withArchive { directory in
            try publish(directory)
            let path = directory + "/" + SandboxCheckpointManifest.filename
            let target = directory + "/target"
            try FileManager.default.moveItem(atPath: path, toPath: target)
            try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
            #expect(throws: (any Error).self) { try verify(directory) }
        }
    }

    @Test func directoryInsteadOfArtifactIsRejected() throws {
        try withArchive { directory in
            let path = directory + "/memory.snap"
            try FileManager.default.removeItem(atPath: path)
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
            #expect(throws: SandboxCheckpointManifest.CheckpointError.invalidArtifact) { try publish(directory) }
        }
    }

    @Test func hardLinkedArtifactIsRejected() throws {
        try withArchive { directory in
            try FileManager.default.linkItem(atPath: directory + "/memory.snap", toPath: directory + "/alias")
            #expect(throws: SandboxCheckpointManifest.CheckpointError.invalidArtifact) { try publish(directory) }
        }
    }

    @Test func emptyArtifactIsRejected() throws {
        try withArchive { directory in
            try Data().write(to: URL(fileURLWithPath: directory + "/memory.snap"))
            #expect(throws: SandboxCheckpointManifest.CheckpointError.invalidArtifact) { try publish(directory) }
        }
    }

    @Test func failedPublishRemovesTemporaryFile() throws {
        try withArchive { directory in
            try FileManager.default.createDirectory(
                atPath: directory + "/" + SandboxCheckpointManifest.filename, withIntermediateDirectories: false)
            #expect(throws: (any Error).self) { try publish(directory) }
            let files = try FileManager.default.contentsOfDirectory(atPath: directory)
            #expect(!files.contains { $0.hasPrefix(".checkpoint-integrity-") })
            #expect(files.count == 5)
        }
    }
}
