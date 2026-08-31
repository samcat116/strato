import Crypto
import Fluent
import Foundation
import NIOConcurrencyHelpers
import SQLKit
import StratoShared
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

// MARK: - Shared fixtures

private struct WebhookFixture {
    let user: User
    let organization: Organization
    let project: Project
    let apiToken: String
}

/// A user (org admin by default) + org + project, authenticated via API key.
private func makeFixture(
    _ app: Application, role: String = "admin"
) async throws -> WebhookFixture {
    let builder = TestDataBuilder(db: app.db)
    let user = try await builder.createUser(username: "hookuser", email: "hooks@example.com")
    let org = try await builder.createOrganization(name: "Webhook Org")
    try await builder.addUserToOrganization(user: user, organization: org, role: role)
    let project = try await builder.createProject(
        name: "Hook Project", description: "", organization: org)
    let apiToken = try await user.generateAPIKey(on: app.db)
    return WebhookFixture(user: user, organization: org, project: project, apiToken: apiToken)
}

/// Insert a subscription row directly (bypassing the API) so outbox/sweep
/// tests do not depend on the CRUD surface.
private func makeSubscription(
    _ app: Application,
    fixture: WebhookFixture,
    url: String = "http://127.0.0.1:1/hook",
    eventTypes: [WebhookEventType] = [],
    projectID: UUID? = nil,
    secret: String = "whsec_test_secret"
) async throws -> WebhookSubscription {
    let subscription = WebhookSubscription(
        organizationID: fixture.organization.id!,
        projectID: projectID,
        name: "test hook",
        url: url,
        eventTypes: eventTypes,
        signingSecret: try app.secretsEncryption.encrypt(secret),
        createdByID: fixture.user.id!
    )
    try await subscription.save(on: app.db)
    return subscription
}

// MARK: - Subscription CRUD API

@Suite("Webhook Subscription API Tests", .serialized)
struct WebhookSubscriptionAPITests {

    @Test("Create returns the signing secret exactly once and echoes the config")
    func createReturnsSecret() async throws {
        try await withTestApp { app in
            let fixture = try await makeFixture(app)

            try await app.test(
                .POST, "/api/organizations/\(fixture.organization.id!.uuidString)/webhooks"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.apiToken)
                try req.content.encode(
                    CreateWebhookSubscriptionRequest(
                        name: "CI notifier",
                        url: "https://hooks.example.com/strato",
                        projectId: nil,
                        eventTypes: ["operation.completed", "operation.failed"]
                    ))
            } afterResponse: { res in
                #expect(res.status == .created)
                let body = try res.content.decode(WebhookSubscriptionWithSecretResponse.self)
                #expect(body.signingSecret.hasPrefix("whsec_"))
                #expect(body.subscription.name == "CI notifier")
                #expect(
                    body.subscription.eventTypes.sorted()
                        == ["operation.completed", "operation.failed"])
                #expect(body.subscription.isActive)
            }

