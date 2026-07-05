import Foundation
import Logging
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Join state persisted across agent restarts.
///
/// Registration tokens are single-use: the control plane consumes the token an
/// agent presents and returns a rotated one in the registration response. That
/// rotated token only lives in memory during a run, so without this file an
/// agent restart after its original join token was consumed could never
/// reconnect. The agent saves this state after every successful registration
/// (first join and each rotation) and dials from it on startup.
public struct AgentState: Codable, Equatable, Sendable {
    /// Format version for forward compatibility.
    public var version: Int
    /// Human-readable agent name assigned by the control plane.
    public var agentName: String
    /// Database UUID the control plane assigned to this agent.
    public var assignedAgentID: String?
    /// Control plane WebSocket URL without query parameters
    /// (e.g. `ws://control-plane:8080/agent/ws`).
    public var controlPlaneURL: String
    /// Current single-use reconnect token.
    public var reconnectToken: String
    public var updatedAt: Date

    public static let currentVersion = 1

    public init(
        version: Int = AgentState.currentVersion,
        agentName: String,
        assignedAgentID: String? = nil,
        controlPlaneURL: String,
        reconnectToken: String,
        updatedAt: Date = Date()
    ) {
        self.version = version
        self.agentName = agentName
        self.assignedAgentID = assignedAgentID
        self.controlPlaneURL = controlPlaneURL
        self.reconnectToken = reconnectToken
        self.updatedAt = updatedAt
    }
}

public protocol AgentStateStore: Sendable {
    /// Returns the persisted state, or nil when absent or unreadable.
    func load() -> AgentState?
    func save(_ state: AgentState) throws
    /// Human-readable location of the store, for log messages.
    var location: String { get }
}

/// File-backed state store. The file holds the reconnect token, so it is
/// written with mode 0600 (and the containing directory created 0700).
public struct FileAgentStateStore: AgentStateStore {
    public let path: String
    private let logger: Logger?

    /// Default state file path (platform-specific, next to the other agent data).
    public static var defaultPath: String {
        #if os(macOS)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/strato/agent-state.json"
        #else
        return "/var/lib/strato/agent-state.json"
        #endif
    }

    public init(path: String = FileAgentStateStore.defaultPath, logger: Logger? = nil) {
        self.path = path
        self.logger = logger
    }

    public var location: String { path }

    public func load() -> AgentState? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(AgentState.self, from: data)
        } catch {
            // A corrupt state file must not brick the agent, but must not be
            // silently destroyed either: move it aside so the evidence
            // survives, and let the caller fall back to explicit join.
            logger?.error("Agent state file at \(path) is unreadable (\(error)); moving it aside")
            let corruptPath = path + ".corrupt"
            try? fileManager.removeItem(atPath: corruptPath)
            try? fileManager.moveItem(atPath: path, toPath: corruptPath)
            return nil
        }
    }

    public func save(_ state: AgentState) throws {
        let fileManager = FileManager.default
        let directory = (path as NSString).deletingLastPathComponent

        if !fileManager.fileExists(atPath: directory) {
            try fileManager.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)

        // Atomic replace: write a temp file in the same directory, then rename
        // over the destination, so a crash mid-write never truncates the state.
        //
        // Use POSIX rename(2) directly rather than FileManager. rename(2)
        // atomically replaces an existing destination on the same filesystem,
        // whether or not it already exists — so there is no separate
        // create-vs-overwrite branch. FileManager's alternatives are both
        // unsuitable on Linux: moveItem throws if the destination exists, and
        // replaceItemAt on swift-corelibs-foundation fails against an existing
        // file with "The file doesn't exist" (NSCocoaError 4), which is exactly
        // the reconnect-time persistence failure this avoids.
        let tempPath = directory + "/.agent-state-\(UUID().uuidString).tmp"
        guard
            fileManager.createFile(
                atPath: tempPath,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            )
        else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: tempPath])
        }
        if rename(tempPath, path) != 0 {
            let code = errno
            try? fileManager.removeItem(atPath: tempPath)
            throw CocoaError(
                .fileWriteUnknown,
                userInfo: [
                    NSFilePathErrorKey: path,
                    NSLocalizedDescriptionKey: "rename to \(path) failed: \(String(cString: strerror(code)))",
                ])
        }
        // The temp file was created 0600 and rename preserves the inode's mode,
        // so the destination already carries the restrictive permissions.
    }

    /// Verifies the store can actually persist state, creating the directory
    /// if needed. Called before a join consumes its single-use token: state
    /// paths default to root-owned locations (/var/lib/strato), and discovering
    /// unwritability only after registration would leave the agent connected
    /// but unable to survive a restart — with the join token already spent.
    public func ensureWritable() throws {
        let fileManager = FileManager.default
        let directory = (path as NSString).deletingLastPathComponent

        if !fileManager.fileExists(atPath: directory) {
            try fileManager.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        let probePath = directory + "/.agent-state-probe-\(UUID().uuidString).tmp"
        guard fileManager.createFile(atPath: probePath, contents: Data(), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: directory])
        }
        try? fileManager.removeItem(atPath: probePath)
    }
}
