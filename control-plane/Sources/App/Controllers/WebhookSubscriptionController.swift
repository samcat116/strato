import Fluent
import Foundation
import Vapor

/// User-managed webhook subscriptions (issue #559).
///
/// Org-scoped subscription management (org members read, org admins mutate):
/// - `GET/POST  /api/organizations/:organizationID/webhooks`
/// - `GET/PUT/DELETE /api/organizations/:organizationID/webhooks/:webhookID`
/// - `POST .../:webhookID/rotate-secret` — new signing secret, shown once.
/// - `POST .../:webhookID/test` — enqueue a `webhook.test` delivery.
/// - `GET  .../:webhookID/deliveries` — recent delivery history.
/// - `POST .../:webhookID/deliveries/:deliveryID/redeliver` — re-enqueue one.
struct WebhookSubscriptionController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let webhooks = routes.grouped("api", "organizations", ":organizationID", "webhooks")
        webhooks.get(use: list)
        webhooks.post(use: create)
        webhooks.group(":webhookID") { webhook in
            webhook.get(use: get)
            webhook.put(use: update)
            webhook.delete(use: delete)
            webhook.post("rotate-secret", use: rotateSecret)
            webhook.post("test", use: sendTestEvent)
            webhook.get("deliveries", use: listDeliveries)
            webhook.post("deliveries", ":deliveryID", "redeliver", use: redeliver)
        }
    }

    // MARK: - CRUD

    func list(req: Request) async throws -> [WebhookSubscriptionResponse] {
        let organizationID = try requireOrganizationID(req)
        try await OrganizationAccessService.requireMember(organizationID: organizationID, on: req)

        let subscriptions = try await WebhookSubscription.query(on: req.db)
            .filter(\.$organization.$id == organizationID)
            .sort(\.$createdAt)
            .all()
        return subscriptions.map(WebhookSubscriptionResponse.init(from:))
    }

    func create(req: Request) async throws -> Response {
        let organizationID = try requireOrganizationID(req)
        try await OrganizationAccessService.requireAdmin(organizationID: organizationID, on: req)
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        let request = try req.content.decode(CreateWebhookSubscriptionRequest.self)
        let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw Abort(.badRequest, reason: "Webhook name must not be empty")
        }
        try await validateTargetURL(request.url, on: req)
        let eventTypes = try parseEventTypes(request.eventTypes)
        if let projectID = request.projectId {
            try await validateProjectScope(projectID, organizationID: organizationID, on: req.db)
        }

        let secret = WebhookSubscription.generateSigningSecret()
        let subscription = WebhookSubscription(
            organizationID: organizationID,
            projectID: request.projectId,
            name: name,
            url: request.url,
            eventTypes: eventTypes,
            signingSecret: try req.secretsEncryption.encrypt(secret),
            createdByID: try user.requireID()
        )
        try await subscription.save(on: req.db)

        let body = WebhookSubscriptionWithSecretResponse(
            subscription: WebhookSubscriptionResponse(from: subscription),
            signingSecret: secret)
        let response = Response(status: .created)
        try response.content.encode(body)
        return response
    }

    func get(req: Request) async throws -> WebhookSubscriptionResponse {
        let subscription = try await requireSubscription(req)
        try await OrganizationAccessService.requireMember(
            organizationID: subscription.$organization.id, on: req)
        return WebhookSubscriptionResponse(from: subscription)
    }

    func update(req: Request) async throws -> WebhookSubscriptionResponse {
        let subscription = try await requireSubscription(req)
        try await OrganizationAccessService.requireAdmin(
            organizationID: subscription.$organization.id, on: req)

        let request = try req.content.decode(UpdateWebhookSubscriptionRequest.self)
        if let name = request.name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw Abort(.badRequest, reason: "Webhook name must not be empty")
            }
            subscription.name = trimmed
        }
        if let url = request.url {
            try await validateTargetURL(url, on: req)
            subscription.url = url
        }
        if let eventTypes = request.eventTypes {
            subscription.eventTypesArray = try parseEventTypes(eventTypes)
        }
        if let isActive = request.isActive {
            subscription.isActive = isActive
            // Re-activating clears the failure bookkeeping so the auto-disable
            // window restarts from scratch instead of immediately re-tripping.
            if isActive {
                subscription.disabledReason = nil
                subscription.failingSince = nil
            }
        }
        try await subscription.save(on: req.db)
        return WebhookSubscriptionResponse(from: subscription)
    }

    func delete(req: Request) async throws -> HTTPStatus {
        let subscription = try await requireSubscription(req)
        try await OrganizationAccessService.requireAdmin(
            organizationID: subscription.$organization.id, on: req)

        try await subscription.delete(on: req.db)
        return .noContent
    }

    // MARK: - Secret rotation

    func rotateSecret(req: Request) async throws -> WebhookSubscriptionWithSecretResponse {
        let subscription = try await requireSubscription(req)
        try await OrganizationAccessService.requireAdmin(
            organizationID: subscription.$organization.id, on: req)

        let secret = WebhookSubscription.generateSigningSecret()
        subscription.signingSecret = try req.secretsEncryption.encrypt(secret)
        try await subscription.save(on: req.db)

        return WebhookSubscriptionWithSecretResponse(
            subscription: WebhookSubscriptionResponse(from: subscription),
            signingSecret: secret)
    }

    // MARK: - Test event

    /// Enqueue a `webhook.test` delivery for exactly this subscription,
    /// bypassing its event-type selection — the point is proving the endpoint
    /// plus signature verification end to end.
    func sendTestEvent(req: Request) async throws -> WebhookDeliveryResponse {
        let subscription = try await requireSubscription(req)
        try await OrganizationAccessService.requireAdmin(
            organizationID: subscription.$organization.id, on: req)
        guard subscription.isActive else {
            throw Abort(.conflict, reason: "Subscription is disabled")
        }

        let event = WebhookEvent(
            type: .webhookTest,
            organizationID: subscription.$organization.id,
            projectID: subscription.$project.id,
            data: [
                "message": .string("Test event from Strato"),
                "subscriptionId": .string(try subscription.requireID().uuidString),
            ])
        let delivery = WebhookDelivery(
            subscriptionID: try subscription.requireID(),
            eventID: event.id,
            eventType: event.type,
            payload: try event.encodedPayload())
        try await delivery.save(on: req.db)
        return WebhookDeliveryResponse(from: delivery)
    }

    // MARK: - Delivery history

    func listDeliveries(req: Request) async throws -> [WebhookDeliveryResponse] {
        let subscription = try await requireSubscription(req)
        try await OrganizationAccessService.requireMember(
            organizationID: subscription.$organization.id, on: req)

        let limit = min(max(req.query[Int.self, at: "limit"] ?? 50, 1), 200)
        let deliveries = try await WebhookDelivery.query(on: req.db)
            .filter(\.$subscription.$id == subscription.requireID())
            .sort(\.$createdAt, .descending)
            .limit(limit)
            .all()
        return deliveries.map(WebhookDeliveryResponse.init(from:))
    }

    func redeliver(req: Request) async throws -> WebhookDeliveryResponse {
        let subscription = try await requireSubscription(req)
        try await OrganizationAccessService.requireAdmin(
            organizationID: subscription.$organization.id, on: req)
        guard subscription.isActive else {
            throw Abort(.conflict, reason: "Subscription is disabled")
        }

        guard let raw = req.parameters.get("deliveryID"), let deliveryID = UUID(uuidString: raw)
        else {
            throw Abort(.badRequest, reason: "Invalid delivery ID")
        }
        guard
            let delivery = try await WebhookDelivery.query(on: req.db)
                .filter(\.$id == deliveryID)
                .filter(\.$subscription.$id == subscription.requireID())
                .first()
        else {
            throw Abort(.notFound, reason: "Delivery not found")
        }
        guard delivery.statusValue != .pending else {
            throw Abort(.conflict, reason: "Delivery is already pending")
        }

        delivery.status = WebhookDeliveryStatus.pending.rawValue
        delivery.attempts = 0
        delivery.nextAttemptAt = Date()
        delivery.lastError = nil
        try await delivery.save(on: req.db)
        return WebhookDeliveryResponse(from: delivery)
    }

    // MARK: - Helpers

    private func requireOrganizationID(_ req: Request) throws -> UUID {
        guard let raw = req.parameters.get("organizationID"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }
        return id
    }

    private func requireSubscription(_ req: Request) async throws -> WebhookSubscription {
        let organizationID = try requireOrganizationID(req)
        guard let raw = req.parameters.get("webhookID"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "Invalid webhook ID")
        }
        guard
            let subscription = try await WebhookSubscription.query(on: req.db)
                .filter(\.$id == id)
                .filter(\.$organization.$id == organizationID)
                .first()
        else {
            throw Abort(.notFound, reason: "Webhook subscription not found")
        }
        return subscription
    }

    /// The scheme check is a fast client error; the SSRF guard rejects hosts
    /// resolving to non-public addresses. The delivery sweep re-validates at
    /// POST time, covering later DNS changes.
    private func validateTargetURL(_ urlString: String, on req: Request) async throws {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https", url.host != nil
        else {
            throw Abort(.badRequest, reason: "Webhook URL must be a valid http or https URL")
        }
        do {
            try await SSRFGuard.validate(
                url: url, environment: req.application.environment,
                on: req.application.threadPool)
        } catch let error as SSRFGuard.BlockedHostError {
            throw Abort(.badRequest, reason: error.reason)
        }
    }

    private func parseEventTypes(_ raw: [String]?) throws -> [WebhookEventType] {
        guard let raw else { return [] }
        return try raw.map { value in
            guard let type = WebhookEventType(rawValue: value),
                WebhookEventType.subscribable.contains(type)
            else {
                throw Abort(.badRequest, reason: "Unknown event type '\(value)'")
            }
            return type
        }
    }

    private func validateProjectScope(
        _ projectID: UUID, organizationID: UUID, on db: Database
    ) async throws {
        guard let project = try await Project.find(projectID, on: db),
            try await project.getRootOrganizationId(on: db) == organizationID
        else {
            throw Abort(.badRequest, reason: "Project does not belong to this organization")
        }
    }
}
