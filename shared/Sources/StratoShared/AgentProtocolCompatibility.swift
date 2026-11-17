import Foundation

/// Compatibility policy for the binary Protobuf workload protocol.
public enum AgentProtocolCompatibility {
    public static let major: UInt32 = 1
    public static let sessionHeader = "Strato-Agent-Session"

    /// Every feature existing at the hard cutover belongs to major 1. Future
    /// independently deployable behavior adds immutable capability identifiers.
    public static var localOffer: Strato_Agent_V1_ProtocolOffer {
        var offer = Strato_Agent_V1_ProtocolOffer()
        offer.major = major
        return offer
    }

    /// Errors intentionally contain no remote values: callers can log them
    /// without leaking arbitrary peer-controlled contents.
    public enum Failure: Error, Equatable, Sendable {
        case missingMajor
        case incompatibleMajor
        case invalidCapability
        case invalidSession
        case unsupportedCapability
        case unofferedCapability
    }

    public static func negotiate(
        local: Strato_Agent_V1_ProtocolOffer,
        remote: Strato_Agent_V1_ProtocolOffer,
        inventorySessionID: UUID
    ) throws -> Strato_Agent_V1_ProtocolAgreement {
        try validate(local)
        try validate(remote)
        guard local.major == remote.major else { throw Failure.incompatibleMajor }
        var result = Strato_Agent_V1_ProtocolAgreement()
        result.major = local.major
        result.capabilities = Array(Set(local.capabilities).intersection(remote.capabilities)).sorted()
        result.inventorySessionID = inventorySessionID.uuidString
        return result
    }

    public static func validate(
        _ agreement: Strato_Agent_V1_ProtocolAgreement,
        offered: Strato_Agent_V1_ProtocolOffer
    ) throws {
        try validate(offered)
        guard agreement.hasMajor else { throw Failure.missingMajor }
        guard agreement.major == offered.major else { throw Failure.incompatibleMajor }
        guard agreement.hasInventorySessionID, UUID(uuidString: agreement.inventorySessionID) != nil else {
            throw Failure.invalidSession
        }
        try validateCapabilities(agreement.capabilities)
        guard Set(agreement.capabilities).isSubset(of: Set(offered.capabilities)) else {
            throw Failure.unofferedCapability
        }
    }

    public static func require(
        _ requirements: Strato_Agent_V1_ProtocolRequirements,
        agreement: Strato_Agent_V1_ProtocolAgreement,
        offered: Strato_Agent_V1_ProtocolOffer
    ) throws {
        try validate(agreement, offered: offered)
        try validateCapabilities(requirements.capabilities)
        guard Set(requirements.capabilities).isSubset(of: Set(agreement.capabilities)) else {
            throw Failure.unsupportedCapability
        }
    }

    private static func validate(_ offer: Strato_Agent_V1_ProtocolOffer) throws {
        guard offer.hasMajor else { throw Failure.missingMajor }
        guard offer.major == major else { throw Failure.incompatibleMajor }
        try validateCapabilities(offer.capabilities)
    }

    /// Lowercase ASCII letters, digits, and `-` `.` `/` `_`.
    private static func isCapabilityByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
            UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "/"), UInt8(ascii: "_"):
            return true
        default:
            return false
        }
    }

    private static func validateCapabilities(_ capabilities: [String]) throws {
        // Bound negotiation work and accept stable ASCII identifiers only.
        guard capabilities.count <= 256 else { throw Failure.invalidCapability }
        for capability in capabilities {
            guard !capability.isEmpty, capability.utf8.count <= 128,
                capability.utf8.allSatisfy(isCapabilityByte)
            else { throw Failure.invalidCapability }
        }
    }
}
