import ArgumentParser
import Foundation
import StratoAPIClient
import StratoCLICore

struct ResourceClassCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resource-class", abstract: "Inspect and configure site workload resource classes.",
        subcommands: [List.self, Configure.self], defaultSubcommand: List.self)

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show the site's guaranteed and burstable policies.")
        @OptionGroup var global: GlobalOptions
        @Option(name: .long, help: "Site UUID.") var site: String
        func run() async throws {
            try await runHandlingCLIErrors {
                let env = try CLIEnvironment.resolve(global)
                let result = try await env.makeClient().getSite(path: .init(siteId: site)).ok.body.json
                // Flattened snapshot JSON is also the exact transport contract.
                try printResourceClasses(result.resourceClasses ?? [], format: global.output)
            }
        }
    }

    struct Configure: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract:
                "Configure burstable policy. Bounds are policy limits, not safe-overcommit recommendations; assignment requires verified runtime enforcement."
        )
        @OptionGroup var global: GlobalOptions
        @Option(name: .long, help: "Site UUID.") var site: String
        @Option(name: .long, help: "CPU allocation ratio, 1 through 64.") var cpuRatio: Double = 4
        @Option(name: .long, help: "Memory allocation ratio, 1 through 16.") var memoryRatio: Double = 1
        @Option(name: .long, help: "Fair-share CPU weight, 1 through 10000.") var cpuWeight: Int = 100
        @Option(name: .long, help: "Memory high as percent of current guest grant, 1 through 99.")
        var memoryHighPercent: Int = 80
        @Option(name: .long) var maxCpuPressure10: Double = 10
        @Option(name: .long) var maxMemoryPressure10: Double = 5
        @Option(name: .long) var maxTelemetryAgeSeconds: Int = 60
        func run() async throws {
            try await runHandlingCLIErrors {
                let env = try CLIEnvironment.resolve(global)
                let client = env.makeClient()
                let existing = try await client.getSite(path: .init(siteId: site)).ok.body.json
                let policy = Components.Schemas.WorkloadResourceClassPolicy(
                    kind: .burstable, cpuAllocationRatio: cpuRatio, memoryAllocationRatio: memoryRatio,
                    cpuWeight: cpuWeight, memoryHighPercent: memoryHighPercent, hardLimitPolicy: .guestAndBackend,
                    maxCPUPressure10: maxCpuPressure10, maxMemoryPressure10: maxMemoryPressure10,
                    maxTelemetryAgeSeconds: maxTelemetryAgeSeconds)
                let result = try await client.updateSite(
                    path: .init(siteId: site),
                    body: .json(
                        .init(
                            burstableResourcePolicy: policy, description: existing.description,
                            networkControllerAgentId: existing.networkControllerAgentId,
                            latitude: existing.latitude, longitude: existing.longitude,
                            locationLabel: existing.locationLabel, regionCode: existing.regionCode,
                            labels: .init(additionalProperties: existing.labels.additionalProperties)
                        ))
                ).ok.body.json
                try printResourceClasses(result.resourceClasses ?? [], format: global.output)
            }
        }
    }
}

private func printResourceClasses(_ classes: [Components.Schemas.WorkloadResourceClassSnapshot], format: OutputFormat)
    throws
{
    try printResult(classes, format: format) {
        var table = TextTable(headers: [
            "class", "id", "revision", "CPU ratio", "memory ratio", "weight", "memory high", "admission",
        ])
        for snapshot in classes {
            let policy = snapshot.value1
            table.addRow([
                policy.kind.rawValue, snapshot.value2.classID, String(snapshot.value2.revision),
                String(policy.cpuAllocationRatio), String(policy.memoryAllocationRatio), String(policy.cpuWeight),
                String(policy.memoryHighPercent), policy.kind == .guaranteed ? "default" : "unavailable",
            ])
        }
        return table
    }
}
