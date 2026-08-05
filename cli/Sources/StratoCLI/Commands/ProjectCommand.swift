import ArgumentParser
import Foundation
import StratoAPIClient
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
                let projects = try await environment.makeClient().listProjects().ok.body.json
                try printResult(projects, format: global.output) {
                    var table = TextTable(headers: ["id", "name", "path", "environments", "vms"])
                    for project in projects {
                        table.addRow([
                            project.id, project.name, project.path,
                            project.environments.joined(separator: ", "),
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
                let detail = try await environment.makeClient()
                    .getProject(path: .init(projectID: id)).ok.body.json
                // `ProjectDetail` is `allOf: [ProjectSummary, {quotas}]`, which
                // the generator splits into `value1`/`value2`.
                let project = detail.value1
                try printResult(detail, format: global.output) {
                    var table = TextTable(headers: ["field", "value"])
                    table.addRow(["id", project.id])
                    table.addRow(["name", project.name])
                    table.addRow(["description", project.description])
                    table.addRow(["path", project.path])
                    table.addRow(["default environment", project.defaultEnvironment])
                    table.addRow(["environments", project.environments.joined(separator: ", ")])
                    table.addRow(["organization", project.organizationId ?? ""])
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
                let detail = try await env.makeClient().createOrganizationProject(
                    path: .init(organizationID: organizationId),
                    body: .json(
                        .init(
                            name: name, description: description ?? "",
                            defaultEnvironment: environment))
                ).ok.body.json
                switch global.output {
                case .table:
                    print("Project '\(detail.value1.name)' created (\(detail.value1.id)).")
                case .json:
                    print(try renderJSON(detail))
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
                _ = try await environment.makeClient().deleteProject(path: .init(projectID: id)).noContent
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
                let organizations = try await environment.makeClient().listOrganizations().ok.body.json
                try printResult(organizations, format: global.output) {
                    var table = TextTable(headers: ["id", "name", "role", "created"])
                    for organization in organizations {
                        table.addRow([
                            organization.id ?? "", organization.name,
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
                let organization = try await environment.makeClient()
                    .getOrganization(path: .init(organizationID: id)).ok.body.json
                try printResult(organization, format: global.output) {
                    var table = TextTable(headers: ["field", "value"])
                    table.addRow(["id", organization.id ?? ""])
                    table.addRow(["name", organization.name])
                    table.addRow(["description", organization.description])
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
                let quotas = try await environment.makeClient()
                    .listResourceQuotas(query: .init(limit: listPageLimit)).ok.body.json.items
                try printResult(quotas, format: global.output) {
                    var table = TextTable(
                        headers: ["id", "name", "scope", "environment", "enabled", "vcpus", "memory gb", "vms"])
                    for quota in quotas {
                        table.addRow([
                            quota.id ?? "", quota.name,
                            quota.entityType.rawValue, quota.environment ?? "",
                            quota.isEnabled ? "yes" : "no",
                            String(quota.limits.maxVCPUs),
                            String(format: "%g", quota.limits.maxMemoryGB),
                            String(quota.limits.maxVMs),
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
                let quota = try await environment.makeClient()
                    .getResourceQuota(path: .init(quotaID: id)).ok.body.json
                try printResult(quota, format: global.output) {
                    var table = TextTable(headers: ["field", "value"])
                    table.addRow(["id", quota.id ?? ""])
                    table.addRow(["name", quota.name])
                    table.addRow(["scope", quota.entityType.rawValue])
                    table.addRow(["environment", quota.environment ?? ""])
                    table.addRow(["enabled", quota.isEnabled ? "yes" : "no"])
                    table.addRow(["max vcpus", String(quota.limits.maxVCPUs)])
                    table.addRow(["max memory gb", String(format: "%g", quota.limits.maxMemoryGB)])
                    table.addRow(["max storage gb", String(format: "%g", quota.limits.maxStorageGB)])
                    table.addRow(["max vms", String(quota.limits.maxVMs)])
                    table.addRow(["max sandboxes", String(quota.limits.maxSandboxes)])
                    return table
                }
            }
        }
    }
}
