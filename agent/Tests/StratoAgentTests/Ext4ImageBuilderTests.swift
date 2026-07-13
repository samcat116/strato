import Foundation
import Logging
import Testing

@testable import StratoAgentCore

@Suite("Ext4 Image Builder")
struct Ext4ImageBuilderTests {

    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "ext4-builder-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeTree(in dir: String, fileBytes: Int = 1000) throws -> String {
        let tree = dir + "/tree"
        try FileManager.default.createDirectory(atPath: tree + "/bin", withIntermediateDirectories: true)
        try Data(repeating: 1, count: fileBytes).write(to: URL(fileURLWithPath: tree + "/bin/app"))
        return tree
    }

    @Test("sizing covers content plus headroom, block-aligned, floored")
    func sizing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let tree = try makeTree(in: dir, fileBytes: 10_000_000)

        let builder = Ext4ImageBuilder(logger: Logger(label: "test"))
        let size = builder.imageSizeBytes(forTree: tree)
        #expect(size >= 10_000_000 + builder.minimumHeadroomBytes)
        #expect(size >= builder.minimumImageBytes)
        #expect(size % 4096 == 0)

        // An empty tree still yields a usable minimum-size image.
        let emptyTree = dir + "/empty"
        try FileManager.default.createDirectory(atPath: emptyTree, withIntermediateDirectories: true)
        let emptySize = builder.imageSizeBytes(forTree: emptyTree)
        #expect(emptySize == builder.minimumImageBytes)
    }

    @Test("invokes mkfs.ext4 -d against a pre-sized image file")
    func invocation() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let tree = try makeTree(in: dir)
        let imagePath = dir + "/rootfs.ext4"

        let recorded = RecordedInvocation()
        let builder = Ext4ImageBuilder(
            mkfsPath: "/bin/ls",  // exists and is executable; never actually run
            logger: Logger(label: "test"),
            runSubprocess: { executable, arguments in
                await recorded.record(executable: executable.path, arguments: arguments)
                return ProcessResult(terminationStatus: 0, standardOutput: Data(), standardError: Data())
            }
        )
        try await builder.buildImage(fromTree: tree, at: imagePath)

        let invocation = await recorded.invocations.first
        #expect(invocation?.executable == "/bin/ls")
        #expect(invocation?.arguments == ["-F", "-q", "-d", tree, imagePath])

        // The image file was pre-sized for mkfs.
        let attributes = try FileManager.default.attributesOfItem(atPath: imagePath)
        let size = attributes[.size] as? Int64
        #expect(size == builder.imageSizeBytes(forTree: tree))
    }

    @Test("a failing mkfs surfaces stderr and removes the partial image")
    func mkfsFailure() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let tree = try makeTree(in: dir)
        let imagePath = dir + "/rootfs.ext4"

        let builder = Ext4ImageBuilder(
            mkfsPath: "/bin/ls",
            logger: Logger(label: "test"),
            runSubprocess: { _, _ in
                ProcessResult(
                    terminationStatus: 1, standardOutput: Data(),
                    standardError: Data("simulated mkfs failure".utf8))
            }
        )
        do {
            try await builder.buildImage(fromTree: tree, at: imagePath)
            Issue.record("expected hostMisconfiguration")
        } catch let error as OCIError {
            guard case .hostMisconfiguration(let detail) = error else {
                Issue.record("expected hostMisconfiguration, got \(error)")
                return
            }
            #expect(detail.contains("simulated mkfs failure"))
        }
        #expect(!FileManager.default.fileExists(atPath: imagePath))
    }

    @Test("a missing mkfs.ext4 is a permanent host misconfiguration")
    func missingMkfs() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let tree = try makeTree(in: dir)

        let builder = Ext4ImageBuilder(mkfsPath: "/nonexistent/mkfs.ext4", logger: Logger(label: "test"))
        do {
            try await builder.buildImage(fromTree: tree, at: dir + "/rootfs.ext4")
            Issue.record("expected hostMisconfiguration")
        } catch let error as OCIError {
            #expect(error.failureClassification == .permanent)
        }
    }

    @Test("builds a real ext4 image when the host has mkfs.ext4", .enabled(if: mkfsPresent))
    func realBuild() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let tree = try makeTree(in: dir)
        let imagePath = dir + "/rootfs.ext4"

        let builder = Ext4ImageBuilder(logger: Logger(label: "test"))
        try await builder.buildImage(fromTree: tree, at: imagePath)

        // ext4 superblock magic 0xEF53 at offset 0x438.
        let handle = FileHandle(forReadingAtPath: imagePath)
        defer { try? handle?.close() }
        handle?.seek(toFileOffset: 0x438)
        let magic = handle?.readData(ofLength: 2)
        #expect(magic == Data([0x53, 0xEF]))
    }

    private static var mkfsPresent: Bool {
        ["/usr/sbin/mkfs.ext4", "/sbin/mkfs.ext4", "/usr/bin/mkfs.ext4"]
            .contains { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// Collects subprocess invocations from `@Sendable` stub runners.
private actor RecordedInvocation {
    struct Invocation {
        let executable: String
        let arguments: [String]
    }

    private(set) var invocations: [Invocation] = []

    func record(executable: String, arguments: [String]) {
        invocations.append(Invocation(executable: executable, arguments: arguments))
    }
}
