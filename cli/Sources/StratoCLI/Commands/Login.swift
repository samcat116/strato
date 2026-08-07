import ArgumentParser
import Foundation
import StratoAPIClient
import StratoCLICore

struct Login: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Sign in to a Strato control plane via your browser."
    )

    @Option(name: .long, help: "Control plane URL (required the first time).")
    var server: String?

    @Option(name: .long, help: "Context name to store the login under.")
    var context: String?

    @Option(name: .long, help: "Requested scopes, space-separated (read, write, admin). Deprecated; use --actions.")
    var scopes: String = "read write"

    @Option(
        name: .long,
        help: "Limit this session to these actions, comma-separated (e.g. 'vm:*,volume:read'). Default: no limit.")
    var actions: String?

    @Option(name: .long, help: "Limit this session to one role's actions, by role id.")
    var role: String?

    @Option(name: .long, help: "Limit this session to one node, e.g. 'project'. Requires --node-id.")
    var nodeType: String?

    @Option(name: .long, help: "The id of the node named by --node-type.")
    var nodeId: String?

    func run() async throws {
        try await runHandlingCLIErrors {
            let directory = ConfigStore.defaultDirectory()
            let configStore = ConfigStore(directory: directory)
            let credentialStore = CredentialStore(directory: directory)
            var config = try configStore.load()

            // Resolve which context this login belongs to: an explicit
            // --context, else the current one, else "default".
            let contextName = context ?? config.currentContext ?? "default"
            var contextConfig =
                config.contexts[contextName]
                ?? ContextConfig(server: server ?? "")
            if let server {
                contextConfig.server = server
            }
            guard !contextConfig.server.isEmpty else {
                throw CLIError.config("No server known for context '\(contextName)'. Pass --server <url>.")
            }
            guard let serverURL = URL(string: contextConfig.server), serverURL.scheme != nil else {
                throw CLIError.config("Invalid server URL '\(contextConfig.server)'.")
            }

            let clientName = "strato CLI on \(hostname())"
            let flow = DeviceFlow(serverURL: serverURL)
            let authorization = try await flow.start(
                clientName: clientName, scopes: scopes, restriction: try requestedRestriction())

            print("To sign in, visit:\n")
            print("    \(authorization.verificationUriComplete)\n")
            print("and enter the code: \(authorization.userCode)\n")
            Browser.open(authorization.verificationUriComplete)
            print("Waiting for approval in the browser...")

            let token = try await flow.pollForToken(authorization)

            try credentialStore.store(
                StoredCredentials(
                    accessToken: token.accessToken,
                    refreshToken: token.refreshToken,
                    expiresAt: Date().addingTimeInterval(TimeInterval(token.expiresIn))
                ),
                for: contextName
            )

            config.contexts[contextName] = contextConfig
            if config.currentContext == nil {
                config.currentContext = contextName
            }
            try configStore.save(config)

            print("Signed in. Context '\(contextName)' -> \(contextConfig.server)")
        }
    }

    /// The restriction to ask for, or nil when none of the narrowing flags were
    /// given. The server validates the contents; this only checks the shape, so
    /// a typo costs a message rather than a round trip.
    private func requestedRestriction() throws -> Components.Schemas.CredentialRestriction? {
        let actionList = actions?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        if actionList != nil && role != nil {
            throw CLIError.config("Pass either --actions or --role, not both.")
        }
        if (nodeType == nil) != (nodeId == nil) {
            throw CLIError.config("--node-type and --node-id must be given together.")
        }
        guard actionList != nil || role != nil || nodeType != nil else { return nil }

        if let role, Foundation.UUID(uuidString: role) == nil {
            throw CLIError.config("--role must be a role id (UUID).")
        }
        if let nodeId, Foundation.UUID(uuidString: nodeId) == nil {
            throw CLIError.config("--node-id must be a UUID.")
        }
        // A node scope with no action list is still a narrowing: everything the
        // owner can do, but only inside that subtree.
        return .init(
            role: role,
            actions: actionList ?? (role == nil ? ["*"] : nil),
            nodeType: nodeType,
            nodeId: nodeId)
    }

    private func hostname() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        gethostname(&buffer, buffer.count)
        return String(cString: buffer, encoding: .utf8) ?? "unknown host"
    }
}

struct Logout: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Sign out and revoke this device's tokens."
    )

    @Option(name: .long, help: "Context to sign out of (defaults to current-context).")
    var context: String?

    func run() async throws {
        try await runHandlingCLIErrors {
            let directory = ConfigStore.defaultDirectory()
            let configStore = ConfigStore(directory: directory)
            let credentialStore = CredentialStore(directory: directory)
            let config = try configStore.load()

            guard let contextName = context ?? config.currentContext else {
                throw CLIError.config("No context to sign out of.")
            }

            guard let credentials = try credentialStore.credentials(for: contextName) else {
                print("Not signed in for context '\(contextName)'.")
                return
            }

            // Revoke server-side, then delete locally either way.
            if let contextConfig = config.contexts[contextName],
                let serverURL = URL(string: contextConfig.server)
            {
                let flow = DeviceFlow(serverURL: serverURL)
                try? await flow.revoke(token: credentials.refreshToken)
            }
            try credentialStore.delete(for: contextName)
            print("Signed out of context '\(contextName)'.")
        }
    }
}
