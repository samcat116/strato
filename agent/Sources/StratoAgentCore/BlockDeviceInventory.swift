import Foundation
import Logging
import StratoShared

public struct BlockDeviceInventoryProbe: Sendable {
    typealias Runner = @Sendable (
        _ executableURL: URL,
        _ arguments: [String],
        _ timeout: Duration?,
        _ environment: [String: String]?,
        _ maxOutputBytes: Int?
    ) async throws -> ProcessResult

    public static let timeout: Duration = .seconds(5)
    public static let maxOutputBytes = 4 * 1024 * 1024

    private static let arguments = [
        "--json", "--bytes", "--tree", "--output",
        "NAME,PATH,TYPE,SIZE,MODEL,SERIAL,WWN,ROTA,RO,FSTYPE,PTTYPE,MOUNTPOINTS,STATE",
    ]
    private static let defaultExecutableCandidates = [
        URL(fileURLWithPath: "/usr/bin/lsblk"),
        URL(fileURLWithPath: "/bin/lsblk"),
        URL(fileURLWithPath: "/usr/sbin/lsblk"),
        URL(fileURLWithPath: "/sbin/lsblk"),
    ]

    private let executableCandidates: [URL]
    private let fileExists: @Sendable (String) -> Bool
    private let run: Runner

    public init() {
        executableCandidates = Self.defaultExecutableCandidates
        fileExists = { FileManager.default.fileExists(atPath: $0) }
        run = { executableURL, arguments, timeout, environment, maxOutputBytes in
            try await ProcessRunner.run(
                executableURL: executableURL,
                arguments: arguments,
                timeout: timeout,
                environment: environment,
                maxOutputBytes: maxOutputBytes)
        }
    }

    init(
        executableCandidates: [URL],
        fileExists: @escaping @Sendable (String) -> Bool,
        run: @escaping Runner
    ) {
        self.executableCandidates = executableCandidates
        self.fileExists = fileExists
        self.run = run
    }

    public func observe() async -> [ObservedStorageDevice]? {
        #if os(Linux)
        return await observeUsingCandidates()
        #else
        return nil
        #endif
    }

    func observeUsingCandidates() async -> [ObservedStorageDevice]? {
        let logger = Logger(label: "strato-agent.storage-device-inventory")
        guard let executableURL = executableCandidates.first(where: { fileExists($0.path) }) else {
            logger.warning("lsblk is unavailable; storage inventory is unknown")
            return nil
        }

        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        do {
            let result = try await run(
                executableURL,
                Self.arguments,
                Self.timeout,
                environment,
                Self.maxOutputBytes)
            guard result.terminationStatus == 0 else {
                logger.warning(
                    "lsblk failed; storage inventory is unknown",
                    metadata: [
                        "status": .stringConvertible(result.terminationStatus),
                        "diagnostic": .string(Self.boundedDiagnostic(result.standardError)),
                    ])
                return nil
            }
            return try Self.decode(result.standardOutput)
        } catch {
            logger.warning(
                "lsblk observation failed; storage inventory is unknown",
                metadata: ["error": .string(Self.boundedDiagnostic(Data(String(describing: error).utf8)))])
            return nil
        }
    }

    static func decode(_ data: Data) throws -> [ObservedStorageDevice] {
        let document = try JSONDecoder().decode(LSBLKDocument.self, from: data)
        return try document.blockdevices.flatMap { try observations(in: $0) }
            .sorted { $0.devicePath < $1.devicePath }
    }

