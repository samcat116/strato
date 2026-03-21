import Foundation

/// Base protocol for all security events
public protocol SecurityEvent: Codable, Sendable {
    /// The type identifier for this event
    static var eventType: String { get }
}

/// CAEP (Continuous Access Evaluation Protocol) Events
public enum CAEPEvent: SecurityEvent, Sendable {
    case sessionRevoked(SessionRevokedEvent)
    case tokenClaimsChange(TokenClaimsChangeEvent)
    case credentialChange(CredentialChangeEvent)
    case assuranceLevelChange(AssuranceLevelChangeEvent)
    case deviceComplianceChange(DeviceComplianceChangeEvent)
    
    public static var eventType: String { "https://schemas.openid.net/secevent/caep/" }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        
        if container.contains(.init(stringValue: "session-revoked")!) {
            let event = try container.decode(SessionRevokedEvent.self, forKey: .init(stringValue: "session-revoked")!)
            self = .sessionRevoked(event)
        } else if container.contains(.init(stringValue: "token-claims-change")!) {
            let event = try container.decode(TokenClaimsChangeEvent.self, forKey: .init(stringValue: "token-claims-change")!)
            self = .tokenClaimsChange(event)
        } else if container.contains(.init(stringValue: "credential-change")!) {
            let event = try container.decode(CredentialChangeEvent.self, forKey: .init(stringValue: "credential-change")!)
            self = .credentialChange(event)
        } else if container.contains(.init(stringValue: "assurance-level-change")!) {
            let event = try container.decode(AssuranceLevelChangeEvent.self, forKey: .init(stringValue: "assurance-level-change")!)
            self = .assuranceLevelChange(event)
        } else if container.contains(.init(stringValue: "device-compliance-change")!) {
            let event = try container.decode(DeviceComplianceChangeEvent.self, forKey: .init(stringValue: "device-compliance-change")!)
            self = .deviceComplianceChange(event)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown CAEP event type"))
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        
        switch self {
        case .sessionRevoked(let event):
            try container.encode(event, forKey: .init(stringValue: "session-revoked")!)
        case .tokenClaimsChange(let event):
            try container.encode(event, forKey: .init(stringValue: "token-claims-change")!)
        case .credentialChange(let event):
            try container.encode(event, forKey: .init(stringValue: "credential-change")!)
        case .assuranceLevelChange(let event):
            try container.encode(event, forKey: .init(stringValue: "assurance-level-change")!)
        case .deviceComplianceChange(let event):
            try container.encode(event, forKey: .init(stringValue: "device-compliance-change")!)
        }
    }
}

/// RISC (Risk Incident Sharing and Coordination) Events
public enum RISCEvent: SecurityEvent, Sendable {
    case accountPurged(AccountPurgedEvent)
    case accountDisabled(AccountDisabledEvent)
    case accountEnabled(AccountEnabledEvent)
    case credentialCompromise(CredentialCompromiseEvent)
    case accountCredentialChangeRequired(AccountCredentialChangeRequiredEvent)
    
