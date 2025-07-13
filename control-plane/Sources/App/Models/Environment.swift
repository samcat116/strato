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

// MARK: - Environment Configuration

struct EnvironmentConfig: Content {
    let environments: [DeploymentEnvironment]
    let defaultEnvironment: String
    let productionEnvironments: [String]
    let requiresApprovalEnvironments: [String]
    
    init(for project: Project) {
        // Map project environment strings to DeploymentEnvironment objects
        self.environments = project.environments.compactMap { envName in
            DeploymentEnvironment.byName(envName) ?? DeploymentEnvironment(
                name: envName,
                displayName: envName.capitalized,
                description: "Custom environment",
                color: "gray",
                icon: "cube",
                isProduction: false,
                requiresApproval: false
            )
        }
        
        self.defaultEnvironment = project.defaultEnvironment
        
        self.productionEnvironments = environments
            .filter { $0.isProduction }
            .map { $0.name }
        
        self.requiresApprovalEnvironments = environments
            .filter { $0.requiresApproval }
            .map { $0.name }
    }
}

// MARK: - Environment-specific Settings

struct EnvironmentSettings: Content {
    let environment: String
    let autoScalingEnabled: Bool
    let maxInstances: Int
    let minInstances: Int
    let backupEnabled: Bool
    let backupSchedule: String? // cron expression
    let monitoringEnabled: Bool
    let alertingEnabled: Bool
    let maintenanceWindow: MaintenanceWindow?
    
    struct MaintenanceWindow: Content {
        let dayOfWeek: Int // 0-6, 0 = Sunday
        let startHour: Int // 0-23
        let durationHours: Int
    }
}

// MARK: - Environment Promotion

struct EnvironmentPromotion: Content {
    let sourceEnvironment: String
    let targetEnvironment: String
    let vmId: UUID
    let promotedBy: UUID
    let promotedAt: Date
    let notes: String?
    let approvedBy: UUID?
    let approvalRequired: Bool
    
    init(
        from source: String,
        to target: String,
        vmId: UUID,
        promotedBy: UUID,
        notes: String? = nil,
        approvalRequired: Bool = false
    ) {
        self.sourceEnvironment = source
        self.targetEnvironment = target
        self.vmId = vmId
        self.promotedBy = promotedBy
        self.promotedAt = Date()
        self.notes = notes
        self.approvedBy = nil
        self.approvalRequired = approvalRequired
    }
}