            // The list surface never exposes the secret.
            try await app.test(
                .GET, "/api/organizations/\(fixture.organization.id!.uuidString)/webhooks"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.apiToken)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let listed = try res.content.decode([WebhookSubscriptionResponse].self)
                #expect(listed.count == 1)
                #expect(!res.body.string.contains("whsec_"))
            }
        }
    }

    @Test("Create validates URL, event types, and project scope")
    func createValidation() async throws {
        try await withTestApp { app in
            let fixture = try await makeFixture(app)
            let base = "/api/organizations/\(fixture.organization.id!.uuidString)/webhooks"

            // Malformed / non-http URLs.
            for badURL in ["not a url", "ftp://example.com/hook", "https://"] {
                try await app.test(.POST, base) { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.apiToken)
                    try req.content.encode(
                        CreateWebhookSubscriptionRequest(
                            name: "bad", url: badURL, projectId: nil, eventTypes: nil))
                } afterResponse: { res in
                    #expect(res.status == .badRequest, "expected 400 for \(badURL)")
                }
            }

            // Unknown event type.
            try await app.test(.POST, base) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.apiToken)
                try req.content.encode(
                    CreateWebhookSubscriptionRequest(
                        name: "bad", url: "https://hooks.example.com",
                        projectId: nil, eventTypes: ["vm.exploded"]))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            // The test event type is not subscribable.
            try await app.test(.POST, base) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.apiToken)
                try req.content.encode(
                    CreateWebhookSubscriptionRequest(
                        name: "bad", url: "https://hooks.example.com",
                        projectId: nil, eventTypes: ["webhook.test"]))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            // A project from another organization.
            let builder = TestDataBuilder(db: app.db)
            let otherOrg = try await builder.createOrganization(name: "Other Org")
            let foreignProject = try await builder.createProject(
                name: "Foreign", description: "", organization: otherOrg)
            try await app.test(.POST, base) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.apiToken)
                try req.content.encode(
                    CreateWebhookSubscriptionRequest(
                        name: "bad", url: "https://hooks.example.com",
                        projectId: foreignProject.id, eventTypes: nil))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("Mutations require organization admin; members can read")
    func mutationsRequireAdmin() async throws {
        try await withTestApp { app in
            let fixture = try await makeFixture(app, role: "member")
            let base = "/api/organizations/\(fixture.organization.id!.uuidString)/webhooks"

            try await app.test(.POST, base) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.apiToken)
                try req.content.encode(
                    CreateWebhookSubscriptionRequest(
                        name: "nope", url: "https://hooks.example.com",
                        projectId: nil, eventTypes: nil))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }

            try await app.test(.GET, base) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.apiToken)
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            // Delivery history is admin-only: payloads carry operational
            // detail from any project in the organization.
            let subscription = try await makeSubscription(app, fixture: fixture)
            try await app.test(
                .GET, "\(base)/\(subscription.id!.uuidString)/deliveries"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.apiToken)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test("Re-activating a subscription clears the failure bookkeeping")
    func reactivationClearsFailureState() async throws {
        try await withTestApp { app in
            let fixture = try await makeFixture(app)
            let subscription = try await makeSubscription(app, fixture: fixture)
            subscription.isActive = false
            subscription.disabledReason = "Automatically disabled after 3 day(s) of failed deliveries"
            subscription.failingSince = Date().addingTimeInterval(-86_400 * 4)
            try await subscription.save(on: app.db)

            let path =
                "/api/organizations/\(fixture.organization.id!.uuidString)"
                + "/webhooks/\(subscription.id!.uuidString)"
            try await app.test(.PUT, path) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.apiToken)
                try req.content.encode(
                    UpdateWebhookSubscriptionRequest(
                        name: nil, url: nil, eventTypes: nil, isActive: true))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let body = try res.content.decode(WebhookSubscriptionResponse.self)
                #expect(body.isActive)
                #expect(body.disabledReason == nil)
                #expect(body.failingSince == nil)
            }
        }
    }

    @Test("Rotate-secret mints a fresh secret")
    func rotateSecret() async throws {
        try await withTestApp { app in
            let fixture = try await makeFixture(app)
            let subscription = try await makeSubscription(app, fixture: fixture, secret: "whsec_old")

            let path =
                "/api/organizations/\(fixture.organization.id!.uuidString)"
                + "/webhooks/\(subscription.id!.uuidString)/rotate-secret"
            try await app.test(.POST, path) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.apiToken)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let body = try res.content.decode(WebhookSubscriptionWithSecretResponse.self)
                #expect(body.signingSecret.hasPrefix("whsec_"))
                #expect(body.signingSecret != "whsec_old")
            }
        }
    }

    @Test("Delete removes the subscription and cascades its deliveries")
    func deleteCascades() async throws {
        try await withTestApp { app in
            let fixture = try await makeFixture(app)
            let subscription = try await makeSubscription(app, fixture: fixture)
            let delivery = WebhookDelivery(
                subscriptionID: subscription.id!,
                eventID: UUID(),
                eventType: .webhookTest,
                payload: "{}")
            try await delivery.save(on: app.db)

            let path =
                "/api/organizations/\(fixture.organization.id!.uuidString)"
                + "/webhooks/\(subscription.id!.uuidString)"
            try await app.test(.DELETE, path) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.apiToken)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            let remainingSubscriptions = try await WebhookSubscription.query(on: app.db).count()
            #expect(remainingSubscriptions == 0)
            let remainingDeliveries = try await WebhookDelivery.query(on: app.db).count()
            #expect(remainingDeliveries == 0)
        }
    }

    @Test("Test-event endpoint enqueues a webhook.test delivery")
    func testEventEnqueues() async throws {
        try await withTestApp { app in
            let fixture = try await makeFixture(app)
            let subscription = try await makeSubscription(
                app, fixture: fixture, eventTypes: [.operationCompleted])

            let path =
                "/api/organizations/\(fixture.organization.id!.uuidString)"
                + "/webhooks/\(subscription.id!.uuidString)/test"
            try await app.test(.POST, path) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.apiToken)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let body = try res.content.decode(WebhookDeliveryResponse.self)
                // Enqueued despite the subscription not selecting webhook.test.
                #expect(body.eventType == "webhook.test")
                #expect(body.status == "pending")
            }
        }
    }

    @Test("Redeliver rejects pending deliveries and resets terminal ones")
    func redeliver() async throws {
        try await withTestApp { app in
            let fixture = try await makeFixture(app)
            let subscription = try await makeSubscription(app, fixture: fixture)
            let delivery = WebhookDelivery(
                subscriptionID: subscription.id!,
                eventID: UUID(),
                eventType: .webhookTest,
                payload: "{}")
            try await delivery.save(on: app.db)

            let path =
                "/api/organizations/\(fixture.organization.id!.uuidString)"
                + "/webhooks/\(subscription.id!.uuidString)"
                + "/deliveries/\(delivery.id!.uuidString)/redeliver"

            // Still pending: nothing to redeliver.
            try await app.test(.POST, path) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.apiToken)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            delivery.status = WebhookDeliveryStatus.dead.rawValue
            delivery.attempts = 8
            delivery.lastError = "gave up"
            try await delivery.save(on: app.db)

            try await app.test(.POST, path) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.apiToken)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let body = try res.content.decode(WebhookDeliveryResponse.self)
                #expect(body.status == "pending")
                #expect(body.attempts == 0)
                #expect(body.lastError == nil)
            }
        }
    }

    @Test("Delivery history surfaces the most recently changed rows")
    func deliveryHistory() async throws {
        try await withTestApp { app in
            let fixture = try await makeFixture(app)
            let subscription = try await makeSubscription(app, fixture: fixture)
            var oldest: WebhookDelivery?
            for index in 0..<3 {
                let delivery = WebhookDelivery(
                    subscriptionID: subscription.id!,
                    eventID: UUID(),
                    eventType: .webhookTest,
                    payload: "{\"n\":\(index)}")
                try await delivery.save(on: app.db)
                if oldest == nil { oldest = delivery }
            }
            let dropped = try #require(oldest)
            dropped.status = WebhookDeliveryStatus.dropped.rawValue
            dropped.lastError = WebhookOutbox.droppedReason(limit: 2)
            try await dropped.save(on: app.db)

            let path =
                "/api/organizations/\(fixture.organization.id!.uuidString)"
                + "/webhooks/\(subscription.id!.uuidString)/deliveries?limit=2"
            try await app.test(.GET, path) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.apiToken)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let deliveries = try res.content.decode([WebhookDeliveryResponse].self)
                #expect(deliveries.count == 2)
                #expect(deliveries[0].payload == "{\"n\":0}")
                #expect(deliveries[0].status == "dropped")
            }
        }
    }
}

// MARK: - Outbox enqueue

@Suite("Webhook Outbox Tests", .serialized)
struct WebhookOutboxTests {

    @Test("The pending ceiling drops each subscription's oldest rows independently")
    func pendingCeilingDropsOldestPerSubscription() async throws {
        try await withTestApp { app in
            let fixture = try await makeFixture(app)
            let first = try await makeSubscription(app, fixture: fixture)
            let second = try await makeSubscription(app, fixture: fixture)

            for subscription in [first, second] {
                for index in 0..<3 {
                    let delivery = WebhookDelivery(
                        subscriptionID: subscription.id!, eventID: UUID(),
                        eventType: .webhookTest, payload: "{\"index\":\(index)}")
                    _ = try await app.db.transaction { tx in
                        try await WebhookOutbox.enqueue([delivery], pendingLimit: 2, on: tx)
                    }
                }

                let rows = try await WebhookDelivery.query(on: app.db)
                    .filter(\.$subscription.$id == subscription.id!)
                    .sort(\.$createdAt)
                    .all()
                #expect(rows.map(\.statusValue) == [.dropped, .pending, .pending])
                #expect(rows[0].lastError == WebhookOutbox.droppedReason(limit: 2))
                #expect(rows[0].attempts == 0)
            }
        }
    }

