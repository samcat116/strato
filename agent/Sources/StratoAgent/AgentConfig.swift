import Foundation
import Toml
import Logging

struct AgentConfig: Codable {
    let controlPlaneURL: String
    let qemuSocketDir: String?
    let logLevel: String?
    
    // Certificate-based authentication settings
    let certificatePath: String?
    let privateKeyPath: String?
    let caBundlePath: String?
    let joinToken: String?
    let enrollmentURL: String?
    let autoRenewal: Bool?
    let renewalThreshold: Double?
    
    enum CodingKeys: String, CodingKey {
        case controlPlaneURL = "control_plane_url"
        case qemuSocketDir = "qemu_socket_dir"
        case logLevel = "log_level"
        case certificatePath = "certificate_path"
        case privateKeyPath = "private_key_path"
        case caBundlePath = "ca_bundle_path"
        case joinToken = "join_token"
        case enrollmentURL = "enrollment_url"
        case autoRenewal = "auto_renewal"
        case renewalThreshold = "renewal_threshold"
    }
    
    init(
        controlPlaneURL: String,
        qemuSocketDir: String? = nil,
        logLevel: String? = nil,
        certificatePath: String? = nil,
        privateKeyPath: String? = nil,
        caBundlePath: String? = nil,
        joinToken: String? = nil,
        enrollmentURL: String? = nil,
        autoRenewal: Bool? = nil,
        renewalThreshold: Double? = nil
    ) {
        self.controlPlaneURL = controlPlaneURL
        self.qemuSocketDir = qemuSocketDir
        self.logLevel = logLevel
        self.certificatePath = certificatePath
        self.privateKeyPath = privateKeyPath
        self.caBundlePath = caBundlePath
        self.joinToken = joinToken
        self.enrollmentURL = enrollmentURL
        self.autoRenewal = autoRenewal
        self.renewalThreshold = renewalThreshold
    }
    
    static func load(from path: String) throws -> AgentConfig {
        let fileURL = URL(fileURLWithPath: path)
        
        guard FileManager.default.fileExists(atPath: path) else {
            throw AgentConfigError.configFileNotFound(path)
        }
        
        let tomlString = try String(contentsOf: fileURL, encoding: .utf8)
        let tomlData = try Toml(withString: tomlString)
        
        // Extract configuration values from TOML
        guard let controlPlaneURL = tomlData.string("control_plane_url") else {
            throw AgentConfigError.missingRequiredField("control_plane_url")
        }
        
        let qemuSocketDir = tomlData.string("qemu_socket_dir")
        let logLevel = tomlData.string("log_level")
        
        // Certificate authentication settings
        let certificatePath = tomlData.string("certificate_path")
        let privateKeyPath = tomlData.string("private_key_path")
        let caBundlePath = tomlData.string("ca_bundle_path")
        let joinToken = tomlData.string("join_token")
        let enrollmentURL = tomlData.string("enrollment_url")
        let autoRenewal = tomlData.bool("auto_renewal")
        let renewalThreshold = tomlData.double("renewal_threshold")
        
        return AgentConfig(
            controlPlaneURL: controlPlaneURL,
            qemuSocketDir: qemuSocketDir,
            logLevel: logLevel,
            certificatePath: certificatePath,
            privateKeyPath: privateKeyPath,
            caBundlePath: caBundlePath,
            joinToken: joinToken,
            enrollmentURL: enrollmentURL,
            autoRenewal: autoRenewal,
            renewalThreshold: renewalThreshold
        )
    }
    
    static let defaultConfigPath = "/etc/strato/config.toml"
    static let fallbackConfigPath = "./config.toml"
    
    static func loadDefaultConfig(logger: Logger? = nil) -> AgentConfig {
        // Try to load from default path first
        do {
            return try load(from: defaultConfigPath)
        } catch {
            logger?.warning("Failed to load config from \(defaultConfigPath): \(error)")
        }
        
        // Try fallback path for development
        do {
            return try load(from: fallbackConfigPath)
        } catch {
            logger?.warning("Failed to load config from \(fallbackConfigPath): \(error)")
        }
        
        // Return default configuration if no config file found
        logger?.info("Using default configuration")
        return AgentConfig(
            controlPlaneURL: "ws://localhost:8080/agent/ws",
            qemuSocketDir: "/var/run/qemu",
            logLevel: "info"
        )
    }
    
    // MARK: - Certificate Management Properties
    
    /// Check if certificate-based authentication is configured
    var hasCertificateAuth: Bool {
        return certificatePath != nil && privateKeyPath != nil && caBundlePath != nil
    }
    
    /// Check if enrollment configuration is available
    var canEnroll: Bool {
        return joinToken != nil && enrollmentURL != nil
    }
    
    /// Get the default certificate storage directory
    var certificateDirectory: String {
        return "/etc/strato/certs"
    }
    
    /// Get the default certificate file path
    var defaultCertificatePath: String {
        return "\(certificateDirectory)/agent.crt"
    }
    
    /// Get the default private key file path
    var defaultPrivateKeyPath: String {
        return "\(certificateDirectory)/agent.key"
    }
    
    /// Get the default CA bundle file path
    var defaultCABundlePath: String {
        return "\(certificateDirectory)/ca-bundle.crt"
    }
    
    /// Get renewal threshold (default 60% of certificate lifetime)
    var effectiveRenewalThreshold: Double {
        return renewalThreshold ?? 0.6
    }
    
    /// Check if auto-renewal is enabled (default true)
    var isAutoRenewalEnabled: Bool {
        return autoRenewal ?? true
    }
}

enum AgentConfigError: Error, LocalizedError {
    case configFileNotFound(String)
    case invalidTOMLFormat(String)
    case missingRequiredField(String)
    
    var errorDescription: String? {
        switch self {
        case .configFileNotFound(let path):
            return "Configuration file not found at path: \(path)"
        case .invalidTOMLFormat(let details):
            return "Invalid TOML format: \(details)"
        case .missingRequiredField(let field):
            return "Missing required configuration field: \(field)"
        }
    }
}