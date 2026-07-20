import Foundation
import Toml

/// A named connection target: server URL plus optional default org/project.
public struct ContextConfig: Sendable, Equatable {
    public var server: String
    public var organization: String?
    public var project: String?

    public init(server: String, organization: String? = nil, project: String? = nil) {
        self.server = server
        self.organization = organization
        self.project = project
    }
}

/// The contents of `~/.config/strato/config.toml`.
public struct CLIConfig: Sendable, Equatable {
    public var currentContext: String?
    public var contexts: [String: ContextConfig]

    public init(currentContext: String? = nil, contexts: [String: ContextConfig] = [:]) {
        self.currentContext = currentContext
        self.contexts = contexts
    }
}

/// Loads and saves the CLI's TOML config file. TOML is read with swift-toml
/// (matching the agent) and written by hand — the structure is two levels deep
/// and the library has no serializer.
public struct ConfigStore: Sendable {
    public let directory: URL

    public var configFile: URL { directory.appendingPathComponent("config.toml") }

    public init(directory: URL) {
        self.directory = directory
    }

    /// Default location: `$XDG_CONFIG_HOME/strato`, falling back to
    /// `~/.config/strato` (also on macOS — a CLI belongs with dotfiles, not
    /// Application Support).
    public static func defaultDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg).appendingPathComponent("strato")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("strato")
    }

    public func load() throws -> CLIConfig {
        guard FileManager.default.fileExists(atPath: configFile.path) else {
            return CLIConfig()
        }

        let contents = try String(contentsOf: configFile, encoding: .utf8)
        let toml: Toml
        do {
            toml = try Toml(withString: contents)
        } catch {
            throw CLIError.config("Malformed config file at \(configFile.path): \(error)")
        }

        var config = CLIConfig()
        config.currentContext = toml.string("current-context")

        // Iterate [contexts.<name>] tables by path — swift-toml's tableNames
        // holds full key paths from the document root.
        for path in toml.tableNames
        where path.components.count == 2 && path.components.first == "contexts" {
            let name = path.components[1]
            let contextTable = toml.table(from: path.components)
            guard let server = contextTable.string("server") else { continue }
            config.contexts[name] = ContextConfig(
                server: server,
                organization: contextTable.string("organization"),
                project: contextTable.string("project")
            )
        }

        return config
    }

    public func save(_ config: CLIConfig) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        var lines: [String] = []
        if let current = config.currentContext {
            lines.append("current-context = \(tomlQuote(current))")
            lines.append("")
        }
        for name in config.contexts.keys.sorted() {
            guard let context = config.contexts[name] else { continue }
            lines.append("[contexts.\(tomlKey(name))]")
            lines.append("server = \(tomlQuote(context.server))")
            if let organization = context.organization {
                lines.append("organization = \(tomlQuote(organization))")
            }
            if let project = context.project {
                lines.append("project = \(tomlQuote(project))")
            }
            lines.append("")
        }

        let contents = lines.joined(separator: "\n")
        try contents.write(to: configFile, atomically: true, encoding: .utf8)
    }

    private func tomlQuote(_ value: String) -> String {
        let escaped =
            value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Bare keys allow only [A-Za-z0-9_-]; anything else must be quoted.
    private func tomlKey(_ name: String) -> String {
        let bare = name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return bare && !name.isEmpty ? name : tomlQuote(name)
    }
}
