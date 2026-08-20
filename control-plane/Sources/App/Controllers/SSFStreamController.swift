import ControlPlanePostgres
import Foundation
import SwiftSSF
import Vapor

/// Shared Signals Framework receiver API (issue #38).
///
/// Org-scoped stream management (org members read, org admins mutate):
/// - `GET/POST  /api/organizations/:organizationID/ssf-streams`
/// - `GET/PUT/DELETE /api/organizations/:organizationID/ssf-streams/:streamID`
/// - `POST .../:streamID/register` — create the stream at the transmitter;
///   for push streams the response carries the inbound bearer token, shown once.
/// - `POST .../:streamID/verify` — request a verification event.
/// - `GET  .../:streamID/status` — transmitter-side stream status.
/// - `POST .../:streamID/poll` — drain a poll stream immediately.
///
/// Plus the public RFC 8935 push delivery endpoint (exempt from session auth
/// in `AuthorizationMiddleware`; authenticated in-handler with the per-stream
/// bearer token):
/// - `POST /ssf/events/:streamID`
struct SSFStreamController: RouteCollection {
    private let streams: SSFStreamsPersistence

    init(streams: SSFStreamsPersistence) {
        self.streams = streams
    }

    func boot(routes: RoutesBuilder) throws {
        let streams = routes.grouped("api", "organizations", ":organizationID", "ssf-streams")
        streams.get(use: list)
        streams.post(use: create)
        streams.group(":streamID") { stream in
            stream.get(use: get)
            stream.put(use: update)
            stream.delete(use: delete)
            stream.post("register", use: register)
            stream.post("verify", use: verify)
            stream.get("status", use: status)
            stream.post("poll", use: pollNow)
        }

        // RFC 8935: transmitters POST SETs here with Content-Type
        // application/secevent+jwt and the stream's bearer token.
        routes.on(.POST, "ssf", "events", ":streamID", body: .collect(maxSize: "1mb"), use: receivePush)
    }

    // MARK: - CRUD

    func list(req: Request) async throws -> [SSFStreamResponse] {
        let organizationID = try requireOrganizationID(req)
        try await OrganizationAccessService.requireMember(organizationID: organizationID, on: req)

        return try await streams.streams(organizationID: organizationID)
            .map { response(for: $0, on: req) }
    }

    func create(req: Request) async throws -> Response {
        let organizationID = try requireOrganizationID(req)
        try await OrganizationAccessService.requireAdmin(organizationID: organizationID, on: req)
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        let request = try req.content.decodeValidated(CreateSSFStreamRequest.self)
        try SSFValidation.validateTransmitterURL(
            request.transmitterURL, configuration: req.controlPlaneConfiguration)

        let stream = try await streams.create(
            SSFStreamWrite(
                organizationID: organizationID,
                name: request.name,
                description: request.description,
                transmitterURL: request.transmitterURL,
                encryptedAuthToken: try request.authToken.map { try req.secretsEncryption.encrypt($0) },
                expectedIssuer: request.expectedIssuer,
                expectedAudience: request.expectedAudience ?? [],
                deliveryMethod: request.deliveryMethod,
                eventsRequested: request.eventsRequested ?? [],
                createdByID: try user.requireID()
            )
        )

        let body = response(for: stream, on: req)
        let response = Response(status: .created)
        try response.content.encode(body)
        return response
    }

    func get(req: Request) async throws -> SSFStreamResponse {
        let stream = try await requireStream(req)
        try await OrganizationAccessService.requireMember(
            organizationID: stream.organizationID, on: req)
        return response(for: stream, on: req)
    }

    func update(req: Request) async throws -> SSFStreamResponse {
        let stream = try await requireStream(req)
        try await OrganizationAccessService.requireAdmin(
            organizationID: stream.organizationID, on: req)

        let request = try req.content.decodeValidated(UpdateSSFStreamRequest.self)
        guard
            let updated = try await streams.updateOwnedStream(
                id: stream.id,
                organizationID: stream.organizationID,
                changes: SSFStreamChanges(
                    name: request.name,
                    description: request.description,
                    encryptedAuthToken: try request.authToken.map {
                        try req.secretsEncryption.encrypt($0)
                    },
                    expectedIssuer: request.expectedIssuer,
                    expectedAudience: request.expectedAudience,
                    eventsRequested: request.eventsRequested,
                    enabled: request.enabled
                )
            )
        else {
            throw Abort(.notFound, reason: "SSF stream not found")
        }

        // The receiver caches transmitter metadata and verification settings.
        await req.application.ssf.invalidateReceiver(for: updated.id)
        return response(for: updated, on: req)
    }

    func delete(req: Request) async throws -> HTTPStatus {
        let stream = try await requireStream(req)
        try await OrganizationAccessService.requireAdmin(
            organizationID: stream.organizationID, on: req)

        await req.application.ssf.deleteRemoteStream(stream)
        await req.application.ssf.invalidateReceiver(for: stream.id)
        guard
            try await streams.deleteOwnedStream(
                id: stream.id,
                organizationID: stream.organizationID
            )
        else {
            throw Abort(.notFound, reason: "SSF stream not found")
        }
        return .noContent
    }

