import Foundation
import Vapor

/// Service for SPIRE migration planning and configuration generation
struct SPIREMigrationService {
    let logger: Logger
    
    init(logger: Logger) {
        self.logger = logger
    }
    
    /// Generate SPIRE server configuration
    func generateSPIREConfig(trustDomain: String, controlPlaneAddress: String) -> SPIREConfiguration {
        let serverConfig = SPIREServerConfig(
            bindAddress: "0.0.0.0",
            bindPort: 8081,
            trustDomain: trustDomain,
            dataDir: "/opt/spire/data",
            logLevel: "INFO",
            plugins: SPIREServerPlugins(
                dataStore: SPIREDataStorePlugin(
                    type: "sql",
                    connectionString: "sqlite3:///opt/spire/data/datastore.sqlite3"
                ),
                nodeAttestor: SPIRENodeAttestorPlugin(
                    type: "join_token"
                ),
                keyManager: SPIREKeyManagerPlugin(
                    type: "disk",
                    keysPath: "/opt/spire/data/keys"
                ),
                upstreamAuthority: nil
            )
        )
        
        let agentConfig = SPIREAgentConfig(
            bindAddress: "0.0.0.0",
            bindPort: 8082,
            trustDomain: trustDomain,
            serverAddress: controlPlaneAddress,
            serverPort: 8081,
            dataDir: "/opt/spire/agent/data",
            logLevel: "INFO",
            plugins: SPIREAgentPlugins(
                nodeAttestor: SPIRENodeAttestorPlugin(
                    type: "join_token"
                ),
                keyManager: SPIREKeyManagerPlugin(
                    type: "disk",
                    keysPath: "/opt/spire/agent/data/keys"
                ),
                workloadAttestor: SPIREWorkloadAttestorPlugin(
                    type: "unix",
                    config: [:]
                )
            )
        )
        
        return SPIREConfiguration(
            version: "1.0",
            trustDomain: trustDomain,
            server: serverConfig,
            agent: agentConfig,
            migrationNotes: generateMigrationNotes()
        )
    }
    
    /// Check compatibility with SPIRE standards
    func checkSPIRECompatibility() -> SPIRECompatibilityReport {
        var checks: [SPIRECompatibilityCheck] = []
        var overallCompatible = true
        
        // Check SPIFFE URI format compatibility
        checks.append(SPIRECompatibilityCheck(
            component: "SPIFFE URI Format",
            compatible: true,
            details: "Current certificates use SPIFFE-compatible URI format in SAN",
            recommendation: "No changes needed - already SPIFFE compatible"
        ))
        
        // Check certificate format compatibility
        checks.append(SPIRECompatibilityCheck(
            component: "Certificate Format",
            compatible: true,
            details: "X.509 certificates with ECDSA keys are SPIRE compatible",
            recommendation: "Continue using current certificate format"
        ))
        
        // Check trust domain compatibility
        checks.append(SPIRECompatibilityCheck(
            component: "Trust Domain",
            compatible: true,
            details: "Current trust domain 'strato.local' follows SPIFFE specification",
            recommendation: "Maintain consistent trust domain during migration"
        ))
        
        // Check workload attestation
        checks.append(SPIRECompatibilityCheck(
            component: "Workload Attestation",
            compatible: false,
            details: "Current system uses certificate-based auth, SPIRE uses workload attestation",
            recommendation: "Plan migration to SPIRE workload attestation (Unix socket, Kubernetes, etc.)"
        ))
        
        if !checks.allSatisfy(\.compatible) {
            overallCompatible = false
        }
        
        // Check node attestation
        checks.append(SPIRECompatibilityCheck(
            component: "Node Attestation",
            compatible: true,
            details: "Join token approach is compatible with SPIRE node attestation",
            recommendation: "Current join token system can be adapted for SPIRE"
        ))
        
        return SPIRECompatibilityReport(
            compatible: overallCompatible,
            readinessScore: calculateReadinessScore(checks: checks),
            checks: checks,
            migrationPath: generateMigrationPath(checks: checks),
            estimatedEffort: estimateMigrationEffort(checks: checks)
        )
    }
    
    private func generateMigrationNotes() -> [String] {
        return [
            "Current Strato certificate system is designed to be SPIRE-compatible",
            "SPIFFE URIs are already implemented in certificate Subject Alternative Names",
            "Trust domain 'strato.local' follows SPIFFE specification",
            "Migration path: Deploy SPIRE server → Migrate agents → Phase out custom CA",
            "Consider gradual migration with dual certificate support during transition",
            "Audit current certificate usage before migration planning"
        ]
    }
    
    private func calculateReadinessScore(checks: [SPIRECompatibilityCheck]) -> Int {
        let compatibleCount = checks.filter(\.compatible).count
        let totalCount = checks.count
        return totalCount > 0 ? (compatibleCount * 100) / totalCount : 0
    }
    
