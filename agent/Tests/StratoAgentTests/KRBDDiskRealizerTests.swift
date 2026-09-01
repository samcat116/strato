import Foundation
import StratoShared
import Testing

@testable import StratoAgentCore

private actor KRBDCommandRecorder {
    struct Invocation: Sendable {
        let arguments: [String]
    }
    private(set) var invocations: [Invocation] = []
    private var nextDevice = 0
    private var devices: [[String: String]] = []
    private var failUnmap = false

    func run(_: URL, _ arguments: [String]) -> ProcessResult {
        invocations.append(Invocation(arguments: arguments))
        if arguments.starts(with: ["device", "list"]) {
            return ProcessResult(
                terminationStatus: 0,
                standardOutput: (try? JSONSerialization.data(withJSONObject: devices)) ?? Data("[]".utf8),
                standardError: Data())
        }
        if arguments.contains("map") {
            let mapIndex = arguments.firstIndex(of: "map")!
            let coordinate = arguments[arguments.index(after: mapIndex)].split(separator: "/", maxSplits: 1)
            let namespaceIndex = arguments.firstIndex(of: "--namespace")!
            let path = "/dev/rbd\(nextDevice)"
            devices.append([
                "name": String(coordinate[1]),
                "pool": String(coordinate[0]),
                "namespace": arguments[arguments.index(after: namespaceIndex)],
                "device": path,
            ])
            defer { nextDevice += 1 }
            return ProcessResult(
                terminationStatus: 0,
                standardOutput: Data("\(path)\n".utf8),
                standardError: Data())
        }
        if arguments.first == "unmap", let path = arguments.last {
            if failUnmap {
                failUnmap = false
                return ProcessResult(
                    terminationStatus: 16, standardOutput: Data(),
                    standardError: Data("device is busy".utf8))
            }
            devices.removeAll { $0["device"] == path }
        }
        return ProcessResult(terminationStatus: 0, standardOutput: Data(), standardError: Data())
    }

    func replaceMappedDevice(path: String, image: String) {
        guard let index = devices.firstIndex(where: { $0["device"] == path }) else { return }
        devices[index]["image"] = image
        devices[index]["name"] = image
    }

    func failNextUnmap() { failUnmap = true }
}

@Suite("Firecracker krbd realization")
struct KRBDDiskRealizerTests {
    private static let fsid = "22222222-3333-4444-8555-666666666666"
    private let attachment = DiskAttachment.rbd(
        pool: "volumes",
        image: "strato-volume-99999999-8888-4777-8666-555555555555",
        namespace: "project-a",
        user: "strato-project",
        monEndpoints: ["v2:mon.example:3300"],
        clusterId: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!,
        credentialId: UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!,
        configPath: "/var/lib/strato/ceph/client/ceph.conf")

    private func temporaryMappingStatePath() -> (directory: URL, path: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("strato-krbd-tests-\(UUID().uuidString)")
        return (directory, directory.appendingPathComponent("mappings.json").path)
    }

    private func textReader(
        readOnlyDevices: Set<String> = []
    ) -> @Sendable (String) throws -> String {
        { path in
            if path.hasSuffix("/ceph.conf") {
                return "[global]\nfsid = \(Self.fsid)\n"
            }
            if path.hasSuffix("/cluster_fsid") { return Self.fsid }
            if path.hasSuffix("/config_info") {
                // The live kernel string may also contain an inline secret on
                // old kernels. Identity verification must consume only these
                // non-secret tokens and never surface the whole value.
                return
                    "10.0.0.1:3300 name=strato-project,key=client.strato-project,ms_mode=secure,_pool_ns=project-a volumes image -"
            }
            if path.hasSuffix("/ro") {
                let device = path.split(separator: "/").dropLast().last.map(String.init) ?? ""
                return readOnlyDevices.contains(device) ? "1\n" : "0\n"
            }
            throw CocoaError(.fileReadNoSuchFile)
        }
    }

    @Test("Mapping enforces secure messenger mode and unmaps after the last reference")
    func mapsAndUnmaps() async throws {
        let recorder = KRBDCommandRecorder()
        let state = temporaryMappingStatePath()
        defer { try? FileManager.default.removeItem(at: state.directory) }
        let realizer = KRBDDiskRealizer(
            rbdPath: "/fake/rbd",
            mappingStatePath: state.path,
            deviceExists: { _ in true },
            readTextFile: textReader(),
            runSubprocess: { executable, arguments in
                await recorder.run(executable, arguments)
            })

        let first = try await realizer.realize(attachment, readOnly: false)
        let second = try await realizer.realize(attachment, readOnly: false)
        #expect(first.realized == .blockDevice(path: "/dev/rbd0"))
        #expect(second.realized == .blockDevice(path: "/dev/rbd0"))
        #expect(first.canonical == attachment)

        try await realizer.release(first)
        #expect(await recorder.invocations.filter { $0.arguments.contains("unmap") }.isEmpty)
        try await realizer.release(second)

        let calls = await recorder.invocations
        let map = try #require(calls.first { $0.arguments.contains("map") })
        #expect(map.arguments.contains("ms_mode=secure"))
        #expect(map.arguments.contains("--namespace"))
        #expect(map.arguments.contains("project-a"))
        #expect(calls.filter { $0.arguments.contains("map") }.count == 1)
        #expect(calls.filter { $0.arguments.contains("unmap") }.count == 1)
        let unmap = try #require(calls.first { $0.arguments.contains("unmap") })
        #expect(unmap.arguments == ["unmap", "/dev/rbd0"])
    }

