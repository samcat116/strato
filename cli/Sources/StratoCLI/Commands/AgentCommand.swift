import ArgumentParser
import Foundation
import StratoCLICore

struct AgentCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent",
        abstract: "Manage hypervisor node agents.",
        subcommands: [List.self, Get.self, Enroll.self],
        defaultSubcommand: List.self
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List agents.")

        @OptionGroup var global: GlobalOptions

        func run() async throws {
            try await runHandlingCLIErrors {
                let environment = try CLIEnvironment.resolve(global)
                let agents: [Agent] = try await environment.makeClient().get("/api/agents")
                try printResult(agents, format: global.output) {
                    var table = TextTable(
                        headers: ["id", "name", "hostname", "version", "arch", "online", "last heartbeat"])
                    for agent in agents {
                        table.addRow([
                            agent.id.uuidString.lowercased(), agent.name, agent.hostname ?? "",
                            agent.version ?? "", agent.architecture ?? "",
                            (agent.isOnline ?? false) ? "yes" : "no",
                            formatDate(agent.lastHeartbeat),
                        ])
                    }
                    return table
                }
            }
        }
    }

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show one agent.")

        @OptionGroup var global: GlobalOptions

        @Argument(help: "Agent id.")
        var id: String

        func run() async throws {
            try await runHandlingCLIErrors {
                let environment = try CLIEnvironment.resolve(global)
                let agent: Agent = try await environment.makeClient().get("/api/agents/\(id)")
                try printResult(agent, format: global.output) {
                    var table = TextTable(headers: ["field", "value"])
                    table.addRow(["id", agent.id.uuidString.lowercased()])
                    table.addRow(["name", agent.name])
                    table.addRow(["hostname", agent.hostname ?? ""])
                    table.addRow(["version", agent.version ?? ""])
                    table.addRow(["architecture", agent.architecture ?? ""])
                    table.addRow(["os", agent.operatingSystem ?? ""])
                    table.addRow(["online", (agent.isOnline ?? false) ? "yes" : "no"])
                    table.addRow(["last heartbeat", formatDate(agent.lastHeartbeat)])
                    table.addRow(["registered", formatDate(agent.createdAt)])
                    return table
                }
            }
        }
    }

    struct Enroll: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Enroll a new hypervisor node, printing its bootstrap command.")

        @OptionGroup var global: GlobalOptions

        @Argument(help: "Name for the new agent.")
        var name: String

        @Option(name: .long, help: "Owning organization id (defaults to the context's organization).")
        var org: String?

        @Option(name: .long, help: "Owning folder (organizational unit) id.")
        var folder: String?

        @Option(name: .long, help: "Site id to place the agent in.")
        var site: String?

        @Option(name: .long, help: "Hours before the enrollment expires.")
        var expiresIn: Int?

        func run() async throws {
            try await runHandlingCLIErrors {
                let env = try CLIEnvironment.resolve(global)
                let organizationId = org ?? (folder == nil ? env.context.organization : nil)
                guard organizationId != nil || folder != nil else {
                    throw CLIError.config(
                        "An enrollment needs an owning scope: pass --org <id> or --folder <id>, "
                            + "or set an organization on the context.")
                }

                let request = CreateAgentEnrollmentRequest(
                    agentName: name, expirationHours: expiresIn, siteId: site,
                    organizationId: organizationId, organizationalUnitId: folder
                )
                let enrollment: AgentEnrollment = try await env.makeClient()
                    .post("/api/agents/enrollments", body: request)

                switch global.output {
                case .table:
                    print("Enrollment for '\(enrollment.agentName)' created.")
                    if let expiresAt = enrollment.expiresAt {
                        print("Expires: \(formatDate(expiresAt))")
                    }
                    print("\nRun this on the new node:\n")
                    print("    \(enrollment.bootstrapCommand)")
                case .json:
                    print(try renderJSON(enrollment))
                }
            }
        }
    }
}
