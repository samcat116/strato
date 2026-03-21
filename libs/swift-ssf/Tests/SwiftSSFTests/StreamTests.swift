import XCTest
@testable import SwiftSSF
import Foundation

final class StreamTests: XCTestCase {
    
    func testEventStreamCreation() throws {
        let issuer = URL(string: "https://transmitter.example.com")!
        let delivery = DeliveryConfiguration(
            method: .poll,
            endpoint_url: URL(string: "https://transmitter.example.com/poll")!
        )
        
        let stream = EventStream(
            id: "stream-123",
            iss: issuer,
            aud: ["receiver-1"],
            events_requested: ["https://schemas.openid.net/secevent/caep/session-revoked"],
            delivery: delivery,
            status: .enabled,
            description: "Test stream"
        )
        
        XCTAssertEqual(stream.id, "stream-123")
        XCTAssertEqual(stream.iss, issuer)
        XCTAssertEqual(stream.aud, ["receiver-1"])
        XCTAssertEqual(stream.status, .enabled)
        XCTAssertEqual(stream.description, "Test stream")
    }
    
    func testDeliveryMethodSerialization() throws {
        let pushMethod = DeliveryMethod.push
        let pollMethod = DeliveryMethod.poll
        
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        // Test push method
        let pushData = try encoder.encode(pushMethod)
        let decodedPush = try decoder.decode(DeliveryMethod.self, from: pushData)
        XCTAssertEqual(decodedPush, .push)
        XCTAssertEqual(decodedPush.rawValue, "urn:ietf:rfc:8935")
        
        // Test poll method
        let pollData = try encoder.encode(pollMethod)
        let decodedPoll = try decoder.decode(DeliveryMethod.self, from: pollData)
        XCTAssertEqual(decodedPoll, .poll)
        XCTAssertEqual(decodedPoll.rawValue, "urn:ietf:rfc:8936")
    }
    
    func testStreamStatusSerialization() throws {
        let statuses: [StreamStatus] = [.enabled, .paused, .disabled, .configuring]
        
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        for status in statuses {
            let data = try encoder.encode(status)
            let decoded = try decoder.decode(StreamStatus.self, from: data)
            XCTAssertEqual(decoded, status)
        }
    }
    
    func testCreateStreamRequest() throws {
        let delivery = DeliveryConfiguration(
            method: .push,
            endpoint_url: URL(string: "https://receiver.example.com/webhook")!,
            authorization_header: "Bearer token123"
        )
        
        let request = CreateStreamRequest(
            aud: ["receiver-1", "receiver-2"],
            events_requested: [
                "https://schemas.openid.net/secevent/caep/session-revoked",
                "https://schemas.openid.net/secevent/risc/account-disabled"
            ],
            delivery: delivery,
            description: "Multi-receiver stream"
        )
        
        XCTAssertEqual(request.aud, ["receiver-1", "receiver-2"])
        XCTAssertEqual(request.events_requested.count, 2)
        XCTAssertEqual(request.delivery.method, .push)
        XCTAssertEqual(request.description, "Multi-receiver stream")
    }
    
    func testUpdateStreamRequest() throws {
        let newDelivery = DeliveryConfiguration(
            method: .poll,
            endpoint_url: URL(string: "https://transmitter.example.com/new-poll")!
        )
        
        let request = UpdateStreamRequest(
            events_requested: ["https://schemas.openid.net/secevent/caep/credential-change"],
            delivery: newDelivery,
            status: .paused,
            description: "Updated description"
        )
        
        XCTAssertEqual(request.events_requested, ["https://schemas.openid.net/secevent/caep/credential-change"])
        XCTAssertEqual(request.delivery?.method, .poll)
        XCTAssertEqual(request.status, .paused)
        XCTAssertEqual(request.description, "Updated description")
    }
    
    func testStreamSubjectManagement() throws {
        let subject = SubjectIdentifier.simple("user@example.com")
        let streamSubject = StreamSubject(
            subject: subject,
            active: true,
            added_at: Date()
        )
        
        XCTAssertTrue(streamSubject.active)
        XCTAssertNotNil(streamSubject.added_at)
        
        let addRequest = AddSubjectRequest(subject: subject)
        let removeRequest = RemoveSubjectRequest(subject: subject)
        
        // Test serialization
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        let addData = try encoder.encode(addRequest)
        let decodedAdd = try decoder.decode(AddSubjectRequest.self, from: addData)
        
        switch decodedAdd.subject {
        case .simple(let value):
            XCTAssertEqual(value, "user@example.com")
        case .complex:
            XCTFail("Expected simple subject")
        }
        
        let removeData = try encoder.encode(removeRequest)
        let decodedRemove = try decoder.decode(RemoveSubjectRequest.self, from: removeData)
        
        switch decodedRemove.subject {
        case .simple(let value):
            XCTAssertEqual(value, "user@example.com")
        case .complex:
            XCTFail("Expected simple subject")
        }
    }
    
    func testVerificationRequests() throws {
        let request = VerificationRequest(state: "test-state-123")
        let response = VerificationResponse(
            status: .verified,
            details: "Verification successful"
        )
        
        XCTAssertEqual(request.state, "test-state-123")
        XCTAssertEqual(response.status, .verified)
        XCTAssertEqual(response.details, "Verification successful")
        
        // Test all verification statuses
        let statuses: [VerificationStatus] = [.verified, .failed, .pending]
        
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        for status in statuses {
            let data = try encoder.encode(status)
            let decoded = try decoder.decode(VerificationStatus.self, from: data)
            XCTAssertEqual(decoded, status)
        }
    }
    
    func testDeliveryConfigurationWithConfig() throws {
        let additionalConfig: [String: AnyCodable] = [
            "timeout": AnyCodable(30),
            "retries": AnyCodable(3),
            "compress": AnyCodable(true)
        ]
        
        let delivery = DeliveryConfiguration(
            method: .push,
            endpoint_url: URL(string: "https://receiver.example.com/events")!,
            authorization_header: "Bearer secret",
            config: additionalConfig
        )
        
        XCTAssertEqual(delivery.method, .push)
        XCTAssertNotNil(delivery.config)
        XCTAssertEqual(delivery.config?["timeout"]?.value as? Int, 30)
        XCTAssertEqual(delivery.config?["retries"]?.value as? Int, 3)
        XCTAssertEqual(delivery.config?["compress"]?.value as? Bool, true)
    }
}