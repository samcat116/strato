import Testing
import Foundation
@testable import App

/// Regression tests for `ObjectReference` JSON coding.
///
/// `ObjectReference` is used both to build SpiceDB request bodies and to parse
/// SpiceDB responses. SpiceDB's grpc-gateway accepts snake_case on input but
/// emits camelCase on output, so a decoder that only understood `object_type`
/// failed on every ReadRelationships response. That went unnoticed until
/// `RoleBindingBackfill.backfillFromSpiceDB` began running at boot, where the
/// decode error was fatal and the control plane could not start against the
/// SpiceDB version the deployment pins.
@Suite("SpiceDB ObjectReference Coding")
struct SpiceDBObjectReferenceTests {

    /// The shape SpiceDB actually returns (verified against authzed/spicedb v1.35.3).
    @Test("Decodes the camelCase spelling SpiceDB emits in responses")
    func decodesCamelCase() throws {
        let json = #"{"objectType":"organization","objectId":"ORG-1"}"#
        let ref = try JSONDecoder().decode(ObjectReference.self, from: Data(json.utf8))

        #expect(ref.objectType == "organization")
        #expect(ref.objectId == "ORG-1")
    }

    /// The spelling we send, and what a server configured for proto field names
    /// would echo back.
    @Test("Decodes the snake_case spelling used in requests")
    func decodesSnakeCase() throws {
        let json = #"{"object_type":"organization","object_id":"ORG-1"}"#
        let ref = try JSONDecoder().decode(ObjectReference.self, from: Data(json.utf8))

        #expect(ref.objectType == "organization")
        #expect(ref.objectId == "ORG-1")
    }

    /// Encoding must stay snake_case: that is what the request bodies rely on.
    @Test("Encodes as snake_case")
    func encodesSnakeCase() throws {
        let ref = ObjectReference(objectType: "user", objectId: "USER-1")
        let data = try JSONEncoder().encode(ref)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["object_type"] as? String == "user")
        #expect(object["object_id"] as? String == "USER-1")
        #expect(object["objectType"] == nil)
    }

    /// A full streamed ReadRelationships line, exactly as SpiceDB returns it —
    /// the payload that previously crashed the boot-time backfill.
    @Test("Decodes a real ReadRelationships response line")
    func decodesReadRelationshipsLine() throws {
        let json = """
            {"result":{"readAt":{"token":"GgYKBENKTkU="},"relationship":{\
            "resource":{"objectType":"organization","objectId":"ORG-1"},\
            "relation":"admin",\
            "subject":{"object":{"objectType":"user","objectId":"USER-1"},"optionalRelation":""},\
            "optionalCaveat":null}}}
            """
        let line = try JSONDecoder().decode(
            ReadRelationshipsResponseLine.self, from: Data(json.utf8))

        let relationship = try #require(line.result?.relationship)
        #expect(relationship.resource.objectType == "organization")
        #expect(relationship.resource.objectId == "ORG-1")
        #expect(relationship.relation == "admin")
        #expect(relationship.subject.object.objectType == "user")
        #expect(relationship.subject.object.objectId == "USER-1")
        #expect(line.error == nil)
    }
}