    @Test("Concurrent admission cannot exceed a subscription's pending ceiling")
    func concurrentAdmissionHonorsPendingCeiling() async throws {
        try await withTestApp { app in
            let fixture = try await makeFixture(app)
            let subscription = try await makeSubscription(app, fixture: fixture)

            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<4 {
                    group.addTask {
                        let delivery = WebhookDelivery(
                            subscriptionID: subscription.id!, eventID: UUID(),
                            eventType: .webhookTest, payload: "{\"index\":\(index)}")
                        _ = try await app.db.transaction { tx in
                            try await WebhookOutbox.enqueue([delivery], pendingLimit: 2, on: tx)
                        }
                    }
                }
                try await group.waitForAll()
            }

            let rows = try await WebhookDelivery.query(on: app.db).all()
            #expect(rows.filter { $0.statusValue == .pending }.count == 2)
            #expect(rows.filter { $0.statusValue == .dropped }.count == 2)
        }
    }

    @Test("A manually re-enqueued delivery displaces older pending work at the ceiling")
    func protectedRedeliveryRemainsPendingAtCeiling() async throws {
        try await withTestApp { app in
            let fixture = try await makeFixture(app)
            let subscription = try await makeSubscription(app, fixture: fixture)
            let redelivered = WebhookDelivery(
                subscriptionID: subscription.id!, eventID: UUID(),
                eventType: .webhookTest, payload: "{\"redelivered\":true}")
            redelivered.status = WebhookDeliveryStatus.dropped.rawValue
            redelivered.lastError = WebhookOutbox.droppedReason(limit: 2)
            try await redelivered.save(on: app.db)

            for index in 0..<2 {
                let pending = WebhookDelivery(
                    subscriptionID: subscription.id!, eventID: UUID(),
                    eventType: .webhookTest, payload: "{\"pending\":\(index)}")
                try await pending.save(on: app.db)
            }

            try await app.db.transaction { tx in
                try await WebhookOutbox.lockSubscriptions([subscription.id!], on: tx)
                redelivered.status = WebhookDeliveryStatus.pending.rawValue
                redelivered.lastError = nil
                redelivered.nextAttemptAt = Date()
                try await redelivered.save(on: tx)
                try await WebhookOutbox.enforcePendingCeiling(
                    for: [subscription.id!], pendingLimit: 2,
                    protecting: redelivered.id!, on: tx)
            }

            let rows = try await WebhookDelivery.query(on: app.db).all()
            #expect(rows.filter { $0.statusValue == .pending }.count == 2)
            #expect(rows.filter { $0.statusValue == .dropped }.count == 1)
            let reloaded = try #require(
                try await WebhookDelivery.find(redelivered.id, on: app.db))
            #expect(reloaded.statusValue == .pending)
        }
    }

    @Test("The ceiling never sheds a claim held by a legacy replica")
    func pendingCeilingProtectsLegacyClaim() async throws {
        try await withTestApp { app in
            let fixture = try await makeFixture(app)
            let subscription = try await makeSubscription(app, fixture: fixture)
            let legacyClaim = WebhookDelivery(
                subscriptionID: subscription.id!, eventID: UUID(),
                eventType: .webhookTest, payload: "{\"legacyClaim\":true}")
            legacyClaim.nextAttemptAt = Date().addingTimeInterval(120)
            legacyClaim.claimedUntil = nil
            try await legacyClaim.save(on: app.db)

            let due = WebhookDelivery(
                subscriptionID: subscription.id!, eventID: UUID(),
                eventType: .webhookTest, payload: "{\"due\":true}")
            try await due.save(on: app.db)

            try await app.db.transaction { tx in
                try await WebhookOutbox.lockSubscriptions([subscription.id!], on: tx)
                try await WebhookOutbox.enforcePendingCeiling(
                    for: [subscription.id!], pendingLimit: 1, on: tx)
            }

            let protected = try #require(
                try await WebhookDelivery.find(legacyClaim.id, on: app.db))
            let shed = try #require(try await WebhookDelivery.find(due.id, on: app.db))
            #expect(protected.statusValue == .pending)
            #expect(shed.statusValue == .dropped)
        }
    }

    @Test("The ceiling protects a legacy claim that retains an expired lease marker")
    func pendingCeilingProtectsMixedVersionClaim() async throws {
        try await withTestApp { app in
            let fixture = try await makeFixture(app)
            let subscription = try await makeSubscription(app, fixture: fixture)
            let retry = WebhookDelivery(
                subscriptionID: subscription.id!, eventID: UUID(),
                eventType: .webhookTest, payload: "{\"retry\":true}")
            retry.nextAttemptAt = Date().addingTimeInterval(3_600)
            retry.claimedUntil = Date(timeIntervalSince1970: 0)
            try await retry.save(on: app.db)

            let due = WebhookDelivery(
                subscriptionID: subscription.id!, eventID: UUID(),
                eventType: .webhookTest, payload: "{\"due\":true}")
            try await due.save(on: app.db)

            try await app.db.transaction { tx in
                try await WebhookOutbox.lockSubscriptions([subscription.id!], on: tx)
                try await WebhookOutbox.enforcePendingCeiling(
                    for: [subscription.id!], pendingLimit: 1, on: tx)
            }

            let protected = try #require(try await WebhookDelivery.find(retry.id, on: app.db))
            let shed = try #require(try await WebhookDelivery.find(due.id, on: app.db))
            #expect(protected.statusValue == .pending)
            #expect(shed.statusValue == .dropped)
        }
    }

    @Test("The ceiling can shed an old future retry after the claim grace period")
    func pendingCeilingShedsFutureRetryAfterGrace() async throws {
        try await withTestApp { app in
            let fixture = try await makeFixture(app)
            let subscription = try await makeSubscription(app, fixture: fixture)
            let retry = WebhookDelivery(
                subscriptionID: subscription.id!, eventID: UUID(),
                eventType: .webhookTest, payload: "{\"retry\":true}")
            retry.nextAttemptAt = Date().addingTimeInterval(3_600)
            try await retry.save(on: app.db)

            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw(
                """
                UPDATE webhook_deliveries
                SET created_at = now() - interval '1 hour',
                    updated_at = now()
                        - (\(bind: WebhookDeliveryService.claimLeaseSeconds + 1) * interval '1 second')
                WHERE id = \(bind: retry.id!)
                """
            ).run()

            let due = WebhookDelivery(
                subscriptionID: subscription.id!, eventID: UUID(),
                eventType: .webhookTest, payload: "{\"due\":true}")
            try await due.save(on: app.db)

            try await app.db.transaction { tx in
                try await WebhookOutbox.lockSubscriptions([subscription.id!], on: tx)
                try await WebhookOutbox.enforcePendingCeiling(
                    for: [subscription.id!], pendingLimit: 1, on: tx)
            }

            let shed = try #require(try await WebhookDelivery.find(retry.id, on: app.db))
            let retained = try #require(try await WebhookDelivery.find(due.id, on: app.db))
            #expect(shed.statusValue == .dropped)
            #expect(retained.statusValue == .pending)
        }
    }

    @Test("Converging emits operation.completed once, naming the recorded mutation")
    func convergenceTransitionEnqueuesCompletion() async throws {
        try await withTestApp { app in
            let fixture = try await makeFixture(app)
            _ = try await makeSubscription(app, fixture: fixture)
            let builder = TestDataBuilder(db: app.db)
            let vm = try await builder.createVM(name: "converging-vm", project: fixture.project)

            // A lifecycle mutation as `ResourceMutation.accept` leaves it: the
            // desired-state change, the deadline, and the attribution event.
            vm.setFixtureDesiredStatus(.running)
            vm.extendConvergenceDeadline(by: 180)
            try await vm.save(on: app.db)
            _ = try await ResourceEvent.record(
                .boot, resourceKind: .virtualMachine, resourceID: vm.requireID(),
                actor: .user(fixture.user.requireID()), on: app.db)

            vm.observedGeneration = vm.generation
            vm.setStatus(.running)
            _ = try await ResourceConvergence.recordSuccess(vm, on: app.db)

            let deliveries = try await WebhookDelivery.query(on: app.db).all()
            #expect(deliveries.count == 1)
            let delivery = try #require(deliveries.first)
            #expect(delivery.eventType == "operation.completed")
            #expect(delivery.payload.contains("\"operationKind\":\"boot\""))
            #expect(delivery.payload.contains(vm.id!.uuidString))

            // The transition is what fires, not the state: the deadline is
            // cleared, so a repeat is a no-op rather than a second delivery.
            _ = try await ResourceConvergence.recordSuccess(vm, on: app.db)
            #expect(try await WebhookDelivery.query(on: app.db).count() == 1)
        }
    }

    @Test("A convergence failure emits operation.failed with the agent's reason")
    func convergenceFailureEnqueuesFailure() async throws {
        try await withTestApp { app in
            let fixture = try await makeFixture(app)
            _ = try await makeSubscription(app, fixture: fixture)
            let builder = TestDataBuilder(db: app.db)
            let vm = try await builder.createVM(name: "failing-vm", project: fixture.project)

            vm.setFixtureDesiredStatus(.running)
            try await vm.save(on: app.db)
            _ = try await ResourceEvent.record(
                .boot, resourceKind: .virtualMachine, resourceID: vm.requireID(),
                actor: .user(fixture.user.requireID()), on: app.db)

            let recorded = try await ResourceConvergence.recordFailure(
                vm, mutation: .boot, reason: "no bootable device",
                telemetryReason: "convergence_failed", on: app.db)
            #expect(recorded == .recorded)

            let delivery = try #require(try await WebhookDelivery.query(on: app.db).first())
            #expect(delivery.eventType == "operation.failed")
            #expect(delivery.payload.contains("no bootable device"))
            #expect(delivery.payload.contains("\"operationKind\":\"boot\""))
        }
    }

    @Test("The finalizer reap emits completion for a delete after the row is gone")
    func reapEnqueuesDeletionCompletion() async throws {
        try await withTestApp { app in
            let fixture = try await makeFixture(app)
            _ = try await makeSubscription(app, fixture: fixture)
            let builder = TestDataBuilder(db: app.db)
            let vm = try await builder.createVM(name: "reaped-vm", project: fixture.project)
            let vmID = try vm.requireID()

            try await ResourceFinalizerService.stampForDeletion(vm, on: app.db)
            vm.setFixtureDesiredStatus(.absent)
            try await vm.save(on: app.db)
            // The request event is where the reap reads its delivery context —
            // by the time it runs there is no resource left to resolve one.
            _ = try await ResourceEvent.record(
                .delete, resourceKind: .virtualMachine, resourceID: vmID,
                actor: .user(fixture.user.requireID()), on: app.db)

            _ = try await ResourceFinalizerService.clear(.agentAbsent, from: vm, on: app.db, app: app)
            #expect(try await VM.find(vmID, on: app.db) == nil)

            let delivery = try #require(try await WebhookDelivery.query(on: app.db).first())
            #expect(delivery.eventType == "operation.completed")
            #expect(delivery.payload.contains("\"operationKind\":\"delete\""))
            #expect(delivery.payload.contains("reaped-vm"))
            #expect(delivery.payload.contains(fixture.organization.id!.uuidString))
        }
    }

    @Test("Event-type selection and project scope filter the fan-out")
    func fanOutFilters() async throws {
        try await withTestApp { app in
            let fixture = try await makeFixture(app)
            let builder = TestDataBuilder(db: app.db)
            let otherProject = try await builder.createProject(
                name: "Other Project", description: "", organization: fixture.organization)

            // Wrong event type, wrong project, disabled — none should match.
            _ = try await makeSubscription(
                app, fixture: fixture, eventTypes: [.agentConnected])
            _ = try await makeSubscription(
                app, fixture: fixture, projectID: otherProject.id)
            let disabled = try await makeSubscription(app, fixture: fixture)
            disabled.isActive = false
            try await disabled.save(on: app.db)

            // Right type and right project scope — both should match.
            let byType = try await makeSubscription(
                app, fixture: fixture, eventTypes: [.operationCompleted])
            let byProject = try await makeSubscription(
                app, fixture: fixture, projectID: fixture.project.id)

            let vm = try await builder.createVM(name: "hook-vm", project: fixture.project)
            vm.setFixtureDesiredStatus(.running)
            vm.extendConvergenceDeadline(by: 180)
            try await vm.save(on: app.db)
            _ = try await ResourceEvent.record(
                .boot, resourceKind: .virtualMachine, resourceID: vm.requireID(),
                actor: .user(fixture.user.requireID()), on: app.db)
            vm.observedGeneration = vm.generation
            vm.setStatus(.running)
            _ = try await ResourceConvergence.recordSuccess(vm, on: app.db)

            let deliveries = try await WebhookDelivery.query(on: app.db).all()
            let recipients = Set(deliveries.map { $0.$subscription.id })
            #expect(recipients == Set([byType.id!, byProject.id!]))

            // The fan-out shares one event id so consumers can dedupe.
            let eventIDs = Set(deliveries.map(\.eventID))
            #expect(eventIDs.count == 1)
        }
    }

    @Test("VM state change events carry the transition")
    func vmStateChanged() async throws {
        try await withTestApp { app in
            let fixture = try await makeFixture(app)
            _ = try await makeSubscription(app, fixture: fixture, eventTypes: [.vmStateChanged])
            let builder = TestDataBuilder(db: app.db)
            let vm = try await builder.createVM(name: "hook-vm", project: fixture.project)

            await WebhookEvents.emitVMStateChanged(
                vm: vm, previous: .running, current: .shutdown, on: app.db, logger: app.logger)

            let delivery = try #require(try await WebhookDelivery.query(on: app.db).first())
            #expect(delivery.eventType == "vm.state_changed")
            #expect(delivery.payload.contains("\"previousStatus\":\"Running\""))
            #expect(delivery.payload.contains("\"newStatus\":\"Shutdown\""))
        }
    }

    @Test("Quota threshold crossings emit only the highest threshold crossed")
    func quotaThresholds() async throws {
        try await withTestApp { app in
            let fixture = try await makeFixture(app)
            _ = try await makeSubscription(
                app, fixture: fixture, eventTypes: [.quotaThresholdExceeded])
            let builder = TestDataBuilder(db: app.db)
            let quota = try await builder.createResourceQuota(
                name: "hook-quota", maxVCPUs: 10, organization: fixture.organization)

            // 70% -> 90% crosses 80 only.
            quota.reservedVCPUs = 7
            let baseline = QuotaUsageSnapshot(of: quota)
            quota.reservedVCPUs = 9
            try await WebhookEvents.enqueueQuotaThresholds(
                quota: quota, baseline: baseline, project: fixture.project, on: app.db)

            var deliveries = try await WebhookDelivery.query(on: app.db).all()
            #expect(deliveries.count == 1)
            #expect(deliveries[0].payload.contains("\"threshold\":80"))
            #expect(deliveries[0].payload.contains("\"pool\":\"vcpus\""))

            // 70% -> 100% crosses both; only the 100 event fires.
            try await WebhookDelivery.query(on: app.db).delete()
            quota.reservedVCPUs = 10
            try await WebhookEvents.enqueueQuotaThresholds(
                quota: quota, baseline: baseline, project: fixture.project, on: app.db)
            deliveries = try await WebhookDelivery.query(on: app.db).all()
            #expect(deliveries.count == 1)
            #expect(deliveries[0].payload.contains("\"threshold\":100"))

            // Already past the threshold at baseline: no re-fire.
            try await WebhookDelivery.query(on: app.db).delete()
            quota.reservedVCPUs = 9
            let highBaseline = QuotaUsageSnapshot(of: quota)
            quota.reservedVCPUs = 10  // 90% -> 100% crosses 100 but not 80
            try await WebhookEvents.enqueueQuotaThresholds(
                quota: quota, baseline: highBaseline, project: fixture.project, on: app.db)
            deliveries = try await WebhookDelivery.query(on: app.db).all()
            #expect(deliveries.count == 1)
            #expect(deliveries[0].payload.contains("\"threshold\":100"))
        }
    }
}

