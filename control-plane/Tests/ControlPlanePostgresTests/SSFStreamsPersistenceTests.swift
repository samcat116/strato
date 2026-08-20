import Foundation
import Testing

@testable import ControlPlanePostgres

@Suite("Native SSF-stream persistence", .serialized)
struct SSFStreamsPersistenceTests {
    @Test("create, scope, update, and delete a stream")
    func lifecycle() async throws {
        try await withSSFStreamDatabase { _, streams in
            let organizationID = UUID()
            let creatorID = UUID()
            let created = try await streams.create(
                SSFStreamWrite(
                    organizationID: organizationID,
                    name: "Workforce IdP",
                    description: "Security events",
                    transmitterURL: "https://idp.example.com",
                    encryptedAuthToken: "encrypted-token",
                    expectedIssuer: "https://idp.example.com",
                    expectedAudience: ["strato"],
                    deliveryMethod: .push,
                    eventsRequested: ["session-revoked"],
                    createdByID: creatorID
                )
            )

            #expect(created.organizationID == organizationID)
            #expect(created.expectedAudience == ["strato"])
            #expect(created.eventsRequested == ["session-revoked"])
            #expect(created.deliveryMethodValue == .push)
            #expect(created.createdAt != nil)
            #expect(created.updatedAt == nil)
            #expect(try await streams.streams(organizationID: organizationID).map(\.id) == [created.id])
            #expect(try await streams.streams(organizationID: UUID()).isEmpty)
            #expect(try await streams.ownedStream(id: created.id, organizationID: UUID()) == nil)
            #expect(try await streams.streamsWithAuthTokens().map(\.id) == [created.id])
            #expect(
                !(try await streams.replaceEncryptedAuthToken(
                    id: created.id,
                    expectedCurrentValue: "stale-token",
                    replacement: "must-not-win"
                ))
            )
            #expect(
                try await streams.replaceEncryptedAuthToken(
                    id: created.id,
                    expectedCurrentValue: "encrypted-token",
                    replacement: "rotated-encrypted-token"
                )
            )
            #expect(
                try await streams.stream(id: created.id)?.encryptedAuthToken
                    == "rotated-encrypted-token"
            )

            let updated = try #require(
                try await streams.updateOwnedStream(
                    id: created.id,
                    organizationID: organizationID,
                    changes: SSFStreamChanges(
                        name: "Production IdP",
                        expectedAudience: [],
                        eventsRequested: ["account-disabled"],
                        enabled: false
                    )
                )
            )
            #expect(updated.name == "Production IdP")
            #expect(updated.description == "Security events")
            #expect(updated.expectedAudience.isEmpty)
            #expect(updated.eventsRequested == ["account-disabled"])
            #expect(!updated.enabled)
            #expect(updated.updatedAt != nil)

            #expect(
                !(try await streams.deleteOwnedStream(
                    id: created.id,
                    organizationID: UUID()
                ))
            )
            #expect(
                try await streams.deleteOwnedStream(
                    id: created.id,
                    organizationID: organizationID
                )
            )
            #expect(try await streams.stream(id: created.id) == nil)
        }
    }

    @Test("registration, delivery state, and poll selection remain explicit")
    func registrationAndDeliveryState() async throws {
        try await withSSFStreamDatabase { _, streams in
            let creatorID = UUID()
            let push = try await streams.create(
                SSFStreamWrite(
                    organizationID: UUID(),
                    name: "push",
                    transmitterURL: "https://push.example.com",
                    deliveryMethod: .push,
                    createdByID: creatorID
                )
            )
            let poll = try await streams.create(
                SSFStreamWrite(
                    organizationID: UUID(),
                    name: "poll",
                    transmitterURL: "https://poll.example.com",
                    deliveryMethod: .poll,
                    createdByID: creatorID
                )
            )

            let registeredPush = try #require(
                try await streams.completeRegistration(
                    id: push.id,
                    remoteStreamID: "remote-push",
                    pollEndpoint: nil,
                    pushTokenHash: "push-hash",
                    pushTokenPrefix: "ssf_prefix"
                )
            )
            #expect(registeredPush.isRegistered)
            #expect(registeredPush.pushTokenHash == "push-hash")

            _ = try #require(
                try await streams.completeRegistration(
                    id: poll.id,
                    remoteStreamID: "remote-poll",
                    pollEndpoint: "https://poll.example.com/events",
                    pushTokenHash: nil,
                    pushTokenPrefix: nil
                )
            )
            #expect(try await streams.registeredPollStreams().map(\.id) == [poll.id])

            let now = Date()
            #expect(try await streams.recordEvent(id: push.id, at: now))
            #expect(try await streams.markVerified(id: push.id, at: now))
            #expect(try await streams.recordError(id: poll.id, message: "temporary failure"))

            let touched = try #require(try await streams.stream(id: push.id))
            #expect(touched.lastEventAt != nil)
            #expect(touched.verifiedAt != nil)
            #expect(touched.lastError == nil)
            #expect(try await streams.stream(id: poll.id)?.lastError == "temporary failure")

            let cleared = try #require(try await streams.clearRegistration(id: push.id))
            #expect(!cleared.isRegistered)
            #expect(cleared.pushTokenHash == nil)
            #expect(cleared.pushTokenPrefix == nil)
            #expect(cleared.verifiedAt == nil)
        }
    }

    private func withSSFStreamDatabase(
        _ test: (PostgresDatabase, SSFStreamsPersistence) async throws -> Void
    ) async throws {
        try await withBareNativePostgresDatabase { database in
            try await database.withSession(operation: "test.ssf_streams.schema") { session in
                _ = try await session.command(
                    """
                    CREATE TABLE ssf_streams (
                        id UUID PRIMARY KEY,
                        organization_id UUID NOT NULL,
                        name TEXT NOT NULL,
                        description TEXT,
                        transmitter_url TEXT NOT NULL,
                        auth_token TEXT,
                        expected_issuer TEXT,
                        expected_audience TEXT NOT NULL DEFAULT '[]',
                        delivery_method TEXT NOT NULL,
                        events_requested TEXT NOT NULL DEFAULT '[]',
                        remote_stream_id TEXT,
                        poll_endpoint TEXT,
                        push_token_hash TEXT,
                        push_token_prefix TEXT,
                        enabled BOOLEAN NOT NULL DEFAULT TRUE,
                        verified_at TIMESTAMPTZ,
                        last_event_at TIMESTAMPTZ,
                        last_error TEXT,
                        created_by_id UUID NOT NULL,
                        created_at TIMESTAMPTZ,
                        updated_at TIMESTAMPTZ
                    )
                    """,
                    operation: "test.ssf_streams.schema.create"
                )
            }
            try await test(
                database,
                ControlPlanePersistence(database: database).ssfStreams
            )
        }
    }
}
