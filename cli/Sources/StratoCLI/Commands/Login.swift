import ArgumentParser
import Foundation
import StratoCLICore

struct Login: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Sign in to a Strato control plane via your browser."
    )

    @Option(name: .long, help: "Control plane URL (required the first time).")
    var server: String?

    @Option(name: .long, help: "Context name to store the login under.")
    var context: String?

    @Option(name: .long, help: "Requested scopes, space-separated (read, write, admin).")
    var scopes: String = "read write"

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
            let authorization = try await flow.start(clientName: clientName, scopes: scopes)

            let url = authorization.verificationUriComplete ?? authorization.verificationUri
            print("To sign in, visit:\n")
            print("    \(url)\n")
            print("and enter the code: \(authorization.userCode)\n")
            Browser.open(url)
            print("Waiting for approval in the browser...")

            let token = try await flow.pollForToken(authorization)

            try credentialStore.store(
                StoredCredentials(
                    accessToken: token.accessToken,
                    refreshToken: token.refreshToken,
                    expiresAt: token.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
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
