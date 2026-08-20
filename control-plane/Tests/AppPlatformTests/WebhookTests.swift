import Crypto
import ControlPlanePostgres
import Fluent
import Foundation
import NIOConcurrencyHelpers
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
    let apiToken = try await user.generateAPIKey(on: app)
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
) async throws -> WebhookSubscriptionSnapshot {
    try await app.webhookSubscriptionsPersistence.create(
        WebhookSubscriptionWrite(
            id: UUID(),
        organizationID: fixture.organization.id!,
        projectID: projectID,
        name: "test hook",
        url: url,
            eventTypesJSON: try webhookEventTypesJSON(eventTypes),
            encryptedSigningSecret: try app.secretsEncryption.encrypt(secret),
            isActive: true,
            disabledReason: nil,
            failingSince: nil,
        createdByID: fixture.user.id!
        ))
}

private func replaceSubscriptionState(
    _ app: Application,
    subscription: WebhookSubscriptionSnapshot,
    isActive: Bool,
    disabledReason: String?,
    failingSince: Date?
) async throws -> WebhookSubscriptionSnapshot {
    try #require(
        try await app.webhookSubscriptionsPersistence.replace(
            WebhookSubscriptionWrite(
                id: subscription.id,
                organizationID: subscription.organizationID,
                projectID: subscription.projectID,
                name: subscription.name,
                url: subscription.url,
                eventTypesJSON: subscription.eventTypesJSON,
                encryptedSigningSecret: subscription.encryptedSigningSecret,
                isActive: isActive,
                disabledReason: disabledReason,
                failingSince: failingSince,
                createdByID: subscription.createdByID
            )))
}

private func makeDelivery(
    _ app: Application,
    subscriptionID: UUID,
    eventID: UUID = UUID(),
    eventType: WebhookEventType = .webhookTest,
    payload: String = "{}",
    status: WebhookDeliveryStatus = .pending,
    attempts: Int = 0,
    nextAttemptAt: Date = Date(),
    lastError: String? = nil
) async throws -> WebhookDeliverySnapshot {
    try await app.webhookDeliveriesPersistence.create(
        WebhookDeliveryWrite(
            subscriptionID: subscriptionID,
            eventID: eventID,
            eventType: eventType.rawValue,
            payload: payload,
            status: status,
            attempts: attempts,
            nextAttemptAt: nextAttemptAt,
            lastError: lastError))
}

