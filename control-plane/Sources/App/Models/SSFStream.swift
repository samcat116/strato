import Crypto
import Fluent
import Foundation
import Vapor

/// A Shared Signals Framework (SSF) receiver stream (issue #38): the
/// configuration an organization uses to consume CAEP/RISC security events
/// from one external transmitter (typically an IdP).
///
/// A row starts unregistered; `POST .../register` creates the stream at the
/// transmitter and records the assigned `remoteStreamID`. Push streams
/// authenticate inbound deliveries with a per-stream bearer token (stored
/// hashed, like SCIM tokens); poll streams record the transmitter's poll
/// endpoint and are drained by the periodic poll sweep.
final class SSFStream: Model, @unchecked Sendable {
    static let schema = "ssf_streams"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "organization_id")
    var organization: Organization

    @Field(key: "name")
    var name: String

    @OptionalField(key: "description")
    var description: String?

    /// Base URL of the transmitter; discovery happens against
    /// `<transmitterURL>/.well-known/ssf-configuration`.
    @Field(key: "transmitter_url")
    var transmitterURL: String

    /// Bearer token for the transmitter's stream-management API.
    /// Stored encrypted at rest by `SecretsEncryptionService` (like
    /// OIDCProvider.clientSecret); never serialized into API responses.
    @OptionalField(key: "auth_token")
    var authToken: String?

    /// Expected `iss` of received SETs; defaults to the transmitter URL.
    @OptionalField(key: "expected_issuer")
    var expectedIssuer: String?

    /// JSON array of acceptable `aud` values for received SETs.
    @Field(key: "expected_audience")
    var expectedAudience: String

    /// "push" (RFC 8935) or "poll" (RFC 8936).
    @Field(key: "delivery_method")
    var deliveryMethod: String

    /// JSON array of requested event type URIs; empty means transmitter default.
    @Field(key: "events_requested")
    var eventsRequested: String

    /// Stream id assigned by the transmitter at registration.
    @OptionalField(key: "remote_stream_id")
    var remoteStreamID: String?

    /// Poll delivery endpoint returned by the transmitter (poll streams only).
    @OptionalField(key: "poll_endpoint")
    var pollEndpoint: String?

    /// SHA256 of the inbound push bearer token (push streams only).
    @OptionalField(key: "push_token_hash")
    var pushTokenHash: String?

    @OptionalField(key: "push_token_prefix")
    var pushTokenPrefix: String?

    @Field(key: "enabled")
    var enabled: Bool

    /// Set when a verification event from the transmitter was processed.
    @OptionalField(key: "verified_at")
    var verifiedAt: Date?

    @OptionalField(key: "last_event_at")
    var lastEventAt: Date?

    @OptionalField(key: "last_error")
    var lastError: String?

    @Parent(key: "created_by_id")
    var createdBy: User

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        organizationID: UUID,
        name: String,
        description: String? = nil,
        transmitterURL: String,
        authToken: String? = nil,
        expectedIssuer: String? = nil,
        expectedAudience: [String] = [],
        deliveryMethod: SSFDeliveryMethod,
        eventsRequested: [String] = [],
        enabled: Bool = true,
        createdByID: UUID
    ) {
        self.id = id
        self.$organization.id = organizationID
        self.name = name
        self.description = description
        self.transmitterURL = transmitterURL
        self.authToken = authToken
        self.expectedIssuer = expectedIssuer
        self.expectedAudience = Self.encodeStringArray(expectedAudience)
        self.deliveryMethod = deliveryMethod.rawValue
        self.eventsRequested = Self.encodeStringArray(eventsRequested)
        self.enabled = enabled
        self.$createdBy.id = createdByID
    }
}

enum SSFDeliveryMethod: String, Codable, Sendable {
    case push
    case poll
}

// MARK: - JSON array helpers

extension SSFStream {
    var expectedAudienceArray: [String] {
        get { Self.decodeStringArray(expectedAudience) }
        set { expectedAudience = Self.encodeStringArray(newValue) }
    }

