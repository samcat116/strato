import ArgumentParser
import StratoCLICore

@main
struct Strato: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "strato",
        abstract: "Command-line interface for the Strato private cloud platform.",
        version: BuildInfo.displayVersion,
        subcommands: [
            Login.self,
            Logout.self,
            ContextCommand.self,
            VMCommand.self,
            SandboxCommand.self,
            VolumeCommand.self,
            ImageCommand.self,
            NetworkCommand.self,
            AgentCommand.self,
            ProjectCommand.self,
            OrgCommand.self,
            QuotaCommand.self,
            OperationCommand.self,
        ]
    )
}

extension OutputFormat: ExpressibleByArgument {}
