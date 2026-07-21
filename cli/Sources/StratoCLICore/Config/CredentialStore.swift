import Foundation

/// The token pair stored for one context.
public struct StoredCredentials: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    /// When the access token expires; used to refresh proactively.
    public var expiresAt: Date?

    public init(accessToken: String, refreshToken: String, expiresAt: Date? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

/// Persists tokens in `credentials.json` next to the config file, keyed by
/// context name. File mode 0600 (directory 0700) — tokens are secrets.
/// Keychain integration can come later; a file works everywhere including
/// headless hosts.
public struct CredentialStore: Sendable {
    public let directory: URL

    public var credentialsFile: URL { directory.appendingPathComponent("credentials.json") }

    public init(directory: URL) {
        self.directory = directory
    }

    public func credentials(for context: String) throws -> StoredCredentials? {
        try loadAll()[context]
    }

    public func store(_ credentials: StoredCredentials, for context: String) throws {
        var all = try loadAll()
        all[context] = credentials
        try saveAll(all)
    }

    public func delete(for context: String) throws {
        var all = try loadAll()
        guard all.removeValue(forKey: context) != nil else { return }
        try saveAll(all)
    }

    private func loadAll() throws -> [String: StoredCredentials] {
        guard FileManager.default.fileExists(atPath: credentialsFile.path) else {
            return [:]
        }
        let data = try Data(contentsOf: credentialsFile)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([String: StoredCredentials].self, from: data)
        } catch {
            throw CLIError.config("Corrupt credentials file at \(credentialsFile.path); delete it and log in again.")
        }
    }

    private func saveAll(_ all: [String: StoredCredentials]) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(all)

        // Write, then clamp permissions. writingOptions can't set mode, and
        // createFile would race a concurrent reader.
        try data.write(to: credentialsFile, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: credentialsFile.path)
    }
}
