import ArgumentParser
import Foundation
import StratoCLICore

struct ProjectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "project",
        abstract: "Manage projects.",
        subcommands: [List.self, Get.self, Create.self, Delete.self],
        defaultSubcommand: List.self
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List projects you can access.")

        @OptionGroup var global: GlobalOptions

        func run() async throws {
            try await runHandlingCLIErrors {
                let environment = try CLIEnvironment.resolve(global)
                let projects: [Project] = try await environment.makeClient().get("/api/projects")
                try printResult(projects, format: global.output) {
                    var table = TextTable(headers: ["id", "name", "path", "environments", "vms"])
                    for project in projects {
                        table.addRow([
                            formatUUID(project.id), project.name, project.path ?? "",
                            project.environments?.joined(separator: ", ") ?? "",
                            project.vmCount.map(String.init) ?? "",
                        ])
                    }
                    return table
                }
            }
        }
    }

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show one project.")

        @OptionGroup var global: GlobalOptions

        @Argument(help: "Project id.")
        var id: String

        func run() async throws {
            try await runHandlingCLIErrors {
                let environment = try CLIEnvironment.resolve(global)
                let project: Project = try await environment.makeClient().get("/api/projects/\(id)")
                try printResult(project, format: global.output) {
                    var table = TextTable(headers: ["field", "value"])
                    table.addRow(["id", formatUUID(project.id)])
                    table.addRow(["name", project.name])
                    table.addRow(["description", project.description ?? ""])
                    table.addRow(["path", project.path ?? ""])
                    table.addRow(["default environment", project.defaultEnvironment ?? ""])
                    table.addRow(["environments", project.environments?.joined(separator: ", ") ?? ""])
                    table.addRow(["organization", formatUUID(project.organizationId)])
                    table.addRow(["created", formatDate(project.createdAt)])
                    return table
                }
            }
        }
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a project in an organization.")

        @OptionGroup var global: GlobalOptions

        @Argument(help: "Project name.")
        var name: String

        @Option(name: .long, help: "Organization id (defaults to the context's organization).")
        var org: String?

        @Option(name: .long, help: "Description.")
        var description: String?

        @Option(name: .long, help: "Default environment name.")
        var environment: String?

        func run() async throws {
            try await runHandlingCLIErrors {
                let env = try CLIEnvironment.resolve(global)
                guard let organizationId = org ?? env.context.organization else {
                    throw CLIError.config(
                        "No organization specified. Pass --org <id> or set one on the context.")
                }
                let request = CreateProjectRequest(
                    name: name, description: description, defaultEnvironment: environment)
                let project: Project = try await env.makeClient()
                    .post("/api/organizations/\(organizationId)/projects", body: request)
                switch global.output {
                case .table:
                    print("Project '\(project.name)' created (\(formatUUID(project.id))).")
                case .json:
                    print(try renderJSON(project))
                }
            }
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a project.")

        @OptionGroup var global: GlobalOptions

        @Argument(help: "Project id.")
        var id: String

        func run() async throws {
            try await runHandlingCLIErrors {
                let environment = try CLIEnvironment.resolve(global)
                try await environment.makeClient().deleteExpectingNoContent("/api/projects/\(id)")
                print("Project \(id) deleted.")
            }
        }
    }
}

struct OrgCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "org",
        abstract: "Inspect organizations.",
        subcommands: [List.self, Get.self],
        defaultSubcommand: List.self
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List your organizations.")

        @OptionGroup var global: GlobalOptions

        func run() async throws {
            try await runHandlingCLIErrors {
                let environment = try CLIEnvironment.resolve(global)
                let organizations: [Organization] = try await environment.makeClient()
                    .get("/api/organizations")
                try printResult(organizations, format: global.output) {
                    var table = TextTable(headers: ["id", "name", "role", "created"])
                    for organization in organizations {
                        table.addRow([
                            organization.id.uuidString.lowercased(), organization.name,
                            organization.userRole ?? "", formatDate(organization.createdAt),
                        ])
                    }
                    return table
                }
            }
        }
    }

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show one organization.")

        @OptionGroup var global: GlobalOptions

        @Argument(help: "Organization id.")
        var id: String

        func run() async throws {
            try await runHandlingCLIErrors {
                let environment = try CLIEnvironment.resolve(global)
                let organization: Organization = try await environment.makeClient()
                    .get("/api/organizations/\(id)")
                try printResult(organization, format: global.output) {
                    var table = TextTable(headers: ["field", "value"])
                    table.addRow(["id", organization.id.uuidString.lowercased()])
                    table.addRow(["name", organization.name])
                    table.addRow(["description", organization.description ?? ""])
                    table.addRow(["your role", organization.userRole ?? ""])
                    table.addRow(["created", formatDate(organization.createdAt)])
                    return table
                }
            }
        }
    }
}

struct QuotaCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quota",
        abstract: "Inspect resource quotas.",
        subcommands: [List.self, Get.self],
        defaultSubcommand: List.self
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List quotas.")

        @OptionGroup var global: GlobalOptions

        func run() async throws {
            try await runHandlingCLIErrors {
                let environment = try CLIEnvironment.resolve(global)
                let quotas: [ResourceQuota] = try await environment.makeClient().get("/api/quotas")
                try printResult(quotas, format: global.output) {
                    var table = TextTable(
                        headers: ["id", "name", "scope", "environment", "enabled", "vcpus", "memory gb", "vms"])
                    for quota in quotas {
                        table.addRow([
                            quota.id.uuidString.lowercased(), quota.name,
                            quota.entityType ?? "", quota.environment ?? "",
                            (quota.isEnabled ?? true) ? "yes" : "no",
                            quota.limits?.maxVCPUs.map(String.init) ?? "",
                            quota.limits?.maxMemoryGB.map { String(format: "%g", $0) } ?? "",
                            quota.limits?.maxVMs.map(String.init) ?? "",
                        ])
                    }
                    return table
                }
            }
        }
    }

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show one quota.")

        @OptionGroup var global: GlobalOptions

        @Argument(help: "Quota id.")
        var id: String

        func run() async throws {
            try await runHandlingCLIErrors {
                let environment = try CLIEnvironment.resolve(global)
                let quota: ResourceQuota = try await environment.makeClient().get("/api/quotas/\(id)")
                try printResult(quota, format: global.output) {
                    var table = TextTable(headers: ["field", "value"])
                    table.addRow(["id", quota.id.uuidString.lowercased()])
                    table.addRow(["name", quota.name])
                    table.addRow(["scope", quota.entityType ?? ""])
                    table.addRow(["environment", quota.environment ?? ""])
                    table.addRow(["enabled", (quota.isEnabled ?? true) ? "yes" : "no"])
                    table.addRow(["max vcpus", quota.limits?.maxVCPUs.map(String.init) ?? ""])
                    table.addRow(["max memory gb", quota.limits?.maxMemoryGB.map { String(format: "%g", $0) } ?? ""])
                    table.addRow(["max storage gb", quota.limits?.maxStorageGB.map { String(format: "%g", $0) } ?? ""])
                    table.addRow(["max vms", quota.limits?.maxVMs.map(String.init) ?? ""])
                    return table
                }
            }
        }
    }
}