private func replaceDelivery(
    _ app: Application,
    delivery: WebhookDeliverySnapshot,
    status: WebhookDeliveryStatus,
    attempts: Int,
    nextAttemptAt: Date,
    lastError: String?
) async throws -> WebhookDeliverySnapshot {
    try #require(
        try await app.webhookDeliveriesPersistence.replace(
            WebhookDeliveryWrite(
                id: delivery.id,
                subscriptionID: delivery.subscriptionID,
                eventID: delivery.eventID,
                eventType: delivery.eventType,
                payload: delivery.payload,
                status: status,
                attempts: attempts,
                nextAttemptAt: nextAttemptAt,
                lastAttemptAt: delivery.lastAttemptAt,
                responseStatus: delivery.responseStatus,
                lastError: lastError,
                deliveredAt: delivery.deliveredAt)))
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
                .GET, "\(base)/\(subscription.id.uuidString)/deliveries"
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
            var subscription = try await makeSubscription(app, fixture: fixture)
            subscription = try await replaceSubscriptionState(
                app,
                subscription: subscription,
                isActive: false,
                disabledReason: "Automatically disabled after 3 day(s) of failed deliveries",
                failingSince: Date().addingTimeInterval(-86_400 * 4))

            let path =
                "/api/organizations/\(fixture.organization.id!.uuidString)"
                + "/webhooks/\(subscription.id.uuidString)"
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
                + "/webhooks/\(subscription.id.uuidString)/rotate-secret"
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
            _ = try await makeDelivery(app, subscriptionID: subscription.id)

            let path =
                "/api/organizations/\(fixture.organization.id!.uuidString)"
                + "/webhooks/\(subscription.id.uuidString)"
            try await app.test(.DELETE, path) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.apiToken)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            let remainingSubscriptions = try await app.webhookSubscriptionsPersistence
                .subscriptions(organizationID: fixture.organization.id!).count
            #expect(remainingSubscriptions == 0)
            let remainingDeliveries = try await app.webhookDeliveriesPersistence.count()
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
                + "/webhooks/\(subscription.id.uuidString)/test"
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
            var delivery = try await makeDelivery(app, subscriptionID: subscription.id)

            let path =
                "/api/organizations/\(fixture.organization.id!.uuidString)"
                + "/webhooks/\(subscription.id.uuidString)"
                + "/deliveries/\(delivery.id.uuidString)/redeliver"

            // Still pending: nothing to redeliver.
            try await app.test(.POST, path) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.apiToken)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            delivery = try await replaceDelivery(
                app,
                delivery: delivery,
                status: .dead,
                attempts: 8,
                nextAttemptAt: delivery.nextAttemptAt,
                lastError: "gave up")

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

    @Test("Delivery history lists newest first")
    func deliveryHistory() async throws {
        try await withTestApp { app in
            let fixture = try await makeFixture(app)
            let subscription = try await makeSubscription(app, fixture: fixture)
            for index in 0..<3 {
                _ = try await makeDelivery(
                    app,
                    subscriptionID: subscription.id,
                    payload: "{\"n\":\(index)}")
            }

            let path =
                "/api/organizations/\(fixture.organization.id!.uuidString)"
                + "/webhooks/\(subscription.id.uuidString)/deliveries?limit=2"
            try await app.test(.GET, path) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.apiToken)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let deliveries = try res.content.decode([WebhookDeliveryResponse].self)
                #expect(deliveries.count == 2)
                #expect(deliveries[0].payload == "{\"n\":2}")
            }
        }
    }
}

// MARK: - Outbox enqueue

@Suite("Webhook Outbox Tests", .serialized)
struct WebhookOutboxTests {

    @Test("Converging emits operation.completed once, naming the recorded mutation")
    func convergenceTransitionEnqueuesCompletion() async throws {
        try await withTestApp { app in
            let fixture = try await makeFixture(app)
            _ = try await makeSubscription(app, fixture: fixture)
            let builder = TestDataBuilder(db: app.db)
            var vm = try await builder.createVM(name: "converging-vm", project: fixture.project)

            // A lifecycle mutation as `ResourceMutation.accept` leaves it: the
            // desired-state change, the deadline, and the attribution event.
            vm.setFixtureDesiredStatus(.running)
            vm = vm.extendingConvergenceDeadline(by: 180)
            try await vm.save(on: app.db)
            _ = try await ResourceEvent.record(
                .boot, resourceKind: .virtualMachine, resourceID: vm.requireID(),
                actor: .user(fixture.user.requireID()), on: app.db)

            vm.observedGeneration = vm.generation
            vm.setStatus(.running)
            vm = try await ResourceConvergence.recordValueSuccess(vm, on: app.db).resource

            let deliveries = try await app.webhookDeliveriesPersistence.all()
            #expect(deliveries.count == 1)
            let delivery = try #require(deliveries.first)
            #expect(delivery.eventType == "operation.completed")
            #expect(delivery.payload.contains("\"operationKind\":\"boot\""))
            #expect(delivery.payload.contains(vm.id!.uuidString))

            // The transition is what fires, not the state: the deadline is
            // cleared, so a repeat is a no-op rather than a second delivery.
            vm = try await ResourceConvergence.recordValueSuccess(vm, on: app.db).resource
            #expect(try await app.webhookDeliveriesPersistence.count() == 1)
        }
    }