    public static var eventType: String { "https://schemas.openid.net/secevent/risc/" }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        
        if container.contains(.init(stringValue: "account-purged")!) {
            let event = try container.decode(AccountPurgedEvent.self, forKey: .init(stringValue: "account-purged")!)
            self = .accountPurged(event)
        } else if container.contains(.init(stringValue: "account-disabled")!) {
            let event = try container.decode(AccountDisabledEvent.self, forKey: .init(stringValue: "account-disabled")!)
            self = .accountDisabled(event)
        } else if container.contains(.init(stringValue: "account-enabled")!) {
            let event = try container.decode(AccountEnabledEvent.self, forKey: .init(stringValue: "account-enabled")!)
            self = .accountEnabled(event)
        } else if container.contains(.init(stringValue: "credential-compromise")!) {
            let event = try container.decode(CredentialCompromiseEvent.self, forKey: .init(stringValue: "credential-compromise")!)
            self = .credentialCompromise(event)
        } else if container.contains(.init(stringValue: "account-credential-change-required")!) {
            let event = try container.decode(AccountCredentialChangeRequiredEvent.self, forKey: .init(stringValue: "account-credential-change-required")!)
            self = .accountCredentialChangeRequired(event)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown RISC event type"))
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        
        switch self {
        case .accountPurged(let event):
            try container.encode(event, forKey: .init(stringValue: "account-purged")!)
        case .accountDisabled(let event):
            try container.encode(event, forKey: .init(stringValue: "account-disabled")!)
        case .accountEnabled(let event):
            try container.encode(event, forKey: .init(stringValue: "account-enabled")!)
        case .credentialCompromise(let event):
            try container.encode(event, forKey: .init(stringValue: "credential-compromise")!)
        case .accountCredentialChangeRequired(let event):
            try container.encode(event, forKey: .init(stringValue: "account-credential-change-required")!)
        }
    }
}

// MARK: - CAEP Event Types

public struct SessionRevokedEvent: Codable, Sendable {
    public let reason_admin: String?
    public let reason_user: String?
    public let reason_code: String?
    
    public init(reason_admin: String? = nil, reason_user: String? = nil, reason_code: String? = nil) {
        self.reason_admin = reason_admin
        self.reason_user = reason_user
        self.reason_code = reason_code
    }
}

public struct TokenClaimsChangeEvent: Codable, Sendable {
    public let claims: [String: AnyCodable]
    
    public init(claims: [String: AnyCodable]) {
        self.claims = claims
    }
}

public struct CredentialChangeEvent: Codable, Sendable {
    public let change_type: String
    public let friendly_name: String?
    
    public init(change_type: String, friendly_name: String? = nil) {
        self.change_type = change_type
        self.friendly_name = friendly_name
    }
}

public struct AssuranceLevelChangeEvent: Codable, Sendable {
    public let current_level: String
    public let previous_level: String?
    public let change_direction: String
    
    public init(current_level: String, previous_level: String? = nil, change_direction: String) {
        self.current_level = current_level
        self.previous_level = previous_level
        self.change_direction = change_direction
    }
}

public struct DeviceComplianceChangeEvent: Codable, Sendable {
    public let current_status: String
    public let previous_status: String?
    
    public init(current_status: String, previous_status: String? = nil) {
        self.current_status = current_status
        self.previous_status = previous_status
    }
}

// MARK: - RISC Event Types

public struct AccountPurgedEvent: Codable, Sendable {
    public let reason: String?
    
    public init(reason: String? = nil) {
        self.reason = reason
    }
}

public struct AccountDisabledEvent: Codable, Sendable {
    public let reason: String?
    
    public init(reason: String? = nil) {
        self.reason = reason
    }
}

public struct AccountEnabledEvent: Codable, Sendable {
    public let reason: String?
    
    public init(reason: String? = nil) {
        self.reason = reason
    }
}

public struct CredentialCompromiseEvent: Codable, Sendable {
    public let credential_type: String
    public let reason_admin: String?
    public let reason_user: String?
    public let event_timestamp: Int64?
    
    public init(credential_type: String, reason_admin: String? = nil, reason_user: String? = nil, event_timestamp: Int64? = nil) {
        self.credential_type = credential_type
        self.reason_admin = reason_admin
        self.reason_user = reason_user
        self.event_timestamp = event_timestamp
    }
}

public struct AccountCredentialChangeRequiredEvent: Codable, Sendable {
    public let reason_admin: String?
    public let reason_user: String?
    
    public init(reason_admin: String? = nil, reason_user: String? = nil) {
        self.reason_admin = reason_admin
        self.reason_user = reason_user
    }
}

// MARK: - Helper Types

private struct DynamicKey: CodingKey, Sendable {
    let stringValue: String
    let intValue: Int?
    
    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }
    
    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}