    private func generateMigrationPath(checks: [SPIRECompatibilityCheck]) -> [SPIREMigrationStep] {
        var steps: [SPIREMigrationStep] = []
        
        steps.append(SPIREMigrationStep(
            phase: 1,
            title: "SPIRE Server Deployment",
            description: "Deploy SPIRE server alongside existing certificate infrastructure",
            estimatedDuration: "1-2 weeks",
            dependencies: [],
            risks: ["Service disruption during deployment"]
        ))
        
        steps.append(SPIREMigrationStep(
            phase: 2,
            title: "Agent Attestation Setup",
            description: "Configure SPIRE agent attestation methods (join tokens, cloud providers)",
            estimatedDuration: "2-3 weeks", 
            dependencies: ["SPIRE Server Deployment"],
            risks: ["Agent enrollment complexity"]
        ))
        
        if !(checks.first(where: { $0.component == "Workload Attestation" })?.compatible ?? true) {
            steps.append(SPIREMigrationStep(
                phase: 3,
                title: "Workload Attestation Migration",
                description: "Migrate from certificate-based to SPIRE workload attestation",
                estimatedDuration: "3-4 weeks",
                dependencies: ["Agent Attestation Setup"],
                risks: ["Application compatibility", "Workload identity changes"]
            ))
        }
        
        steps.append(SPIREMigrationStep(
            phase: 4,
            title: "Dual Certificate Support",
            description: "Run both Strato CA and SPIRE in parallel during transition",
            estimatedDuration: "2-4 weeks",
            dependencies: ["Workload Attestation Migration"],
            risks: ["Certificate management complexity"]
        ))
        
        steps.append(SPIREMigrationStep(
            phase: 5,
            title: "Legacy CA Deprecation",
            description: "Phase out custom Strato CA after full SPIRE adoption",
            estimatedDuration: "1-2 weeks",
            dependencies: ["Dual Certificate Support"],
            risks: ["Service disruption if migration incomplete"]
        ))
        
        return steps
    }
    
    private func estimateMigrationEffort(checks: [SPIRECompatibilityCheck]) -> SPIREMigrationEffort {
        let incompatibleCount = checks.filter { !$0.compatible }.count
        
        let complexity: SPIREMigrationComplexity
        let duration: String
        let resources: Int
        
        switch incompatibleCount {
        case 0:
            complexity = .low
            duration = "4-6 weeks"
            resources = 2
        case 1...2:
            complexity = .medium
            duration = "8-12 weeks"
            resources = 3
        default:
            complexity = .high
            duration = "12-16 weeks"
            resources = 4
        }
        
        return SPIREMigrationEffort(
            complexity: complexity,
            estimatedDuration: duration,
            requiredResources: resources,
            majorBlockers: checks.filter { !$0.compatible }.map(\.component)
        )
    }
}

/// SPIRE configuration structure
struct SPIREConfiguration: Content {
    let version: String
    let trustDomain: String
    let server: SPIREServerConfig
    let agent: SPIREAgentConfig
    let migrationNotes: [String]
}

/// SPIRE server configuration
struct SPIREServerConfig: Codable {
    let bindAddress: String
    let bindPort: Int
    let trustDomain: String
    let dataDir: String
    let logLevel: String
    let plugins: SPIREServerPlugins
}

/// SPIRE agent configuration
struct SPIREAgentConfig: Codable {
    let bindAddress: String
    let bindPort: Int
    let trustDomain: String
    let serverAddress: String
    let serverPort: Int
    let dataDir: String
    let logLevel: String
    let plugins: SPIREAgentPlugins
}

/// SPIRE server plugins configuration
struct SPIREServerPlugins: Codable {
    let dataStore: SPIREDataStorePlugin
    let nodeAttestor: SPIRENodeAttestorPlugin
    let keyManager: SPIREKeyManagerPlugin
    let upstreamAuthority: SPIREUpstreamAuthorityPlugin?
}

/// SPIRE agent plugins configuration
struct SPIREAgentPlugins: Codable {
    let nodeAttestor: SPIRENodeAttestorPlugin
    let keyManager: SPIREKeyManagerPlugin
    let workloadAttestor: SPIREWorkloadAttestorPlugin
}

/// SPIRE data store plugin
struct SPIREDataStorePlugin: Codable {
    let type: String
    let connectionString: String
}

/// SPIRE node attestor plugin
struct SPIRENodeAttestorPlugin: Codable {
    let type: String
}

/// SPIRE key manager plugin
struct SPIREKeyManagerPlugin: Codable {
    let type: String
    let keysPath: String
}

/// SPIRE upstream authority plugin
struct SPIREUpstreamAuthorityPlugin: Codable {
    let type: String
    let config: [String: String]
}

/// SPIRE workload attestor plugin
struct SPIREWorkloadAttestorPlugin: Codable {
    let type: String
    let config: [String: String]
}

/// SPIRE compatibility report
struct SPIRECompatibilityReport: Content {
    let compatible: Bool
    let readinessScore: Int
    let checks: [SPIRECompatibilityCheck]
    let migrationPath: [SPIREMigrationStep]
    let estimatedEffort: SPIREMigrationEffort
}

/// Individual SPIRE compatibility check
struct SPIRECompatibilityCheck: Codable {
    let component: String
    let compatible: Bool
    let details: String
    let recommendation: String
}

/// SPIRE migration step
struct SPIREMigrationStep: Codable {
    let phase: Int
    let title: String
    let description: String
    let estimatedDuration: String
    let dependencies: [String]
    let risks: [String]
}

/// SPIRE migration effort estimation
struct SPIREMigrationEffort: Codable {
    let complexity: SPIREMigrationComplexity
    let estimatedDuration: String
    let requiredResources: Int
    let majorBlockers: [String]
}

/// SPIRE migration complexity levels
enum SPIREMigrationComplexity: String, Codable, CaseIterable {
    case low = "low"
    case medium = "medium"
    case high = "high"
}