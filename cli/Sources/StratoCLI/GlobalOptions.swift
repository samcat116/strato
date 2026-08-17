import ArgumentParser
import Foundation
import StratoAPIClient
import StratoCLICore

/// Options shared by every command that talks to a control plane.
struct ConnectionOptions: ParsableArguments {
    @Option(name: .long, help: "Named context from the config file (defaults to current-context).")
    var context: String?

    @Option(name: .long, help: "Control plane URL, overriding the context's server.")
    var server: String?
}

struct GlobalOptions: ParsableArguments {
    @OptionGroup var connection: ConnectionOptions

    @Option(name: [.customShort("o"), .customLong("output")], help: "Output format: table or json.")
    var output: OutputFormat = .table
}

/// The resolved runtime environment for one invocation: which context is
/// active, where its config lives, and a client for its server.
struct CLIEnvironment {
    let configStore: ConfigStore
    let credentialStore: CredentialStore
    let contextName: String
    let context: ContextConfig
    let serverURL: URL

    static func resolve(_ options: GlobalOptions) throws -> CLIEnvironment {
        try resolve(options.connection)
    }

    static func resolve(_ options: ConnectionOptions) throws -> CLIEnvironment {
        let directory = ConfigStore.defaultDirectory()
        let configStore = ConfigStore(directory: directory)
        let credentialStore = CredentialStore(directory: directory)
        let config = try configStore.load()

        let contextName: String
        var context: ContextConfig
        if let requested = options.context {
            guard let found = config.contexts[requested] else {
                throw CLIError.config(
                    "Unknown context '\(requested)'. Add it with "
                        + "'strato context set \(requested) --server <url>'.")
            }
            contextName = requested
            context = found
        } else if let current = config.currentContext, let found = config.contexts[current] {
            contextName = current
            context = found
        } else if let server = options.server {
            // --server with no configured context: an ad-hoc "default" context
            // so login can bootstrap a fresh machine in one step.
            contextName = "default"
            context = ContextConfig(server: server)
        } else {
            throw CLIError.config(
                "No context configured. Run 'strato login --server <url>' to get started.")
        }

        if let server = options.server {
            context.server = server
        }

        guard let serverURL = URL(string: context.server), serverURL.scheme != nil else {
            throw CLIError.config("Invalid server URL '\(context.server)'.")
        }

        return CLIEnvironment(
            configStore: configStore,
            credentialStore: credentialStore,
            contextName: contextName,
            context: context,
            serverURL: serverURL
        )
    }

    func makeClient() -> any APIProtocol {
        makeAuthenticatedSession().client
    }

    func makeAuthenticatedSession() -> StratoClient.AuthenticatedSession {
        StratoClient.authenticatedSession(
            serverURL: serverURL, contextName: contextName, credentialStore: credentialStore)
    }
}

/// Prints a `CLIError` to stderr and exits nonzero; other errors bubble up to
/// ArgumentParser's default handling. Errors thrown by a generated operation
/// arrive wrapped in the runtime's `ClientError`, so they are unwrapped first.
func runHandlingCLIErrors(_ body: () async throws -> Void) async throws {
    do {
        try await body()
    } catch {
        guard let cliError = CLIError.from(error) else { throw error }
        FileHandle.standardError.write(Data("Error: \(cliError.description)\n".utf8))
        throw ExitCode.failure
    }
}