    @Test("A convergence failure emits operation.failed with the agent's reason")
    func convergenceFailureEnqueuesFailure() async throws {
        try await withTestApp { app in
            let fixture = try await makeFixture(app)
            _ = try await makeSubscription(app, fixture: fixture)
            let builder = TestDataBuilder(db: app.db)
            var vm = try await builder.createVM(name: "failing-vm", project: fixture.project)

            vm.setFixtureDesiredStatus(.running)
            try await vm.save(on: app.db)
            _ = try await ResourceEvent.record(
                .boot, resourceKind: .virtualMachine, resourceID: vm.requireID(),
                actor: .user(fixture.user.requireID()), on: app.db)

            let failure = try await ResourceConvergence.recordValueFailure(
                vm, mutation: .boot, reason: "no bootable device",
                telemetryReason: "convergence_failed", on: app.db)
            vm = failure.resource
            #expect(failure.outcome == .recorded)

            let delivery = try #require(
                try await app.webhookDeliveriesPersistence.all().first)
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
            var vm = try await builder.createVM(name: "reaped-vm", project: fixture.project)
            let vmID = try vm.requireID()

            vm = try await ResourceFinalizerService.stampForDeletion(vm, on: app.db)
            vm.setFixtureDesiredStatus(.absent)
            try await vm.save(on: app.db)
            // The request event is where the reap reads its delivery context —
            // by the time it runs there is no resource left to resolve one.
            _ = try await ResourceEvent.record(
                .delete, resourceKind: .virtualMachine, resourceID: vmID,
                actor: .user(fixture.user.requireID()), on: app.db)

            _ = try await ResourceFinalizerService.clear(.agentAbsent, from: vm, on: app.db, app: app)
            #expect(try await VM.find(vmID, on: app.db) == nil)

            let delivery = try #require(
                try await app.webhookDeliveriesPersistence.all().first)
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
            _ = try await replaceSubscriptionState(
                app, subscription: disabled, isActive: false,
                disabledReason: nil, failingSince: nil)

            // Right type and right project scope — both should match.
            let byType = try await makeSubscription(
                app, fixture: fixture, eventTypes: [.operationCompleted])
            let byProject = try await makeSubscription(
                app, fixture: fixture, projectID: fixture.project.id)

            var vm = try await builder.createVM(name: "hook-vm", project: fixture.project)
            vm.setFixtureDesiredStatus(.running)
            vm = vm.extendingConvergenceDeadline(by: 180)
            try await vm.save(on: app.db)
            _ = try await ResourceEvent.record(
                .boot, resourceKind: .virtualMachine, resourceID: vm.requireID(),
                actor: .user(fixture.user.requireID()), on: app.db)
            vm.observedGeneration = vm.generation
            vm.setStatus(.running)
            vm = try await ResourceConvergence.recordValueSuccess(vm, on: app.db).resource

            let deliveries = try await app.webhookDeliveriesPersistence.all()
            let recipients = Set(deliveries.map(\.subscriptionID))
            #expect(recipients == Set([byType.id, byProject.id]))

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

