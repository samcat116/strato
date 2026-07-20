import ArgumentParser
import Foundation
import StratoCLICore

struct ContextCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "context",
        abstract: "Manage named connection contexts.",
        subcommands: [List.self, Use.self, Show.self, Set.self, Delete.self],
        defaultSubcommand: List.self
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List configured contexts.")

        func run() async throws {
            try await runHandlingCLIErrors {
                let store = ConfigStore(directory: ConfigStore.defaultDirectory())
                let config = try store.load()

                if config.contexts.isEmpty {
                    print("No contexts configured. Run 'strato login --server <url>' to get started.")
                    return
                }

                var table = TextTable(headers: ["current", "name", "server", "organization", "project"])
                for name in config.contexts.keys.sorted() {
                    guard let context = config.contexts[name] else { continue }
                    table.addRow([
                        name == config.currentContext ? "*" : "",
                        name,
                        context.server,
                        context.organization ?? "",
                        context.project ?? "",
                    ])
                }
                print(table.render())
            }
        }
    }

    struct Use: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Switch the current context.")

        @Argument(help: "Context name.")
        var name: String

        func run() async throws {
            try await runHandlingCLIErrors {
                let store = ConfigStore(directory: ConfigStore.defaultDirectory())
                var config = try store.load()
                guard config.contexts[name] != nil else {
                    throw CLIError.config("Unknown context '\(name)'.")
                }
                config.currentContext = name
                try store.save(config)
                print("Switched to context '\(name)'.")
            }
        }
    }

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show the current context.")

        func run() async throws {
            try await runHandlingCLIErrors {
                let store = ConfigStore(directory: ConfigStore.defaultDirectory())
                let config = try store.load()
                guard let current = config.currentContext, let context = config.contexts[current] else {
                    print("No current context.")
                    return
                }
                print("name:         \(current)")
                print("server:       \(context.server)")
                print("organization: \(context.organization ?? "-")")
                print("project:      \(context.project ?? "-")")
            }
        }
    }

    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create or update a context.")

        @Argument(help: "Context name.")
        var name: String

        @Option(name: .long, help: "Control plane URL.")
        var server: String?

        @Option(name: .long, help: "Default organization id.")
        var org: String?

        @Option(name: .long, help: "Default project id.")
        var project: String?

        func run() async throws {
            try await runHandlingCLIErrors {
                let store = ConfigStore(directory: ConfigStore.defaultDirectory())
                var config = try store.load()

                var context = config.contexts[name] ?? ContextConfig(server: "")
                if let server { context.server = server }
                if let org { context.organization = org }
                if let project { context.project = project }
                guard !context.server.isEmpty else {
                    throw CLIError.config("A context needs a server; pass --server <url>.")
                }

                config.contexts[name] = context
                if config.currentContext == nil {
                    config.currentContext = name
                }
                try store.save(config)
                print("Context '\(name)' saved.")
            }
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a context and its stored credentials.")

        @Argument(help: "Context name.")
        var name: String

        func run() async throws {
            try await runHandlingCLIErrors {
                let directory = ConfigStore.defaultDirectory()
                let store = ConfigStore(directory: directory)
                var config = try store.load()
                guard config.contexts.removeValue(forKey: name) != nil else {
                    throw CLIError.config("Unknown context '\(name)'.")
                }
                if config.currentContext == name {
                    config.currentContext = config.contexts.keys.sorted().first
                }
                try store.save(config)
                try CredentialStore(directory: directory).delete(for: name)
                print("Context '\(name)' deleted.")
            }
        }
    }
}
