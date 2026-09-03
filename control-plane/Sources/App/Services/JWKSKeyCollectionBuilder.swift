import Foundation
import JWT
import StratoShared
import Vapor

/// Builds a verifier collection from a mixed JWKS without letting one
/// unsupported or encryption-only key disable every valid signing key.
enum JWKSKeyCollectionBuilder {
    struct Policy: Sendable {
        let acceptedUses: Set<String>
        let normalizedUse: String?
        let requiresKeyID: Bool
        let synthesizesMissingKeyIDs: Bool
        let decodeFailureMessage: String
        let registrationFailureMessage: String
    }

    struct Result: Sendable {
        let keys: JWTKeyCollection
        let knownKeyIDs: Set<String>
    }

    private struct Envelope: Decodable {
        let keys: [JSONValue]
    }

    static func build(
        jwksJSON: Data,
        logger: Logger?,
        policy: Policy,
        malformed: @Sendable () -> any Error,
        empty: @Sendable () -> any Error
    ) async throws -> Result {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: jwksJSON) else {
            throw malformed()
        }

        let collection = JWTKeyCollection()
        let decoder = JSONDecoder()
        var registered = 0
        var knownKeyIDs: Set<String> = []

        for rawKey in envelope.keys {
            guard var object = rawKey.objectValue else { continue }
            if let use = object["use"]?.stringValue {
                guard policy.acceptedUses.contains(use) else { continue }
                if let normalizedUse = policy.normalizedUse {
                    object["use"] = .string(normalizedUse)
                }
            }

            guard let data = try? JSONEncoder().encode(JSONValue.object(object)),
                var jwk = try? decoder.decode(JWK.self, from: data)
            else {
                logger?.debug(
                    "\(policy.decodeFailureMessage)",
                    metadata: ["kty": .string(object["kty"]?.stringValue ?? "<missing>")])
                continue
            }

            if jwk.keyIdentifier == nil, policy.synthesizesMissingKeyIDs {
                jwk.keyIdentifier = JWKIdentifier(string: "strato-unnamed-key-\(registered)")
            }
            if policy.requiresKeyID, jwk.keyIdentifier == nil {
                logger?.debug(
                    "\(policy.decodeFailureMessage)",
                    metadata: ["kty": .string(object["kty"]?.stringValue ?? "<missing>")])
                continue
            }

            do {
                try await collection.add(jwk: jwk)
                registered += 1
                if let keyID = jwk.keyIdentifier?.string {
                    knownKeyIDs.insert(keyID)
                }
            } catch {
                logger?.debug(
                    "\(policy.registrationFailureMessage)",
                    metadata: ["kid": .string(jwk.keyIdentifier?.string ?? "<missing>")])
            }
        }

        guard registered > 0 else { throw empty() }
        return Result(keys: collection, knownKeyIDs: knownKeyIDs)
    }
}
