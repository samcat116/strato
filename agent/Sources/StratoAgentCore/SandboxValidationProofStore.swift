import Foundation
import StratoShared

#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Published before a shadow VMM can spawn. Neither a failed destroy nor an
/// agent restart lends its permit or reserved capacity to another workload.
public struct SandboxValidationProof: Codable, Sendable, Equatable {
    public let id: UUID
    public let permit: UUID
    public let jailUID: UInt32
    public let cpuMicroUnits: Int64
    public let memoryBytes: Int64
    public let diskBytes: Int64
    public var proofId: String { "warm-template-suspend-proof-" + id.uuidString.lowercased() }
    public var reservation: HostReservation {
        HostReservation(memoryBytes: memoryBytes, diskBytes: diskBytes, cpuMicroUnits: cpuMicroUnits)
    }
    public init(id: UUID, permit: UUID, jailUID: UInt32, reservation: HostReservation) {
        self.id = id
        self.permit = permit
        self.jailUID = jailUID
        self.cpuMicroUnits = reservation.cpuMicroUnits
        self.memoryBytes = reservation.memoryBytes
        self.diskBytes = reservation.diskBytes
    }
}

public struct SandboxValidationProofStore: Sendable {
    private let directory: String
    public init(directory: String) { self.directory = directory }

    public func loadAll() throws -> [SandboxValidationProof] {
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: directory) } catch let error as CocoaError
            where error.code == .fileReadNoSuchFile
        { return [] }
        let records = try names.filter { $0.hasSuffix(".json") }.map { name in
            guard let id = UUID(uuidString: String(name.dropLast(5))) else {
                throw SandboxSuspensionGuard.GateError.stale
            }
            let fd = open(directory + "/" + name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw SandboxCheckpointManifest.CheckpointError.ioFailure(errno) }
            defer { _ = close(fd) }
            var metadata = stat()
            guard fstat(fd, &metadata) == 0,
                metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), metadata.st_nlink == 1,
                metadata.st_size > 0, metadata.st_size <= 4096
            else { throw SandboxSuspensionGuard.GateError.stale }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                guard count >= 0, count <= 4096 - data.count else {
                    throw SandboxSuspensionGuard.GateError.stale
                }
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            let record = try JSONDecoder().decode(SandboxValidationProof.self, from: data)
            guard record.id == id, record.jailUID != 0, record.jailUID != UInt32.max,
                record.cpuMicroUnits > 0, record.memoryBytes > 0, record.diskBytes > 0
            else { throw SandboxSuspensionGuard.GateError.stale }
            return record
        }
        guard Set(records.map(\.id)).count == records.count,
            Set(records.map(\.permit)).count == records.count
        else { throw SandboxSuspensionGuard.GateError.stale }
        return records
    }

    public func save(_ record: SandboxValidationProof) throws {
        try DurableFileWriter().write(
            JSONEncoder().encode(record), to: path(record.id), permissions: 0o600)
    }

    /// Call only after process death and artifact cleanup are confirmed.
    public func remove(_ id: UUID) throws {
        let file = path(id)
        if FileManager.default.fileExists(atPath: file) {
            try FileManager.default.removeItem(atPath: file)
        }
        try DurableFileWriter().synchronizeRemoval(at: file)
    }

    private func path(_ id: UUID) -> String { directory + "/" + id.uuidString + ".json" }
}