// MARK: - Delivery sweep

/// A bare Vapor app standing in for the subscriber's endpoint, capturing
/// every request and answering with a configurable status.
private struct HookOrigin {
    struct CapturedRequest: Sendable {
        let body: String
        let signature: String?
        let eventID: String?
        let eventType: String?
        let contentType: String?
    }

    struct PlannedResponse: Sendable {
        let status: HTTPResponseStatus
        let delay: Duration?

        init(_ status: HTTPResponseStatus, delay: Duration? = nil) {
            self.status = status
            self.delay = delay
        }
    }

    let app: Application
    let port: Int
    let captured: NIOLockedValueBox<[CapturedRequest]>
    let responseStatus: NIOLockedValueBox<HTTPResponseStatus>
    let inFlight: NIOLockedValueBox<Int>
    let maxInFlight: NIOLockedValueBox<Int>

    static func start(
        responseForRequest: (@Sendable (CapturedRequest) -> PlannedResponse)? = nil
    ) async throws -> HookOrigin {
        var env = Environment.testing
        env.arguments = ["vapor"]
        let origin = try await Application.make(env)
        origin.logger.logLevel = .error

        let captured = NIOLockedValueBox<[CapturedRequest]>([])
        let responseStatus = NIOLockedValueBox<HTTPResponseStatus>(.ok)
        let inFlight = NIOLockedValueBox<Int>(0)
        let maxInFlight = NIOLockedValueBox<Int>(0)

        origin.post("hook") { req -> Response in
            let active = inFlight.withLockedValue { count in
                count += 1
                return count
            }
            maxInFlight.withLockedValue { $0 = max($0, active) }
            defer { inFlight.withLockedValue { $0 -= 1 } }
            let request = CapturedRequest(
                body: req.body.string ?? "",
                signature: req.headers.first(name: "X-Strato-Signature"),
                eventID: req.headers.first(name: "X-Strato-Event-Id"),
                eventType: req.headers.first(name: "X-Strato-Event-Type"),
                contentType: req.headers.first(name: "Content-Type")
            )
            captured.withLockedValue { $0.append(request) }
            if let planned = responseForRequest?(request) {
                if let delay = planned.delay { try? await Task.sleep(for: delay) }
                return Response(status: planned.status)
            }
            return Response(status: responseStatus.withLockedValue { $0 })
        }

        try await origin.server.start(address: .hostname("127.0.0.1", port: 0))
        guard let port = origin.http.server.shared.localAddress?.port else {
            await origin.server.shutdown()
            try await origin.asyncShutdown()
            throw Abort(.internalServerError, reason: "origin did not report a bound port")
        }
        return HookOrigin(
            app: origin, port: port, captured: captured, responseStatus: responseStatus,
            inFlight: inFlight, maxInFlight: maxInFlight)
    }

