#if os(Linux)
import Foundation
import Logging
import StratoAgentCore
import StratoShared
import SwiftFirecracker
import Testing

@testable import StratoAgentRuntime

private actor CountingFirecrackerDiskRealizer: FirecrackerDiskRealizing {
    private var realizeCount = 0
    private var releaseCount = 0
    private var references = 0

    func realize(
        _ attachment: DiskAttachment, readOnly: Bool
    ) async throws -> FirecrackerRealizedDisk {
        realizeCount += 1
        references += 1
        return FirecrackerRealizedDisk(
            canonical: attachment, realized: attachment, readOnly: readOnly)
    }

    func release(_: FirecrackerRealizedDisk) async throws {
        releaseCount += 1
        references -= 1
    }

    func counts() -> (realized: Int, released: Int, references: Int) {
        (realizeCount, releaseCount, references)
    }
}

@Suite("Firecracker service disk lifecycle")
struct FirecrackerServiceLifecycleTests {
    @Test("A pre-configuration process-create failure releases each krbd reference")
    func processCreateFailureDoesNotAccumulateDiskReferences() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("firecracker-create-failure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let diskPath = directory.appendingPathComponent("root.raw").path
        #expect(FileManager.default.createFile(atPath: diskPath, contents: Data()))

        let realizer = CountingFirecrackerDiskRealizer()
        let missingBinary = directory.appendingPathComponent("missing-firecracker").path
        let client = FirecrackerClient(
            firecrackerBinaryPath: missingBinary,
            socketDirectory: directory.appendingPathComponent("sockets").path,
            logger: Logger(label: "firecracker-create-failure-client"))
        let service = FirecrackerService(
            logger: Logger(label: "firecracker-create-failure-service"),
            diskRealizer: realizer,
            vmStoragePath: directory.path,
            firecrackerBinaryPath: missingBinary,
            socketDirectory: directory.appendingPathComponent("sockets").path,
            firecrackerClient: client)
        let volumeId = UUID()
        let spec = VMSpec(
            cpus: 1, memoryBytes: 256 * 1024 * 1024,
            boot: .directKernel(kernel: "/kernel", initramfs: nil, cmdline: nil),
            volumes: [
                VolumeSpec(
                    volumeId: volumeId, deviceName: .disk(0),
                    attachment: .file(path: diskPath, format: .raw), bootOrder: 0)
            ])

        for attempt in 1...2 {
            await #expect(throws: Error.self) {
                try await service.createVM(vmId: UUID().uuidString, spec: spec)
            }
            let counts = await realizer.counts()
            #expect(counts.realized == attempt)
            #expect(counts.released == attempt)
            #expect(counts.references == 0)
        }
    }
}
#endif
