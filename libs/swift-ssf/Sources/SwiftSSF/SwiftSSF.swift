/// SwiftSSF - A cross-platform Swift framework for OpenID Shared Signals Framework (SSF) receivers
/// 
/// This framework enables Swift applications to act as receivers in the SSF ecosystem,
/// supporting both CAEP and RISC event types with push and poll delivery methods.

// MARK: - Framework Information

/// SwiftSSF framework version
public let swiftSSFVersion = "1.0.0"

/// Supported SSF specification version
public let supportedSSFVersion = "1.0"

/// Supported event types
public let supportedEventTypes = [
    "https://schemas.openid.net/secevent/caep/session-revoked",
    "https://schemas.openid.net/secevent/caep/token-claims-change", 
    "https://schemas.openid.net/secevent/caep/credential-change",
    "https://schemas.openid.net/secevent/caep/assurance-level-change",
    "https://schemas.openid.net/secevent/caep/device-compliance-change",
    "https://schemas.openid.net/secevent/risc/account-purged",
    "https://schemas.openid.net/secevent/risc/account-disabled",
    "https://schemas.openid.net/secevent/risc/account-enabled",
    "https://schemas.openid.net/secevent/risc/credential-compromise",
    "https://schemas.openid.net/secevent/risc/account-credential-change-required"
]

/// Supported delivery methods
public let supportedDeliveryMethods = [
    "urn:ietf:rfc:8935", // Push delivery
    "urn:ietf:rfc:8936"  // Poll delivery
]
