#if os(Linux)
import Foundation
import Logging
import StratoShared
import Testing
@testable import StratoAgentCore
@testable import StratoAgentRuntime

@Suite("Libvirt guest seed admission", .serialized)
struct LibvirtGuestSeedRefusalTests {
    private final class Definitions: @unchecked Sendable {
        private let lock = NSLock()
        private var xml: [String] = []
        func record(_ value: String) { lock.withLock { xml.append(value) } }
        var values: [String] { lock.withLock { xml } }
    }

    private func fixture(_ body: (String, String, VMSpec, Definitions) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("libvirt-seed-" + UUID().uuidString)
            .path
        defer { try? FileManager.default.removeItem(atPath: root) }
        try ManagedStatePermissions.prepareVMDirectory(at: root)
        let id = UUID().uuidString
        let vmDirectory = VMDirectoryLayout.directory(vmStoragePath: root, vmId: id)
        try ManagedStatePermissions.prepareVMDirectory(at: vmDirectory)
        let disk = root + "/disk.raw", firmware = root + "/firmware.fd"
        try Data("disk".utf8).write(to: URL(fileURLWithPath: disk))
        try Data("firmware".utf8).write(to: URL(fileURLWithPath: firmware))
        let spec = VMSpec(
            cpus: 1, memoryBytes: 256 << 20, boot: .disk(firmware: firmware),
            volumes: [
                .init(volumeId: UUID(), deviceName: .disk(0), attachment: .file(path: disk, format: .raw), bootOrder: 0)
            ],
            sshAuthorizedKeys: ["ssh-ed25519 fixture-key"], userData: "#cloud-config\nfixture: requested")
        try await body(root, id, spec, Definitions())
    }

    @Test func refusedStagingPreventsDomainDefinitionAndPreservesPublishedState() async throws {
        for kind in ["unknown", "linked", "building"] {
            try await fixture { root, id, spec, definitions in
                let vmDirectory = VMDirectoryLayout.directory(vmStoragePath: root, vmId: id)
                let iso = VMDirectoryLayout.cloudInitISO(vmDirectory: vmDirectory)
                let state = root + "/vm-manifest.json"
                try DurableFileWriter().write(Data("published ISO".utf8), to: iso)
                try DurableFileWriter().write(Data("published state".utf8), to: state)
                let stage = vmDirectory + "/.cloud-init-staging"
                if kind == "linked" {
                    try FileManager.default.createSymbolicLink(atPath: stage, withDestinationPath: root)
                } else if kind == "building" {
                    do {
                        let owned = try CloudInitStaging(vmDirectory: vmDirectory, vmID: id)
                        try owned.generatorWillStart()
                    }
                } else {
                    try ManagedStatePermissions.createFreshDirectory(at: stage)
                }
                let service = LibvirtService(
                    logger: Logger(label: "seed-admission"), vmStoragePath: root,
                    uri: "qemu+unix:///system?socket=/nonexistent-seed-admission-libvirt",
                    hardwareAccelerationEnabled: false, memoryControllerAvailable: false,
                    defineDomain: { definitions.record($0) })
                do {
                    try await service.createVM(vmId: id, spec: spec)
                    Issue.record("Domain creation accepted refused seed staging")
                } catch let error as HypervisorServiceError {
                    guard case .diskError = error else { Issue.record("Unexpected pre-seed error: \(error)"); return }
                }
                #expect(definitions.values.isEmpty)
                #expect(try String(contentsOfFile: iso, encoding: .utf8) == "published ISO")
                #expect(try String(contentsOfFile: state, encoding: .utf8) == "published state")
                #expect(FileManager.default.fileExists(atPath: stage))
            }
        }
    }

    @Test func absentGuestSeedIntentAllowsDomainDefinition() async throws {
        try await fixture { root, id, requestedSpec, definitions in
            let spec = VMSpec(
                cpus: requestedSpec.cpus, memoryBytes: requestedSpec.memoryBytes,
                boot: requestedSpec.boot, volumes: requestedSpec.volumes)
            var provisioner = CloudInitProvisioner(logger: Logger(label: "absent-seed"))
            provisioner.runISO = { _, _ in
                Issue.record("A VM with no seed intent invoked ISO generation")
                throw CocoaError(.fileWriteUnknown)
            }
            let service = LibvirtService(
                logger: Logger(label: "absent-seed"), vmStoragePath: root,
                hardwareAccelerationEnabled: false, memoryControllerAvailable: false,
                cloudInitProvisioner: provisioner, defineDomain: { definitions.record($0) })
            try await service.createVM(vmId: id, spec: spec)
            #expect(definitions.values.count == 1)
            #expect(definitions.values.first?.contains("cloud-init.iso") == false)
        }
    }

    @Test func failedRequestedSeedPreventsDomainDefinition() async throws {
        try await fixture { root, id, spec, definitions in
            let vmDirectory = VMDirectoryLayout.directory(vmStoragePath: root, vmId: id)
            let iso = VMDirectoryLayout.cloudInitISO(vmDirectory: vmDirectory)
            try DurableFileWriter().write(Data("previous ISO".utf8), to: iso)
            var provisioner = CloudInitProvisioner(logger: Logger(label: "failed-seed"))
            provisioner.runISO = { _, _ in
                ProcessResult(terminationStatus: 1, standardOutput: Data(), standardError: Data())
            }
            let service = LibvirtService(
                logger: Logger(label: "failed-seed"), vmStoragePath: root,
                hardwareAccelerationEnabled: false, memoryControllerAvailable: false,
                cloudInitProvisioner: provisioner, defineDomain: { definitions.record($0) })
            do {
                try await service.createVM(vmId: id, spec: spec)
                Issue.record("Domain creation accepted failed requested seed")
            } catch let error as HypervisorServiceError {
                guard case .diskError = error else { Issue.record("Unexpected pre-seed error: \(error)"); return }
            }
            #expect(definitions.values.isEmpty)
            #expect(try String(contentsOfFile: iso, encoding: .utf8) == "previous ISO")
        }
    }
}
#endif
