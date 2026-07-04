import Fluent
import Vapor
import Foundation

// DeploymentEnvironment is not a database model but a value object
// Actual environments are stored as strings in Project.environments
// and as a field on VMs

struct DeploymentEnvironment: Content {
    let name: String
    let displayName: String
    let description: String
    let color: String // For UI display
    let icon: String // For UI display
    let isProduction: Bool
    let requiresApproval: Bool

    // Common environment presets
    static let development = DeploymentEnvironment(
        name: "development",
        displayName: "Development",
        description: "Development environment for active development",
        color: "green",
        icon: "code",
        isProduction: false,
        requiresApproval: false
    )

    static let staging = DeploymentEnvironment(
        name: "staging",
        displayName: "Staging",
        description: "Staging environment for pre-production testing",
        color: "yellow",
        icon: "flask",
        isProduction: false,
        requiresApproval: true
    )

    static let production = DeploymentEnvironment(
        name: "production",
        displayName: "Production",
        description: "Production environment for live workloads",
        color: "red",
        icon: "server",
        isProduction: true,
        requiresApproval: true
    )

    static let testing = DeploymentEnvironment(
        name: "testing",
        displayName: "Testing",
        description: "Testing environment for QA and automated tests",
        color: "blue",
        icon: "check-circle",
        isProduction: false,
        requiresApproval: false
    )

    static let demo = DeploymentEnvironment(
        name: "demo",
        displayName: "Demo",
        description: "Demo environment for customer demonstrations",
        color: "purple",
        icon: "presentation",
        isProduction: false,
        requiresApproval: false
    )

    // Get all default environments
    static let defaults: [DeploymentEnvironment] = [
        development,
        staging,
        production
    ]

    // Get all available preset environments
    static let allPresets: [DeploymentEnvironment] = [
        development,
        staging,
        production,
        testing,
        demo
    ]

    // Get environment by name
    static func byName(_ name: String) -> DeploymentEnvironment? {
        return allPresets.first { $0.name == name }
    }
}