    // MARK: - Transmitter actions

    func register(req: Request) async throws -> RegisterSSFStreamResponse {
        let stream = try await requireStream(req)
        try await OrganizationAccessService.requireAdmin(
            organizationID: stream.organizationID, on: req)
        guard stream.enabled else {
            throw Abort(.conflict, reason: "Stream is disabled")
        }

        let result = try await req.application.ssf.registerStream(stream)
        return RegisterSSFStreamResponse(
            stream: response(for: result.stream, on: req),
            pushToken: result.pushToken
        )
    }

    func verify(req: Request) async throws -> HTTPStatus {
        let stream = try await requireStream(req)
        try await OrganizationAccessService.requireAdmin(
            organizationID: stream.organizationID, on: req)
        try await req.application.ssf.requestVerification(of: stream)
        return .accepted
    }

    func status(req: Request) async throws -> SSFStreamStatusResponse {
        let stream = try await requireStream(req)
        try await OrganizationAccessService.requireMember(
            organizationID: stream.organizationID, on: req)
        let status = try await req.application.ssf.streamStatus(of: stream)
        return SSFStreamStatusResponse(
            remoteStreamID: status.stream_id,
            status: status.status.rawValue,
            reason: status.reason
        )
    }

    func pollNow(req: Request) async throws -> SSFPollResultResponse {
        let stream = try await requireStream(req)
        try await OrganizationAccessService.requireAdmin(
            organizationID: stream.organizationID, on: req)
        return try await req.application.ssf.pollStream(stream)
    }

    // MARK: - RFC 8935 push delivery

    func receivePush(req: Request) async throws -> Response {
        guard let streamIDParam = req.parameters.get("streamID"),
            let streamID = UUID(uuidString: streamIDParam),
            let stream = try await streams.stream(id: streamID)
        else {
            return setErrorResponse(.notFound, err: "invalid_request", description: "Unknown stream")
        }

        // Requiring a remote registration also guarantees the push token is
        // current: unregistering clears both together.
        guard stream.enabled, stream.deliveryMethodValue == .push, stream.remoteStreamID != nil
        else {
            return setErrorResponse(
                .notFound, err: "invalid_request",
                description: "Stream does not accept push delivery")
        }

        guard let bearer = req.headers.bearerAuthorization?.token,
            stream.pushTokenHash == SSFPushCredential.hashPushToken(bearer)
        else {
            return setErrorResponse(
                .unauthorized, err: "authentication_failed",
                description: "Invalid or missing bearer token")
        }

        guard let contentType = req.headers.contentType,
            contentType.type == "application", contentType.subType == "secevent+jwt"
        else {
            return setErrorResponse(
                .badRequest, err: "invalid_request",
                description: "Content-Type must be application/secevent+jwt")
        }

        guard let body = req.body.string, !body.isEmpty else {
            return setErrorResponse(
                .badRequest, err: "invalid_request", description: "Empty request body")
        }

        do {
            try await req.application.ssf.processInboundToken(
                body.trimmingCharacters(in: .whitespacesAndNewlines), stream: stream)
            return Response(status: .accepted)
        } catch let error as SSFError {
            let status = SETErrorStatus(reporting: error)
            return setErrorResponse(
                .badRequest, err: status.err, description: status.description)
        }
    }

    private func setErrorResponse(
        _ status: HTTPStatus, err: String, description: String?
    ) -> Response {
        struct SETErrorBody: Content {
            let err: String
            let description: String?
        }
        let response = Response(status: status)
        try? response.content.encode(SETErrorBody(err: err, description: description), as: .json)
        return response
    }

    // MARK: - Helpers

    private func requireOrganizationID(_ req: Request) throws -> UUID {
        guard let raw = req.parameters.get("organizationID"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }
        return id
    }

    private func requireStream(_ req: Request) async throws -> SSFStreamSnapshot {
        let organizationID = try requireOrganizationID(req)
        guard let raw = req.parameters.get("streamID"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "Invalid stream ID")
        }
        guard
            let stream = try await streams.ownedStream(
                id: id,
                organizationID: organizationID
            )
        else {
            throw Abort(.notFound, reason: "SSF stream not found")
        }
        return stream
    }

    private func response(for stream: SSFStreamSnapshot, on req: Request) -> SSFStreamResponse {
        let pushEndpoint =
            stream.deliveryMethodValue == .push
            ? SSFService.pushEndpointURL(
                for: stream.id, configuration: req.controlPlaneConfiguration)
            : nil
        return SSFStreamResponse(from: stream, pushEndpoint: pushEndpoint)
    }
}

struct RegisterSSFStreamResponse: Content {
    let stream: SSFStreamResponse
    /// Inbound push bearer token, present only for push streams and only in
    /// this response — it is stored hashed.
    let pushToken: String?
}