    func shutdown() async {
        await app.server.shutdown()
        try? await app.asyncShutdown()
    }
}

@Suite("Webhook Delivery Sweep Tests", .serialized)
struct WebhookDeliverySweepTests {

    @Test("The sweep POSTs a correctly signed payload and records success")
    func deliversSignedPayload() async throws {
        let origin = try await HookOrigin.start()
        do {
            try await withTestApp { app in
                let fixture = try await makeFixture(app)
                let secret = "whsec_signing_test"
                let subscription = try await makeSubscription(
                    app, fixture: fixture,
                    url: "http://127.0.0.1:\(origin.port)/hook",
                    secret: secret)

                let event = WebhookEvent(
                    type: .webhookTest, organizationID: fixture.organization.id!,
                    data: ["message": .string("hello")])
                let delivery = WebhookDelivery(
                    subscriptionID: subscription.id!,
                    eventID: event.id,
                    eventType: event.type,
                    payload: try event.encodedPayload())
                try await delivery.save(on: app.db)

                await app.webhookDelivery.sweepOnce()

                let reloaded = try #require(try await WebhookDelivery.find(delivery.id, on: app.db))
                #expect(reloaded.statusValue == .succeeded)
                #expect(reloaded.responseStatus == 200)
                #expect(reloaded.attempts == 1)
                #expect(reloaded.deliveredAt != nil)

                let request = try #require(origin.captured.withLockedValue { $0.first })
                #expect(request.eventID == event.id.uuidString)
                #expect(request.eventType == "webhook.test")
                #expect(request.contentType == "application/json")
                #expect(request.body.contains("\"message\":\"hello\""))

                // Verify the signature the way a consumer would: parse
                // t/v1 and recompute the HMAC over "<t>.<body>".
                let signature = try #require(request.signature)
                let parts = signature.split(separator: ",")
                #expect(parts.count == 2)
                let timestampPart = try #require(
                    parts.first(where: { $0.hasPrefix("t=") })?.dropFirst(2))
                let signaturePart = try #require(
                    parts.first(where: { $0.hasPrefix("v1=") })?.dropFirst(3))
                let timestamp = try #require(Int(timestampPart))
                let expected = WebhookDeliveryService.signature(
                    payload: request.body, timestamp: timestamp, secret: secret)
                #expect(String(signaturePart) == expected)
            }
        } catch {
            await origin.shutdown()
            throw error
        }
        await origin.shutdown()
    }

    @Test("Failures back off, then succeed on a later pass")
    func retriesWithBackoff() async throws {
        let origin = try await HookOrigin.start()
        do {
            try await withTestApp { app in
                let fixture = try await makeFixture(app)
                let subscription = try await makeSubscription(
                    app, fixture: fixture, url: "http://127.0.0.1:\(origin.port)/hook")
                let delivery = WebhookDelivery(
                    subscriptionID: subscription.id!,
                    eventID: UUID(),
                    eventType: .webhookTest,
                    payload: "{}")
                try await delivery.save(on: app.db)

                origin.responseStatus.withLockedValue { $0 = .internalServerError }
                await app.webhookDelivery.sweepOnce()

                var reloaded = try #require(try await WebhookDelivery.find(delivery.id, on: app.db))
                #expect(reloaded.statusValue == .pending)
                #expect(reloaded.attempts == 1)
                #expect(reloaded.responseStatus == 500)
                #expect(reloaded.lastError?.contains("500") == true)
                #expect(reloaded.nextAttemptAt > Date())
                #expect(reloaded.claimedUntil == nil)

                let failingSubscription = try #require(
                    try await WebhookSubscription.find(subscription.id, on: app.db))
                #expect(failingSubscription.failingSince != nil)

                // Not due yet: an immediate pass must not retry.
                await app.webhookDelivery.sweepOnce()
                reloaded = try #require(try await WebhookDelivery.find(delivery.id, on: app.db))
                #expect(reloaded.attempts == 1)

                // Force it due and let the endpoint recover.
                origin.responseStatus.withLockedValue { $0 = .ok }
                reloaded.nextAttemptAt = Date()
                try await reloaded.save(on: app.db)
                await app.webhookDelivery.sweepOnce()

                reloaded = try #require(try await WebhookDelivery.find(delivery.id, on: app.db))
                #expect(reloaded.statusValue == .succeeded)
                #expect(reloaded.attempts == 2)

                // A success clears the failure streak.
                let recovered = try #require(
                    try await WebhookSubscription.find(subscription.id, on: app.db))
                #expect(recovered.failingSince == nil)
            }
        } catch {
            await origin.shutdown()
            throw error
        }
        await origin.shutdown()
    }

    @Test("A delivery out of attempts goes dead")
    func exhaustedDeliveriesGoDead() async throws {
        let origin = try await HookOrigin.start()
        do {
            try await withTestApp { app in
                let fixture = try await makeFixture(app)
                let subscription = try await makeSubscription(
                    app, fixture: fixture, url: "http://127.0.0.1:\(origin.port)/hook")
                let delivery = WebhookDelivery(
                    subscriptionID: subscription.id!,
                    eventID: UUID(),
                    eventType: .webhookTest,
                    payload: "{}")
                delivery.attempts = WebhookDeliveryService.maxAttempts - 1
                try await delivery.save(on: app.db)

                origin.responseStatus.withLockedValue { $0 = .badGateway }
                await app.webhookDelivery.sweepOnce()

                let reloaded = try #require(try await WebhookDelivery.find(delivery.id, on: app.db))
                #expect(reloaded.statusValue == .dead)
                #expect(reloaded.attempts == WebhookDeliveryService.maxAttempts)
            }
        } catch {
            await origin.shutdown()
            throw error
        }
        await origin.shutdown()
    }

    @Test("Continuous failure auto-disables the subscription")
    func autoDisable() async throws {
        let origin = try await HookOrigin.start()
        do {
            try await withTestApp { app in
                let fixture = try await makeFixture(app)
                let subscription = try await makeSubscription(
                    app, fixture: fixture, url: "http://127.0.0.1:\(origin.port)/hook")
                subscription.failingSince = Date().addingTimeInterval(
                    -Double(app.webhookDelivery.autoDisableDays + 1) * 86_400)
                try await subscription.save(on: app.db)

                let delivery = WebhookDelivery(
                    subscriptionID: subscription.id!,
                    eventID: UUID(),
                    eventType: .webhookTest,
                    payload: "{}")
                try await delivery.save(on: app.db)

                origin.responseStatus.withLockedValue { $0 = .internalServerError }
                await app.webhookDelivery.sweepOnce()

                let disabled = try #require(
                    try await WebhookSubscription.find(subscription.id, on: app.db))
                #expect(!disabled.isActive)
                #expect(disabled.disabledReason?.contains("Automatically disabled") == true)
            }
        } catch {
            await origin.shutdown()
            throw error
        }
        await origin.shutdown()
    }

    @Test("A concurrent success prevents a stale sibling failure from disabling the subscription")
    func concurrentSuccessAndFailure() async throws {
        let origin = try await HookOrigin.start { request in
            if request.body.contains("succeeds") {
                return HookOrigin.PlannedResponse(.ok)
            }
            // Keep the failure in flight until the success has recorded its
            // verdict. Before per-subscription serialization, this delivery
            // retained the old failure-streak model and disabled the freshly
            // recovered subscription when it resumed.
            return HookOrigin.PlannedResponse(.internalServerError, delay: .milliseconds(200))
        }
        do {
            try await withTestApp { app in
                let fixture = try await makeFixture(app)
                let subscription = try await makeSubscription(
                    app, fixture: fixture, url: "http://127.0.0.1:\(origin.port)/hook")
                subscription.failingSince = Date().addingTimeInterval(
                    -Double(app.webhookDelivery.autoDisableDays + 1) * 86_400)
                try await subscription.save(on: app.db)

                let failure = WebhookDelivery(
                    subscriptionID: subscription.id!, eventID: UUID(),
                    eventType: .webhookTest, payload: "{\"outcome\":\"fails\"}")
                failure.nextAttemptAt = Date().addingTimeInterval(-2)
                try await failure.save(on: app.db)

                // Start one pass with the failing request held at the origin.
                // A second pass then claims the success row for the same
                // subscription, reproducing the cross-pass overlap that can
                // happen when a sweep outlives the distributed lock TTL.
                let failingSweep = Task {
                    await app.webhookDelivery.sweepOnce()
                }
                let waitDeadline = ContinuousClock.now.advanced(by: .seconds(2))
                while origin.captured.withLockedValue({ $0.isEmpty }),
                    ContinuousClock.now < waitDeadline
                {
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(!origin.captured.withLockedValue { $0.isEmpty })

                let success = WebhookDelivery(
                    subscriptionID: subscription.id!, eventID: UUID(),
                    eventType: .webhookTest, payload: "{\"outcome\":\"succeeds\"}")
                success.nextAttemptAt = Date().addingTimeInterval(-1)
                try await success.save(on: app.db)
                await app.webhookDelivery.sweepOnce()
                _ = await failingSweep.value

                let reloaded = try #require(
                    try await WebhookSubscription.find(subscription.id, on: app.db))
                #expect(reloaded.isActive)
                #expect(reloaded.disabledReason == nil)
                let failingSince = try #require(reloaded.failingSince)
                #expect(failingSince > Date().addingTimeInterval(-60))
            }
        } catch {
            await origin.shutdown()
            throw error
        }
        await origin.shutdown()
    }

    @Test("A pass keeps claiming due deliveries beyond the concurrency limit")
    func drainsDueQueueBeyondFanOutCapacity() async throws {
        let origin = try await HookOrigin.start { _ in
            HookOrigin.PlannedResponse(.ok, delay: .milliseconds(50))
        }
        do {
            try await withTestApp { app in
                let fixture = try await makeFixture(app)
                let subscription = try await makeSubscription(
                    app, fixture: fixture, url: "http://127.0.0.1:\(origin.port)/hook")
                let deliveryCount = WebhookDeliveryService.claimBatchSize + 1
                for index in 0..<deliveryCount {
                    let delivery = WebhookDelivery(
                        subscriptionID: subscription.id!, eventID: UUID(),
                        eventType: .webhookTest, payload: "{\"index\":\(index)}")
                    delivery.nextAttemptAt = Date().addingTimeInterval(-1)
                    try await delivery.save(on: app.db)
                }

                await app.webhookDelivery.sweepOnce()

                let afterPass = try await WebhookDelivery.query(on: app.db).all()
                #expect(
                    origin.captured.withLockedValue { $0.count }
                        == deliveryCount)
                #expect(
                    afterPass.allSatisfy { $0.statusValue == .succeeded })
                #expect(
                    origin.maxInFlight.withLockedValue { $0 }
                        == WebhookDeliveryService.maxConcurrentDeliveries)
            }
        } catch {
            await origin.shutdown()
            throw error
        }
        await origin.shutdown()
    }

    @Test("A busy organization cannot exclude another organization from the first window")
    func fairClaimStartsQuietOrganizationInFirstWindow() async throws {
        let origin = try await HookOrigin.start { _ in
            HookOrigin.PlannedResponse(.ok, delay: .milliseconds(100))
        }
        do {
            try await withTestApp { app in
                let fixture = try await makeFixture(app)
                let url = "http://127.0.0.1:\(origin.port)/hook"
                for index in 0..<WebhookDeliveryService.claimBatchSize {
                    let busy = WebhookSubscription(
                        organizationID: fixture.organization.id!, projectID: nil,
                        name: "busy-\(index)", url: url,
                        eventTypes: [.webhookTest],
                        signingSecret: try app.secretsEncryption.encrypt("whsec_busy"),
                        createdByID: fixture.user.id!)
                    try await busy.save(on: app.db)
                    let delivery = WebhookDelivery(
                        subscriptionID: busy.id!, eventID: UUID(),
                        eventType: .webhookTest,
                        payload: "{\"subscription\":\"busy\",\"index\":\(index)}")
                    delivery.nextAttemptAt = Date().addingTimeInterval(-2)
                    try await delivery.save(on: app.db)
                }

                let builder = TestDataBuilder(db: app.db)
                let quietOrganization = try await builder.createOrganization(name: "Quiet Org")
                let quiet = WebhookSubscription(
                    organizationID: quietOrganization.id!, projectID: nil,
                    name: "quiet", url: url,
                    eventTypes: [.webhookTest],
                    signingSecret: try app.secretsEncryption.encrypt("whsec_quiet"),
                    createdByID: fixture.user.id!)
                try await quiet.save(on: app.db)
                let quietDelivery = WebhookDelivery(
                    subscriptionID: quiet.id!, eventID: UUID(),
                    eventType: .webhookTest,
                    payload: "{\"subscription\":\"quiet\"}")
                quietDelivery.nextAttemptAt = Date().addingTimeInterval(-1)
                try await quietDelivery.save(on: app.db)

                await app.webhookDelivery.sweepOnce()

                let firstWindow = origin.captured.withLockedValue {
                    Array($0.prefix(WebhookDeliveryService.maxConcurrentDeliveries))
                }
                #expect(firstWindow.contains { $0.body.contains("\"quiet\"") })
                #expect(
                    origin.captured.withLockedValue { $0.count }
                        == WebhookDeliveryService.claimBatchSize + 1)
            }
        } catch {
            await origin.shutdown()
            throw error
        }
        await origin.shutdown()
    }

    @Test("The pass budget stops another claim batch without abandoning claimed work")
    func passBudgetStopsBetweenBatches() async throws {
        let origin = try await HookOrigin.start()
        do {
            try await withTestApp { app in
                let fixture = try await makeFixture(app)
                let subscription = try await makeSubscription(
                    app, fixture: fixture, url: "http://127.0.0.1:\(origin.port)/hook")
                for index in 0...WebhookDeliveryService.claimBatchSize {
                    let delivery = WebhookDelivery(
                        subscriptionID: subscription.id!, eventID: UUID(),
                        eventType: .webhookTest, payload: "{\"index\":\(index)}")
                    try await delivery.save(on: app.db)
                }

                let service = WebhookDeliveryService(app: app, passBudgetSecondsOverride: 0)
                let disposition = await service.sweepOnce()

                #expect(disposition == .budgetExhausted)
                let rows = try await WebhookDelivery.query(on: app.db).all()
                #expect(rows.filter { $0.statusValue == .succeeded }.count == 16)
                #expect(rows.filter { $0.statusValue == .pending }.count == 1)
            }
        } catch {
            await origin.shutdown()
            throw error
        }
        await origin.shutdown()
    }

    @Test("A claim advances past another replica's locked subscription prefix")
    func claimSkipsLockedSubscriptionPrefix() async throws {
        try await withTestApp { app in
            let fixture = try await makeFixture(app)
            let subscription = try await makeSubscription(app, fixture: fixture)
            let deliveryCount = WebhookDeliveryService.claimBatchSize * 2
            for index in 0..<deliveryCount {
                let delivery = WebhookDelivery(
                    subscriptionID: subscription.id!, eventID: UUID(),
                    eventType: .webhookTest, payload: "{\"index\":\(index)}")
                delivery.nextAttemptAt = Date().addingTimeInterval(-1)
                try await delivery.save(on: app.db)
            }

            struct LockedDelivery: Decodable { let id: UUID }
            let claimed = try await app.db.transaction { tx in
                let sql = try #require(tx as? any SQLDatabase)
                let locked = try await sql.raw(
                    """
                    SELECT id
                    FROM webhook_deliveries
                    WHERE subscription_id = \(bind: subscription.id!)
                      AND status = 'pending'
                      AND next_attempt_at <= now()
                    ORDER BY next_attempt_at, created_at, id
                    LIMIT \(bind: WebhookDeliveryService.claimBatchSize)
                    FOR UPDATE SKIP LOCKED
                    """
                ).all(decoding: LockedDelivery.self)
                #expect(locked.count == WebhookDeliveryService.claimBatchSize)

                let claimed = try await app.webhookDelivery.claimDueDeliveries(on: app.db)
                #expect(Set(locked.map(\.id)).isDisjoint(with: claimed.map(\.id)))
                return claimed
            }
            #expect(claimed.count == WebhookDeliveryService.claimBatchSize)
        }
    }

    @Test("Concurrent replica-like passes scale fan-out without duplicate posts")
    func concurrentPassesClaimDisjointRows() async throws {
        let firstOrigin = try await HookOrigin.start { _ in
            HookOrigin.PlannedResponse(.ok, delay: .milliseconds(200))
        }
        let secondOrigin = try await HookOrigin.start { _ in
            HookOrigin.PlannedResponse(.ok, delay: .milliseconds(200))
        }
        do {
            try await withTestApp { app in
                let fixture = try await makeFixture(app)
                let subscriptions = [
                    try await makeSubscription(
                        app, fixture: fixture,
                        url: "http://127.0.0.1:\(firstOrigin.port)/hook"),
                    try await makeSubscription(
                        app, fixture: fixture,
                        url: "http://127.0.0.1:\(secondOrigin.port)/hook"),
                ]
                let deliveryCount = WebhookDeliveryService.claimBatchSize * 2
                for index in 0..<deliveryCount {
                    let delivery = WebhookDelivery(
                        subscriptionID: subscriptions[index % subscriptions.count].id!,
                        eventID: UUID(),
                        eventType: .webhookTest, payload: "{\"index\":\(index)}")
                    try await delivery.save(on: app.db)
                }

                async let first = app.webhookDelivery.sweepOnce()
                async let second = app.webhookDelivery.sweepOnce()
                _ = await (first, second)

                let eventIDs =
                    firstOrigin.captured.withLockedValue { $0.compactMap(\.eventID) }
                    + secondOrigin.captured.withLockedValue { $0.compactMap(\.eventID) }
                #expect(eventIDs.count == deliveryCount)
                #expect(Set(eventIDs).count == deliveryCount)
                #expect(
                    firstOrigin.maxInFlight.withLockedValue { $0 }
                        + secondOrigin.maxInFlight.withLockedValue { $0 }
                        > WebhookDeliveryService.maxConcurrentDeliveries)
                let rows = try await WebhookDelivery.query(on: app.db).all()
                #expect(rows.allSatisfy { $0.statusValue == .succeeded })
            }
        } catch {
            await firstOrigin.shutdown()
            await secondOrigin.shutdown()
            throw error
        }
        await firstOrigin.shutdown()
        await secondOrigin.shutdown()
    }

    @Test("A legacy drainer cannot reclaim a row leased by a new replica")
    func newClaimIsVisibleToLegacyDrainer() async throws {
        let origin = try await HookOrigin.start { _ in
            HookOrigin.PlannedResponse(.ok, delay: .milliseconds(300))
        }
        do {
            try await withTestApp { app in
                let fixture = try await makeFixture(app)
                let subscription = try await makeSubscription(
                    app, fixture: fixture, url: "http://127.0.0.1:\(origin.port)/hook")
                let delivery = WebhookDelivery(
                    subscriptionID: subscription.id!, eventID: UUID(),
                    eventType: .webhookTest, payload: "{}")
                try await delivery.save(on: app.db)

                let sweep = Task { await app.webhookDelivery.sweepOnce() }
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                while origin.captured.withLockedValue({ $0.isEmpty }),
                    ContinuousClock.now < deadline
                {
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(!origin.captured.withLockedValue { $0.isEmpty })

                struct LegacyClaim: Decodable { let id: UUID }
                let sql = try #require(app.db as? any SQLDatabase)
                let legacyClaims = try await sql.raw(
                    """
                    WITH due AS MATERIALIZED (
                        SELECT id
                        FROM webhook_deliveries
                        WHERE status = \(bind: WebhookDeliveryStatus.pending.rawValue)
                          AND next_attempt_at <= now()
                        ORDER BY next_attempt_at
                        LIMIT \(bind: WebhookDeliveryService.maxConcurrentDeliveries)
                        FOR UPDATE SKIP LOCKED
                    )
                    UPDATE webhook_deliveries AS delivery
                    SET next_attempt_at = now()
                        + (\(bind: WebhookDeliveryService.claimLeaseSeconds) * interval '1 second')
                    FROM due
                    WHERE delivery.id = due.id
                    RETURNING delivery.id
                    """
                ).all(decoding: LegacyClaim.self)

                #expect(legacyClaims.isEmpty)
                _ = await sweep.value
                #expect(origin.captured.withLockedValue { $0.count } == 1)
            }
        } catch {
            await origin.shutdown()
            throw error
        }
        await origin.shutdown()
    }

    @Test("Pending deliveries of a deactivated subscription are parked dead")
    func inactiveSubscriptionParksDeliveries() async throws {
        try await withTestApp { app in
            let fixture = try await makeFixture(app)
            let subscription = try await makeSubscription(app, fixture: fixture)
            subscription.isActive = false
            try await subscription.save(on: app.db)

            let delivery = WebhookDelivery(
                subscriptionID: subscription.id!,
                eventID: UUID(),
                eventType: .webhookTest,
                payload: "{}")
            try await delivery.save(on: app.db)

            await app.webhookDelivery.sweepOnce()

            let reloaded = try #require(try await WebhookDelivery.find(delivery.id, on: app.db))
            #expect(reloaded.statusValue == .dead)
            #expect(reloaded.lastError == "Subscription is disabled")
            // No attempt was made — the endpoint was never contacted.
            #expect(reloaded.attempts == 0)
        }
    }

    @Test("Backoff doubles from 30s and caps at an hour")
    func backoffSchedule() {
        #expect(WebhookDeliveryService.backoffSeconds(afterAttempts: 1) == 30)
        #expect(WebhookDeliveryService.backoffSeconds(afterAttempts: 2) == 60)
        #expect(WebhookDeliveryService.backoffSeconds(afterAttempts: 5) == 480)
        #expect(WebhookDeliveryService.backoffSeconds(afterAttempts: 8) == 3600)
        #expect(WebhookDeliveryService.backoffSeconds(afterAttempts: 20) == 3600)
    }
}