    private static func boundedDiagnostic(_ data: Data) -> String {
        let prefix = data.prefix(512)
        let text = String(decoding: prefix, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "none" : text
    }

    private static func observations(in node: LSBLKNode) throws -> [ObservedStorageDevice] {
        var result: [ObservedStorageDevice] = []
        if normalized(node.type) == "disk" {
            result.append(try observation(from: node))
        }
        for child in node.children ?? [] {
            result.append(contentsOf: try observations(in: child))
        }
        return result
    }

    private static func observation(from node: LSBLKNode) throws -> ObservedStorageDevice {
        guard let path = normalized(node.path), path.hasPrefix("/dev/") else {
            throw BlockDeviceInventoryError.invalidDiskPath
        }
        guard let size = node.size?.value, size >= 0 else {
            throw BlockDeviceInventoryError.invalidDiskSize
        }
        guard let rotational = node.rota?.value else {
            throw BlockDeviceInventoryError.missingRotationalFlag
        }

        let model = normalized(node.model)
        let serial = normalized(node.serial)
        let wwn = normalized(node.wwn)
        let uses = Array(collectUses(from: node)).sorted { $0.rawValue < $1.rawValue }
        let state: StorageDeviceState
        if size == 0 || isFaultedKernelState(node.state) {
            state = .faulted
        } else if uses.isEmpty {
            state = .available
        } else {
            state = .inUse
        }

        return ObservedStorageDevice(
            identity: StorageDeviceIdentity.preferred(wwn: wwn, serial: serial),
            devicePath: path,
            sizeBytes: size,
            model: model,
            serial: serial,
            wwn: wwn,
            rotational: rotational,
            state: state,
            uses: uses
        )
    }

    private static func collectUses(from node: LSBLKNode) -> Set<StorageDeviceUse> {
        var uses: Set<StorageDeviceUse> = []
        let children = node.children ?? []
        if !children.isEmpty {
            uses.insert(.childDevice)
        }
        if normalized(node.pttype) != nil {
            uses.insert(.partitionTable)
        }

        if let filesystem = normalized(node.fstype)?.lowercased() {
            switch filesystem {
            case "swap":
                uses.insert(.swap)
            case "lvm2_member":
                uses.insert(.lvmPhysicalVolume)
            default:
                uses.insert(.filesystem)
            }
        }
        if normalized(node.type)?.lowercased() == "lvm" {
            uses.insert(.lvmPhysicalVolume)
        }

        let mountpoints = node.mountpoints?.values.compactMap(normalized) ?? []
        if !mountpoints.isEmpty {
            uses.insert(.mounted)
        }
        if mountpoints.contains(where: { $0.uppercased() == "[SWAP]" }) {
            uses.insert(.swap)
        }
        if node.readOnly?.value == true {
            uses.insert(.readOnly)
        }

        for child in children {
            uses.formUnion(collectUses(from: child))
        }
        return uses
    }

    private static func isFaultedKernelState(_ value: String?) -> Bool {
        guard let state = normalized(value)?.lowercased() else { return false }
        return ["offline", "faulted", "failed", "dead"].contains(state)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}

public actor StorageDeviceInventoryCache {
    public typealias Observer = @Sendable () async -> [ObservedStorageDevice]?

    private let minimumRefreshInterval: Duration
    private let observer: Observer
    private var latestOutcome: [ObservedStorageDevice]?
    private var lastAttemptAt: ContinuousClock.Instant?
    private var inFlight: Task<[ObservedStorageDevice]?, Never>?

    public init(
        minimumRefreshInterval: Duration = .seconds(30),
        observer: @escaping Observer
    ) {
        self.minimumRefreshInterval = minimumRefreshInterval
        self.observer = observer
    }

    public func refresh(
        force: Bool = false,
        now: ContinuousClock.Instant = .now
    ) async {
        if let inFlight {
            latestOutcome = await inFlight.value
            return
        }
        if !force, let lastAttemptAt, now - lastAttemptAt < minimumRefreshInterval {
            return
        }

        lastAttemptAt = now
        let observer = self.observer
        let task = Task { await observer() }
        inFlight = task
        latestOutcome = await task.value
        inFlight = nil
    }

    /// Registration and re-registration need a fresh view even when the prior
    /// heartbeat observed the host moments ago.
    public func refreshForRegistration(
        now: ContinuousClock.Instant = .now
    ) async -> [ObservedStorageDevice]? {
        await refresh(force: true, now: now)
        return latestOutcome
    }

    /// Heartbeats reuse the cadence gate so block-device discovery cannot turn
    /// a fast liveness signal into an unbounded stream of subprocesses.
    public func refreshForHeartbeat(
        now: ContinuousClock.Instant = .now
    ) async -> [ObservedStorageDevice]? {
        await refresh(now: now)
        return latestOutcome
    }

    public func snapshot() -> [ObservedStorageDevice]? {
        latestOutcome
    }
}

enum BlockDeviceInventoryError: Error {
    case invalidDiskPath
    case invalidDiskSize
    case missingRotationalFlag
}

private struct LSBLKDocument: Decodable {
    let blockdevices: [LSBLKNode]
}

private struct LSBLKNode: Decodable {
    let path: String?
    let type: String?
    let size: FlexibleInt64?
    let model: String?
    let serial: String?
    let wwn: String?
    let rota: FlexibleBool?
    let readOnly: FlexibleBool?
    let fstype: String?
    let pttype: String?
    let mountpoints: FlexibleStringArray?
    let state: String?
    let children: [LSBLKNode]?

    private enum CodingKeys: String, CodingKey {
        case path
        case type
        case size
        case model
        case serial
        case wwn
        case rota
        case readOnly = "ro"
        case fstype
        case pttype
        case mountpoints
        case state
        case children
    }
}

private struct FlexibleInt64: Decodable {
    let value: Int64

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) {
            self.value = value
            return
        }
        if let string = try? container.decode(String.self), let value = Int64(string) {
            self.value = value
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container, debugDescription: "Expected an integer or integer string")
    }
}

private struct FlexibleBool: Decodable {
    let value: Bool

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self.value = value
            return
        }
        if let value = try? container.decode(Int.self), value == 0 || value == 1 {
            self.value = value == 1
            return
        }
        if let string = try? container.decode(String.self) {
            switch string.lowercased() {
            case "0", "false":
                self.value = false
                return
            case "1", "true":
                self.value = true
                return
            default:
                break
            }
        }
        throw DecodingError.dataCorruptedError(
            in: container, debugDescription: "Expected a Boolean, zero, or one")
    }
}

private struct FlexibleStringArray: Decodable {
    let values: [String?]

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            values = []
        } else if let values = try? container.decode([String?].self) {
            self.values = values
        } else {
            values = [try container.decode(String.self)]
        }
    }
}
