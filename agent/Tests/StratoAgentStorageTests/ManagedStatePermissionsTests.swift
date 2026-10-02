import Foundation
import Logging
import Testing
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
@testable import StratoAgentCore

@Suite(.serialized)
struct ManagedStatePermissionsTests {
    private func fixture(_ body: (String) async throws -> Void) async throws {
        let root = "/tmp/strato-private-state-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try await body(root)
    }

    private func mode(_ path: String) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        return (attrs[.posixPermissions] as! NSNumber).intValue
    }

    @Test func restrictiveCreationAndReplacementUnderPermissiveUmask() async throws {
        let previous = umask(0)
        defer { _ = umask(previous) }
        try await fixture { root async throws in
            let path = root + "/nested/state.json"
            try DurableFileWriter().write(Data("secret".utf8), to: path)
            #expect(try mode(root + "/nested") == 0o700)
            #expect(try mode(path) == 0o600)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
            try DurableFileWriter().write(Data("replacement".utf8), to: path)
            #expect(try mode(path) == 0o600)
            let manifest = VMManifestStore(path: root + "/vm-manifest.json", logger: Logger(label: "test"))
            #expect(manifest.save([:]))
            #expect(try mode(manifest.path) == 0o600)
            try Data("invalid fixture manifest".utf8).write(to: URL(fileURLWithPath: manifest.path))
            if case .unreadable = manifest.load() {} else { Issue.record("Expected corrupt manifest") }
            let copies = try FileManager.default.contentsOfDirectory(atPath: root)
                .filter { $0.hasPrefix("vm-manifest.json.corrupt-") }
            #expect(copies.count == 1)
            for copy in copies { #expect(try mode(root + "/" + copy) == 0o600) }
        }
    }

    @Test func migrationPreservesOperatorFilesBackingPathsAndSandboxDirectories() async throws {
        try await fixture { root async throws in
            let vm = root + "/" + UUID().uuidString
            let sandbox = root + "/" + UUID().uuidString
            for directory in [vm, sandbox] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory)
            }
            let records = [
                "vm-manifest.json", "snapshot-records.json", "instance-metadata.json",
                "vm-manifest.json.corrupt-fixture",
            ]
            let privateFiles = records.map { root + "/" + $0 } + [vm + "/cloud-init.iso"]
            let untouched = [root + "/operator.txt", vm + "/disk.qcow2", vm + "/nvram.fd"]
            for path in privateFiles + untouched {
                try Data("fixture".utf8).write(to: URL(fileURLWithPath: path))
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
            }
            try ManagedStatePermissions.migrate(at: root)
            try ManagedStatePermissions.migrate(at: root)
            for path in privateFiles { #expect(try mode(path) == 0o600) }
            for path in untouched { #expect(try mode(path) == 0o644) }
            #expect(try mode(vm) == 0o700)
            #expect(try mode(sandbox) == 0o755)
            #expect(access(vm + "/cloud-init.iso", R_OK) == 0)
        }
    }

    @Test func migrationAndCreationRefuseSymlinksAndHardlinks() async throws {
        try await fixture { root async throws in
            let outside = root + "/operator"
            try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: false)
            let linkPath = root + "/linked"
            try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: outside)
            #expect(throws: (any Error).self) {
                try ManagedStatePermissions.prepareVMDirectory(at: linkPath + "/child")
            }
            #expect(!FileManager.default.fileExists(atPath: outside + "/child"))
            let target = outside + "/secret"
            try Data("operator".utf8).write(to: URL(fileURLWithPath: target))
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target)
            let record = root + "/vm-manifest.json"
            try FileManager.default.createSymbolicLink(atPath: record, withDestinationPath: target)
            #expect(throws: (any Error).self) { try ManagedStatePermissions.migrate(at: root) }
            #expect(try mode(target) == 0o644)
            try FileManager.default.removeItem(atPath: record)
            #expect(link(target, record) == 0)
            #expect(throws: (any Error).self) { try ManagedStatePermissions.migrate(at: root) }
            #expect(try mode(target) == 0o644)
        }
    }

    @Test func seedGenerationStagesPrivatelyAndPublishesRestrictiveISO() async throws {
        let previous = umask(0)
        defer { _ = umask(previous) }
        try await fixture { root async throws in
            var provisioner = CloudInitProvisioner(logger: Logger(label: "test"))
            provisioner.runISO = { _, arguments in
                let staging = arguments.last!
                let attrs = try FileManager.default.attributesOfItem(atPath: staging)
                #expect((attrs[.posixPermissions] as! NSNumber).intValue == 0o700)
                for name in ["meta-data", "user-data"] {
                    let attrs = try FileManager.default.attributesOfItem(atPath: staging + "/" + name)
                    #expect((attrs[.posixPermissions] as! NSNumber).intValue == 0o600)
                }
                try Data("ISO fixture".utf8).write(
                    to: URL(fileURLWithPath: (staging as NSString).deletingLastPathComponent + "/cloud-init.iso"))
                return ProcessResult(terminationStatus: 0, standardOutput: Data(), standardError: Data())
            }
            #expect(
                await provisioner.makeNoCloudISO(
                    at: root + "/cloud-init.iso", vmId: "fixture", userData: "#cloud-config\nfixture: secret"))
            #expect(try mode(root) == 0o700)
            #expect(try mode(root + "/cloud-init.iso") == 0o600)
            #expect(!FileManager.default.fileExists(atPath: root + "/.cloud-init-staging"))
        }
    }

    @Test func staleStagingAndOutputSymlinksArePreservedAndRefused() async throws {
        try await fixture { root async throws in
            let staging = root + "/.cloud-init-staging"
            try FileManager.default.createDirectory(atPath: staging, withIntermediateDirectories: false)
            try Data("stale".utf8).write(to: URL(fileURLWithPath: staging + "/user-data"))
            let provisioner = CloudInitProvisioner(logger: Logger(label: "test"))
            #expect(await provisioner.makeNoCloudISO(at: root + "/cloud-init.iso", vmId: "fixture") == false)
            #expect(try String(contentsOfFile: staging + "/user-data", encoding: .utf8) == "stale")
            try FileManager.default.removeItem(atPath: staging)
            try FileManager.default.createSymbolicLink(atPath: staging, withDestinationPath: root)
            #expect(await provisioner.makeNoCloudISO(at: root + "/cloud-init.iso", vmId: "fixture") == false)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: staging) == root)
            try FileManager.default.removeItem(atPath: staging)
            try FileManager.default.createSymbolicLink(
                atPath: root + "/cloud-init.iso", withDestinationPath: root + "/operator")
            #expect(await provisioner.makeNoCloudISO(at: root + "/cloud-init.iso", vmId: "fixture") == false)
            #expect(!FileManager.default.fileExists(atPath: staging))
        }
    }

    @Test func failedGeneratorPreservesPreviousISOAndCleansOwnedStaging() async throws {
        try await fixture { root async throws in
            let iso = root + "/cloud-init.iso"
            try DurableFileWriter().write(Data("previous seed".utf8), to: iso)
            var provisioner = CloudInitProvisioner(logger: Logger(label: "test"))
            provisioner.runISO = { _, arguments in
                let documents = arguments.last!
                let metadata = try String(contentsOfFile: documents + "/meta-data", encoding: .utf8)
                #expect(metadata.contains("seedfrom:"))
                return ProcessResult(terminationStatus: 1, standardOutput: Data(), standardError: Data())
            }
            #expect(
                await provisioner.makeNoCloudISO(
                    at: iso, vmId: "fixture", metadataSource: .imds, noCloudSeedToken: UUID()) == false)
            #expect(try String(contentsOfFile: iso, encoding: .utf8) == "previous seed")
            #expect(!FileManager.default.fileExists(atPath: root + "/.cloud-init-staging"))
            provisioner.runISO = { _, _ in throw CocoaError(.fileWriteUnknown) }
            #expect(await provisioner.makeNoCloudISO(at: iso, vmId: "fixture") == false)
            #expect(try String(contentsOfFile: iso, encoding: .utf8) == "previous seed")
            #expect(!FileManager.default.fileExists(atPath: root + "/.cloud-init-staging"))
        }
    }

    @Test func migrationSecuresCrashLeftoversAndSkipsUnmanagedUUIDFiles() async throws {
        try await fixture { root async throws in
            let legacyRoot = root + "/legacy-tmp"
            try FileManager.default.createDirectory(atPath: legacyRoot, withIntermediateDirectories: false)
            let vmId = UUID().uuidString
            let legacy = legacyRoot + "/cloud-init-" + vmId
            try FileManager.default.createDirectory(atPath: legacy, withIntermediateDirectories: false)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: legacy)
            let crashFiles = [
                root + "/vm-manifest.json.tmp", root + "/vm-manifest.json.tmp." + UUID().uuidString,
                legacy + "/user-data", legacy + "/meta-data", legacy + "/network-config",
            ]
            let operatorUUID = root + "/" + UUID().uuidString
            let operatorLink = root + "/" + UUID().uuidString
            let untouched = [operatorUUID, root + "/instance-metadata.json.tmp", legacy + "/operator.txt"]
            for path in crashFiles + untouched {
                try Data("fixture bytes".utf8).write(to: URL(fileURLWithPath: path))
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
            }
            try FileManager.default.createSymbolicLink(atPath: operatorLink, withDestinationPath: operatorUUID)
            try ManagedStatePermissions.migrate(at: root, qemuVMIds: [vmId], legacyStagingRoot: legacyRoot)
            #expect(try mode(legacy) == 0o700)
            for path in crashFiles {
                #expect(try mode(path) == 0o600)
                #expect(try String(contentsOfFile: path, encoding: .utf8) == "fixture bytes")
            }
            for path in untouched { #expect(try mode(path) == 0o644) }
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: operatorLink) == operatorUUID)
            #expect(throws: (any Error).self) {
                try ManagedStatePermissions.migrate(at: root, qemuVMIds: [(operatorLink as NSString).lastPathComponent])
            }
        }
    }
}