    @Test("Read-only and read-write mappings never share a kernel device")
    func separatesAccessModes() async throws {
        let recorder = KRBDCommandRecorder()
        let state = temporaryMappingStatePath()
        defer { try? FileManager.default.removeItem(at: state.directory) }
        let realizer = KRBDDiskRealizer(
            rbdPath: "/fake/rbd",
            mappingStatePath: state.path,
            deviceExists: { _ in true },
            readTextFile: textReader(readOnlyDevices: ["rbd0"]),
            runSubprocess: { executable, arguments in
                await recorder.run(executable, arguments)
            })

        let readOnly = try await realizer.realize(attachment, readOnly: true)
        let readWrite = try await realizer.realize(attachment, readOnly: false)
        #expect(readOnly.realized == .blockDevice(path: "/dev/rbd0"))
        #expect(readWrite.realized == .blockDevice(path: "/dev/rbd1"))
        let maps = await recorder.invocations.filter { $0.arguments.contains("map") }
        #expect(maps.count == 2)
        #expect(maps[0].arguments.contains("--read-only"))
        #expect(!maps[1].arguments.contains("--read-only"))
    }

    @Test("A restarted agent adopts and cleans up the durable kernel mapping")
    func adoptsPersistedMappingAfterRestart() async throws {
        let recorder = KRBDCommandRecorder()
        let state = temporaryMappingStatePath()
        defer { try? FileManager.default.removeItem(at: state.directory) }
        let runner: SubprocessRunner = { executable, arguments in
            await recorder.run(executable, arguments)
        }

        let originalProcess = KRBDDiskRealizer(
            rbdPath: "/fake/rbd",
            mappingStatePath: state.path,
            deviceExists: { _ in true },
            readTextFile: textReader(),
            runSubprocess: runner)
        let original = try await originalProcess.realize(attachment, readOnly: false)
        #expect(original.realized == .blockDevice(path: "/dev/rbd0"))

        // Model an unclean agent restart: the original actor disappears
        // without releasing the kernel mapping, while its durable record
        // remains for the replacement process.
        let restartedProcess = KRBDDiskRealizer(
            rbdPath: "/fake/rbd",
            mappingStatePath: state.path,
            deviceExists: { $0 == "/dev/rbd0" },
            readTextFile: textReader(),
            runSubprocess: runner)
        let adopted = try await restartedProcess.adopt(attachment, readOnly: false)
        #expect(adopted.realized == .blockDevice(path: "/dev/rbd0"))
        #expect(await recorder.invocations.filter { $0.arguments.contains("map") }.count == 1)

        try await restartedProcess.release(adopted)
        #expect(await recorder.invocations.filter { $0.arguments.contains("unmap") }.count == 1)
        let persisted = try JSONDecoder().decode(
            [String: String].self, from: Data(contentsOf: URL(fileURLWithPath: state.path)))
        #expect(persisted.isEmpty)
    }

    @Test("A reused kernel minor is never adopted as another tenant's image")
    func rejectsStalePersistedDeviceIdentity() async throws {
        let recorder = KRBDCommandRecorder()
        let state = temporaryMappingStatePath()
        defer { try? FileManager.default.removeItem(at: state.directory) }
        let runner: SubprocessRunner = { executable, arguments in
            await recorder.run(executable, arguments)
        }
        let original = KRBDDiskRealizer(
            rbdPath: "/fake/rbd", mappingStatePath: state.path,
            deviceExists: { _ in true }, readTextFile: textReader(),
            runSubprocess: runner)
        _ = try await original.realize(attachment, readOnly: false)

        // The persisted /dev/rbd0 still exists, but the kernel assigned that
        // minor to a different image after an out-of-band unmap/remap.
        await recorder.replaceMappedDevice(path: "/dev/rbd0", image: "another-tenant-volume")
        let restarted = KRBDDiskRealizer(
            rbdPath: "/fake/rbd", mappingStatePath: state.path,
            deviceExists: { _ in true }, readTextFile: textReader(),
            runSubprocess: runner)

        await #expect(throws: StorageBackendError.self) {
            try await restarted.adopt(attachment, readOnly: false)
        }
        #expect(await recorder.invocations.filter { $0.arguments.contains("unmap") }.isEmpty)
        let persisted = try JSONDecoder().decode(
            [String: String].self, from: Data(contentsOf: URL(fileURLWithPath: state.path)))
        #expect(persisted.isEmpty)
    }

    @Test("A failed unmap remains durable and blocks deletion until retry succeeds")
    func retriesFailedUnmap() async throws {
        let recorder = KRBDCommandRecorder()
        let state = temporaryMappingStatePath()
        defer { try? FileManager.default.removeItem(at: state.directory) }
        let realizer = KRBDDiskRealizer(
            rbdPath: "/fake/rbd", mappingStatePath: state.path,
            deviceExists: { _ in true }, readTextFile: textReader(),
            runSubprocess: { executable, arguments in
                await recorder.run(executable, arguments)
            })
        let disk = try await realizer.realize(attachment, readOnly: false)
        await recorder.failNextUnmap()

        await #expect(throws: StorageBackendError.self) {
            try await realizer.release(disk)
        }
        var persisted = try JSONDecoder().decode(
            [String: String].self, from: Data(contentsOf: URL(fileURLWithPath: state.path)))
        #expect(Array(persisted.values) == ["/dev/rbd0"])

        try await realizer.release(disk)
        persisted = try JSONDecoder().decode(
            [String: String].self, from: Data(contentsOf: URL(fileURLWithPath: state.path)))
        #expect(persisted.isEmpty)
        #expect(await recorder.invocations.filter { $0.arguments.contains("unmap") }.count == 2)
    }
}