            let delivery = try #require(
                try await app.webhookDeliveriesPersistence.all().first)
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
            let quotaAt70 = quota.replacingCounters(reservedVCPUs: 7)
            let baseline = QuotaUsageSnapshot(of: quotaAt70)
            let quotaAt90 = quota.replacingCounters(reservedVCPUs: 9)
            try await WebhookEvents.enqueueQuotaThresholds(
                quota: quotaAt90, baseline: baseline, project: fixture.project, on: app.db)

            var deliveries = try await app.webhookDeliveriesPersistence.all()
            #expect(deliveries.count == 1)
            #expect(deliveries[0].payload.contains("\"threshold\":80"))
            #expect(deliveries[0].payload.contains("\"pool\":\"vcpus\""))

            // 70% -> 100% crosses both; only the 100 event fires.
            try await app.webhookDeliveriesPersistence.deleteAll()
            let quotaAt100 = quota.replacingCounters(reservedVCPUs: 10)
            try await WebhookEvents.enqueueQuotaThresholds(
                quota: quotaAt100, baseline: baseline, project: fixture.project, on: app.db)
            deliveries = try await app.webhookDeliveriesPersistence.all()
            #expect(deliveries.count == 1)
            #expect(deliveries[0].payload.contains("\"threshold\":100"))

            // Already past the threshold at baseline: no re-fire.
            try await app.webhookDeliveriesPersistence.deleteAll()
            let highBaseline = QuotaUsageSnapshot(of: quotaAt90)
            try await WebhookEvents.enqueueQuotaThresholds(
                quota: quotaAt100, baseline: highBaseline, project: fixture.project, on: app.db)
            deliveries = try await app.webhookDeliveriesPersistence.all()
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

    static func start(
        responseForRequest: (@Sendable (CapturedRequest) -> PlannedResponse)? = nil
    ) async throws -> HookOrigin {
        var env = Environment.testing
        env.arguments = ["vapor"]
        let origin = try await Application.make(env)
        origin.logger.logLevel = .error

        let captured = NIOLockedValueBox<[CapturedRequest]>([])
        let responseStatus = NIOLockedValueBox<HTTPResponseStatus>(.ok)

        origin.post("hook") { req -> Response in
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
            app: origin, port: port, captured: captured, responseStatus: responseStatus)
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
                let delivery = try await makeDelivery(
                    app,
                    subscriptionID: subscription.id,
                    eventID: event.id,
                    eventType: event.type,
                    payload: try event.encodedPayload())

                await app.webhookDelivery.sweepOnce(acquiringLock: false)

                let reloaded = try #require(
                    try await app.webhookDeliveriesPersistence.delivery(id: delivery.id))
                #expect(reloaded.status == .succeeded)
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
                let delivery = try await makeDelivery(app, subscriptionID: subscription.id)

                origin.responseStatus.withLockedValue { $0 = .internalServerError }
                await app.webhookDelivery.sweepOnce(acquiringLock: false)

                var reloaded = try #require(
                    try await app.webhookDeliveriesPersistence.delivery(id: delivery.id))
                #expect(reloaded.status == .pending)
                #expect(reloaded.attempts == 1)
                #expect(reloaded.responseStatus == 500)
                #expect(reloaded.lastError?.contains("500") == true)
                #expect(reloaded.nextAttemptAt > Date())

                let failingSubscription = try #require(
                    try await app.webhookSubscriptionsPersistence.subscription(id: subscription.id))
                #expect(failingSubscription.failingSince != nil)

                // Not due yet: an immediate pass must not retry.
                await app.webhookDelivery.sweepOnce(acquiringLock: false)
                reloaded = try #require(
                    try await app.webhookDeliveriesPersistence.delivery(id: delivery.id))
                #expect(reloaded.attempts == 1)

                // Force it due and let the endpoint recover.
                origin.responseStatus.withLockedValue { $0 = .ok }
                reloaded = try await replaceDelivery(
                    app,
                    delivery: reloaded,
                    status: reloaded.status,
                    attempts: reloaded.attempts,
                    nextAttemptAt: Date(),
                    lastError: reloaded.lastError)
                await app.webhookDelivery.sweepOnce(acquiringLock: false)

                reloaded = try #require(
                    try await app.webhookDeliveriesPersistence.delivery(id: delivery.id))
                #expect(reloaded.status == .succeeded)
                #expect(reloaded.attempts == 2)

                // A success clears the failure streak.
                let recovered = try #require(
                    try await app.webhookSubscriptionsPersistence.subscription(id: subscription.id))
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
                let delivery = try await makeDelivery(
                    app,
                    subscriptionID: subscription.id,
                    attempts: WebhookDeliveryService.maxAttempts - 1)

                origin.responseStatus.withLockedValue { $0 = .badGateway }
                await app.webhookDelivery.sweepOnce(acquiringLock: false)

                let reloaded = try #require(
                    try await app.webhookDeliveriesPersistence.delivery(id: delivery.id))
                #expect(reloaded.status == .dead)
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
                var subscription = try await makeSubscription(
                    app, fixture: fixture, url: "http://127.0.0.1:\(origin.port)/hook")
                subscription = try await replaceSubscriptionState(
                    app,
                    subscription: subscription,
                    isActive: true,
                    disabledReason: nil,
                    failingSince: Date().addingTimeInterval(
                        -Double(app.webhookDelivery.autoDisableDays + 1) * 86_400))

                _ = try await makeDelivery(app, subscriptionID: subscription.id)

                origin.responseStatus.withLockedValue { $0 = .internalServerError }
                await app.webhookDelivery.sweepOnce(acquiringLock: false)

                let disabled = try #require(
                    try await app.webhookSubscriptionsPersistence.subscription(id: subscription.id))
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
                var subscription = try await makeSubscription(
                    app, fixture: fixture, url: "http://127.0.0.1:\(origin.port)/hook")
                subscription = try await replaceSubscriptionState(
                    app,
                    subscription: subscription,
                    isActive: true,
                    disabledReason: nil,
                    failingSince: Date().addingTimeInterval(
                        -Double(app.webhookDelivery.autoDisableDays + 1) * 86_400))

                _ = try await makeDelivery(
                    app,
                    subscriptionID: subscription.id,
                    payload: "{\"outcome\":\"fails\"}",
                    nextAttemptAt: Date().addingTimeInterval(-2))

                // Start one pass with the failing request held at the origin.
                // A second pass then claims the success row for the same
                // subscription, reproducing the cross-pass overlap that can
                // happen when a sweep outlives the distributed lock TTL.
                let failingSweep = Task {
                    await app.webhookDelivery.sweepOnce(acquiringLock: false)
                }
                let waitDeadline = ContinuousClock.now.advanced(by: .seconds(2))
                while origin.captured.withLockedValue({ $0.isEmpty }),
                    ContinuousClock.now < waitDeadline
                {
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(!origin.captured.withLockedValue { $0.isEmpty })

                _ = try await makeDelivery(
                    app,
                    subscriptionID: subscription.id,
                    payload: "{\"outcome\":\"succeeds\"}",
                    nextAttemptAt: Date().addingTimeInterval(-1))
                await app.webhookDelivery.sweepOnce(acquiringLock: false)
                await failingSweep.value

                let reloaded = try #require(
                    try await app.webhookSubscriptionsPersistence.subscription(id: subscription.id))
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

    @Test("A pass claims only the deliveries it can start inside the lease")
    func claimDoesNotOutrunFanOutCapacity() async throws {
        let origin = try await HookOrigin.start()
        do {
            try await withTestApp { app in
                let fixture = try await makeFixture(app)
                let subscription = try await makeSubscription(
                    app, fixture: fixture, url: "http://127.0.0.1:\(origin.port)/hook")
                let deliveryCount = WebhookDeliveryService.maxConcurrentDeliveries + 1
                for index in 0..<deliveryCount {
                    _ = try await makeDelivery(
                        app,
                        subscriptionID: subscription.id,
                        payload: "{\"index\":\(index)}",
                        nextAttemptAt: Date().addingTimeInterval(-1))
                }

                await app.webhookDelivery.sweepOnce(acquiringLock: false)

                let afterFirstPass = try await app.webhookDeliveriesPersistence.all()
                #expect(
                    origin.captured.withLockedValue { $0.count }
                        == WebhookDeliveryService.maxConcurrentDeliveries)
                #expect(
                    afterFirstPass.filter { $0.status == .succeeded }.count
                        == WebhookDeliveryService.maxConcurrentDeliveries)
                let unclaimed = try #require(afterFirstPass.first { $0.status == .pending })
                #expect(unclaimed.attempts == 0)
                #expect(unclaimed.nextAttemptAt <= Date())

                await app.webhookDelivery.sweepOnce(acquiringLock: false)
                let afterSecondPass = try await app.webhookDeliveriesPersistence.all()
                #expect(afterSecondPass.allSatisfy { $0.status == .succeeded })
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
            _ = try await replaceSubscriptionState(
                app, subscription: subscription, isActive: false,
                disabledReason: nil, failingSince: nil)

            let delivery = try await makeDelivery(app, subscriptionID: subscription.id)

            await app.webhookDelivery.sweepOnce(acquiringLock: false)

            let reloaded = try #require(
                try await app.webhookDeliveriesPersistence.delivery(id: delivery.id))
            #expect(reloaded.status == .dead)
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
