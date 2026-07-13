import Foundation
import Testing
import StratoShared
@testable import StratoAgentCore

@Suite("Sandbox Guest Image Tests")
struct SandboxGuestImageTests {

    /// Lay out a guest image directory with a `guest.json` and the named
    /// artifact files, and return its path.
    private func makeGuestDir(
        manifest: String,
        files: [String] = [
            "vmlinux-x86_64", "initramfs-x86_64.cpio.gz",
            "vmlinux-aarch64", "initramfs-aarch64.cpio.gz",
        ]
    ) throws -> String {
        let dir = NSTemporaryDirectory() + "sandbox-guest-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try manifest.write(toFile: dir + "/guest.json", atomically: true, encoding: .utf8)
        for file in files {
            FileManager.default.createFile(atPath: dir + "/" + file, contents: Data("x".utf8))
        }
        return dir
    }

    private let multiArchManifest = """
        {
          "schemaVersion": 1,
          "version": "6.1.177+init0.1.0",
          "gitSHA": "abc1234",
          "artifacts": [
            {
              "arch": "x86_64",
              "kernel": "vmlinux-x86_64",
              "initramfs": "initramfs-x86_64.cpio.gz",
              "kernelSha256": "aa", "initramfsSha256": "bb",
              "kernelSize": 1, "initramfsSize": 2,
              "bootArgs": "console=ttyS0 reboot=k panic=1 pci=off"
            },
            {
              "arch": "aarch64",
              "kernel": "vmlinux-aarch64",
              "initramfs": "initramfs-aarch64.cpio.gz",
              "kernelSha256": "cc", "initramfsSha256": "dd",
              "kernelSize": 3, "initramfsSize": 4,
              "bootArgs": "console=ttyAMA0 reboot=k panic=1 pci=off"
            }
          ]
        }
        """

    @Test("resolves the x86_64 artifacts and boot args")
    func resolvesX86() throws {
        let dir = try makeGuestDir(manifest: multiArchManifest)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let image = try SandboxGuestImage.resolve(atDirectory: dir, architecture: .x86_64)
        #expect(image.kernelPath == dir + "/vmlinux-x86_64")
        #expect(image.initramfsPath == dir + "/initramfs-x86_64.cpio.gz")
        #expect(image.bootArgs == "console=ttyS0 reboot=k panic=1 pci=off")
        #expect(image.version == "6.1.177+init0.1.0")
        #expect(image.arch == "x86_64")
    }

    @Test("maps arm64 to the aarch64 artifact token")
    func resolvesArm64() throws {
        let dir = try makeGuestDir(manifest: multiArchManifest)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let image = try SandboxGuestImage.resolve(atDirectory: dir, architecture: .arm64)
        #expect(image.kernelPath == dir + "/vmlinux-aarch64")
        #expect(image.bootArgs.contains("ttyAMA0"))
        #expect(image.arch == "aarch64")
    }

    @Test("missing manifest is reported with its path")
    func missingManifest() {
        let dir = NSTemporaryDirectory() + "sandbox-guest-tests-" + UUID().uuidString
        #expect(throws: SandboxGuestImageError.self) {
            try SandboxGuestImage.resolve(atDirectory: dir, architecture: .x86_64)
        }
    }

    @Test("an unsupported schema version is rejected")
    func unsupportedSchema() throws {
        let manifest = multiArchManifest.replacingOccurrences(of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 2")
        let dir = try makeGuestDir(manifest: manifest)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        #expect {
            try SandboxGuestImage.resolve(atDirectory: dir, architecture: .x86_64)
        } throws: { error in
            error as? SandboxGuestImageError == .unsupportedSchema(2)
        }
    }

    @Test("a host architecture with no artifacts is rejected, naming what is present")
    func architectureUnavailable() throws {
        // Manifest ships only x86_64.
        let x86Only = """
            {
              "schemaVersion": 1, "version": "v", "gitSHA": "s",
              "artifacts": [
                {"arch": "x86_64", "kernel": "vmlinux-x86_64",
                 "initramfs": "initramfs-x86_64.cpio.gz", "bootArgs": "console=ttyS0"}
              ]
            }
            """
        let dir = try makeGuestDir(manifest: x86Only, files: ["vmlinux-x86_64", "initramfs-x86_64.cpio.gz"])
        defer { try? FileManager.default.removeItem(atPath: dir) }

        #expect {
            try SandboxGuestImage.resolve(atDirectory: dir, architecture: .arm64)
        } throws: { error in
            guard case .architectureUnavailable(let detail)? = error as? SandboxGuestImageError else { return false }
            return detail.contains("aarch64") && detail.contains("x86_64")
        }
    }

    @Test("a manifest referencing an absent artifact file is rejected")
    func artifactMissing() throws {
        // Manifest names artifacts but we write none.
        let dir = try makeGuestDir(manifest: multiArchManifest, files: [])
        defer { try? FileManager.default.removeItem(atPath: dir) }

        #expect {
            try SandboxGuestImage.resolve(atDirectory: dir, architecture: .x86_64)
        } throws: { error in
            guard case .artifactMissing(let path)? = error as? SandboxGuestImageError else { return false }
            return path.hasSuffix("vmlinux-x86_64")
        }
    }
}
