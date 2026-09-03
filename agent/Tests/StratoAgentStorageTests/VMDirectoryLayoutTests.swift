import Foundation
import Logging
import Testing

@testable import StratoAgentCore

@Suite("VM Directory Removal")
struct VMDirectoryLayoutTests {

    private static let logger = Logger(label: "vm-directory-layout-tests")

    /// A storage root with one VM directory populated the way a delete finds
    /// it: the boot disk and the cloud-init ISO that #969 leaked, alongside the
    /// sockets and state files the old file-by-file cleanup did know about.
    private func makeStorageRoot(vmId: String) throws -> String {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("strato-vmdir-\(UUID().uuidString)")
        let vmDir = root + "/" + vmId
        try FileManager.default.createDirectory(
            atPath: vmDir + "/tpm", withIntermediateDirectories: true)
        for file in ["disk.qcow2", "cloud-init.iso", "nvram.fd", "console.sock", "tpm/tpm2-00.permall"] {
            #expect(FileManager.default.createFile(atPath: vmDir + "/" + file, contents: Data("x".utf8)))
        }
        return root
    }

    @Test("delete removes the boot disk, the cloud-init ISO and the directory itself")
    func removesEverythingTheVMOwns() throws {
        let vmId = UUID().uuidString
        let root = try makeStorageRoot(vmId: vmId)
        defer { try? FileManager.default.removeItem(atPath: root) }

        VMDirectoryLayout.removeDirectory(vmStoragePath: root, vmId: vmId, logger: Self.logger)

        #expect(!FileManager.default.fileExists(atPath: root + "/" + vmId))
        // The storage root survives — it holds the manifest and every other VM.
        #expect(FileManager.default.fileExists(atPath: root))
    }

    @Test("a VM whose directory is already gone is a no-op, not a failure")
    func idempotent() throws {
        let vmId = UUID().uuidString
        let root = try makeStorageRoot(vmId: vmId)
        defer { try? FileManager.default.removeItem(atPath: root) }

        VMDirectoryLayout.removeDirectory(vmStoragePath: root, vmId: vmId, logger: Self.logger)
        VMDirectoryLayout.removeDirectory(vmStoragePath: root, vmId: vmId, logger: Self.logger)

        #expect(!FileManager.default.fileExists(atPath: root + "/" + vmId))
    }

    /// `fileExists` follows symlinks, so an existence pre-check reports a
    /// dangling symlink absent and leaves it on disk forever. The removal
    /// classifies the error instead, which unlinks the link itself.
    @Test("a dangling symlink at the VM's path is unlinked, not mistaken for absence")
    func removesDanglingSymlink() throws {
        let vmId = UUID().uuidString
        let root = try makeStorageRoot(vmId: UUID().uuidString)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let link = root + "/" + vmId
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: root + "/gone")

        VMDirectoryLayout.removeDirectory(vmStoragePath: root, vmId: vmId, logger: Self.logger)

        // `attributesOfItem` does not traverse the link, so it sees the link
        // itself — unlike `fileExists`, which is why this is asserted with it.
        #expect((try? FileManager.default.attributesOfItem(atPath: link)) == nil)
    }

    /// The removal is recursive, so an id that escapes its own directory would
    /// take other VMs' disks — or the whole storage root — with it.
    @Test(
        "an id that is not a single path component is refused",
        arguments: ["", ".", "..", "../..", "some/nested/id", "/"])
    func refusesTraversingIds(vmId: String) throws {
        let neighbour = UUID().uuidString
        let root = try makeStorageRoot(vmId: neighbour)
        defer { try? FileManager.default.removeItem(atPath: root) }

        VMDirectoryLayout.removeDirectory(vmStoragePath: root, vmId: vmId, logger: Self.logger)

        #expect(FileManager.default.fileExists(atPath: root + "/" + neighbour + "/disk.qcow2"))
        #expect(FileManager.default.fileExists(atPath: root))
    }

}