    var eventsRequestedArray: [String] {
        get { Self.decodeStringArray(eventsRequested) }
        set { eventsRequested = Self.encodeStringArray(newValue) }
    }

    var deliveryMethodValue: SSFDeliveryMethod? {
        SSFDeliveryMethod(rawValue: deliveryMethod)
    }

    private static func decodeStringArray(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
            let array = try? JSONDecoder().decode([String].self, from: data)
        else {
            return []
        }
        return array
    }

    private static func encodeStringArray(_ array: [String]) -> String {
        guard let data = try? JSONEncoder().encode(array),
            let string = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return string
    }
}

// MARK: - Push token helpers (same shape as SCIMToken)

extension SSFStream {
    /// Generate an inbound push-delivery bearer token: ssf_[48 alphanumerics].
    static func generatePushToken() -> String {
        let randomBytes = SymmetricKey(size: .bits256)
        let keyData = randomBytes.withUnsafeBytes { Data($0) }
        let keyString = keyData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "")
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "=", with: "")
            .prefix(48)
        return "ssf_\(keyString)"
    }

    static func hashPushToken(_ token: String) -> String {
        let hashed = SHA256.hash(data: Data(token.utf8))
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }

    static func extractPushTokenPrefix(_ token: String) -> String {
        String(token.prefix(12))
    }

    func matchesPushToken(_ token: String) -> Bool {
        guard let pushTokenHash else { return false }
        return pushTokenHash == Self.hashPushToken(token)
    }
}

// MARK: - DTOs

struct CreateSSFStreamRequest: Content {
    let name: String
    let description: String?
    let transmitterURL: String
    let authToken: String?
    let expectedIssuer: String?
    let expectedAudience: [String]?
    let deliveryMethod: SSFDeliveryMethod
    let eventsRequested: [String]?
}

struct UpdateSSFStreamRequest: Content {
    let name: String?
    let description: String?
    let authToken: String?
    let expectedIssuer: String?
    let expectedAudience: [String]?
    let eventsRequested: [String]?
    let enabled: Bool?
}

struct SSFStreamResponse: Content {
    let id: UUID?
    let organizationId: UUID
    let name: String
    let description: String?
    let transmitterURL: String
    let expectedIssuer: String?
    let expectedAudience: [String]
    let deliveryMethod: String
    let eventsRequested: [String]
    let remoteStreamID: String?
    let pollEndpoint: String?
    let pushEndpoint: String?
    let pushTokenPrefix: String?
    let enabled: Bool
    let registered: Bool
    let verifiedAt: Date?
    let lastEventAt: Date?
    let lastError: String?
    let createdAt: Date?
    let updatedAt: Date?

    init(from stream: SSFStream, pushEndpoint: String?) {
        self.id = stream.id
        self.organizationId = stream.$organization.id
        self.name = stream.name
        self.description = stream.description
        self.transmitterURL = stream.transmitterURL
        self.expectedIssuer = stream.expectedIssuer
        self.expectedAudience = stream.expectedAudienceArray
        self.deliveryMethod = stream.deliveryMethod
        self.eventsRequested = stream.eventsRequestedArray
        self.remoteStreamID = stream.remoteStreamID
        self.pollEndpoint = stream.pollEndpoint
        self.pushEndpoint = pushEndpoint
        self.pushTokenPrefix = stream.pushTokenPrefix
        self.enabled = stream.enabled
        self.registered = stream.remoteStreamID != nil
        self.verifiedAt = stream.verifiedAt
        self.lastEventAt = stream.lastEventAt
        self.lastError = stream.lastError
        self.createdAt = stream.createdAt
        self.updatedAt = stream.updatedAt
    }
}

struct SSFStreamStatusResponse: Content {
    let remoteStreamID: String
    let status: String
    let reason: String?
}

struct SSFPollResultResponse: Content {
    let processed: Int
    let failed: Int
    let moreAvailable: Bool
}
