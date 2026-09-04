import ArgumentParser
import StratoAgentRuntime

@main
struct StratoAgentMain: AsyncParsableCommand {
    static let configuration = StratoAgent.configuration

    mutating func run() async throws {}
}
