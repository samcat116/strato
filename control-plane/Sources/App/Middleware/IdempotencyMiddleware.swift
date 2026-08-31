import Fluent
import Vapor

/// Collapses a caller's repeated HTTP mutation into the first committed
/// outcome. Authentication must run before this middleware because the key
/// space is scoped to the acting principal.
struct IdempotencyMiddleware: AsyncMiddleware {
    static let headerName = "Idempotency-Key"

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        guard Self.isMutation(request.method),
            let key = request.headers.first(name: Self.headerName)
        else {
            return try await next.respond(to: request)
        }
        guard !key.isEmpty else {
            throw Abort(.badRequest, reason: "Idempotency-Key must not be empty")
        }
        // PostgreSQL `char_length` and OpenAPI `maxLength` both count Unicode
        // scalar values, so enforce the same boundary before the transaction.
        guard key.unicodeScalars.count <= 255 else {
            throw Abort(.badRequest, reason: "Idempotency-Key must not exceed 255 characters")
        }

        let actor = MutationActor(principal: try request.requireActingPrincipal())
        let body = request.body.data.map { Data($0.readableBytesView) } ?? Data()
        let context = IdempotencyRequestContext(
            actor: actor,
            key: key,
            requestDigest: try IdempotencyRequestDigest.compute(
                method: request.method, path: request.url.string, body: body))
        request.idempotencyContext = context

        if let claim = try await IdempotencyService.activeClaim(for: context, on: request.db) {
            let response = try await replay(claim, matching: context, on: request)
            return try await storeSuccessfulBody(response, for: context, on: request)
        }

        do {
            let response = try await next.respond(to: request)
            return try await storeSuccessfulBody(response, for: context, on: request)
        } catch is IdempotencyReplayRequired {
            // `reserve` only emits this after PostgreSQL has waited for the
            // competing principal/key insert to commit. Read that winner now;
            // the losing handler transaction has already rolled back.
            guard let claim = try await IdempotencyService.activeClaim(for: context, on: request.db)
            else {
                throw Abort(
                    .conflict,
                    reason: "A request with this idempotency key is still in progress")
            }
            let response = try await replay(claim, matching: context, on: request)
            return try await storeSuccessfulBody(response, for: context, on: request)
        } catch {
            // A winner can commit after the preflight lookup above while this
            // duplicate is still in controller validation, before it reaches
            // `reserve`. Prefer that committed outcome over a stale preflight
            // error such as "already started" or a post-create name conflict.
            if let claim = try await IdempotencyService.activeClaim(for: context, on: request.db) {
                let response = try await replay(claim, matching: context, on: request)
                return try await storeSuccessfulBody(response, for: context, on: request)
            }
            throw error
        }
    }

    private static func isMutation(_ method: HTTPMethod) -> Bool {
        method == .POST || method == .PUT || method == .PATCH || method == .DELETE
    }

    private func replay(
        _ claim: IdempotencyKey,
        matching context: IdempotencyRequestContext,
        on request: Request
    ) async throws -> Response {
        guard claim.requestDigest == context.requestDigest else {
            throw Abort(
                .unprocessableEntity,
                reason: "This Idempotency-Key was already used for a different request")
        }
        guard let kind = claim.resourceKind,
            let resourceID = claim.resourceID,
            let responseStatusCode = claim.responseStatus
        else {
            throw Abort(.internalServerError, reason: "The idempotency record is incomplete")
        }
        let responseStatus = HTTPStatus(statusCode: responseStatusCode)
        let accepted: ResourceMutation.Accepted?
        if responseStatus == .accepted {
            guard let mutationID = claim.mutationID,
                let targetGeneration = claim.targetGeneration
            else {
                throw Abort(.internalServerError, reason: "The idempotency record is incomplete")
            }
            accepted = ResourceMutation.Accepted(
                mutationID: mutationID, targetGeneration: targetGeneration)
        } else {
            accepted = nil
        }

        switch kind {
        case .virtualMachine:
            guard let vm = try await VM.find(resourceID, on: request.db) else {
                return try cachedResponse(from: claim)
            }
            try await request.authorize(
                "vm:read", on: IAMNode(type: .virtualMachine, id: resourceID))
            if let accepted {
                return try await VMController.acceptedResponse(for: vm, accepted, on: request)
            }
            guard responseStatus == .ok else {
                throw Abort(.internalServerError, reason: "The idempotency response is unsupported")
            }
            return try await VMController.detailResponse(for: vm, on: request)

        case .sandbox:
            guard let accepted else {
                throw Abort(.internalServerError, reason: "The idempotency response is unsupported")
            }
            guard let sandbox = try await Sandbox.find(resourceID, on: request.db) else {
                return try cachedResponse(from: claim)
            }
            try await request.authorize(
                "sandbox:read", on: IAMNode(type: .sandbox, id: resourceID))
            return try await AcceptedMutation(
                SandboxController.detailResponse(for: sandbox, on: request), accepted
            ).acceptedResponse()

        case .volume:
            guard let accepted else {
                throw Abort(.internalServerError, reason: "The idempotency response is unsupported")
            }
            guard let volume = try await Volume.find(resourceID, on: request.db) else {
                return try cachedResponse(from: claim)
            }
            try await request.authorize(
                "volume:read", on: IAMNode(type: .volume, id: resourceID))
            return try await AcceptedMutation(
                VolumeService.response(for: volume, on: request.db), accepted
            ).acceptedResponse()

        case .volumeSnapshot:
            guard let accepted else {
                throw Abort(.internalServerError, reason: "The idempotency response is unsupported")
            }
            guard let snapshot = try await VolumeSnapshot.find(resourceID, on: request.db) else {
                return try cachedResponse(from: claim)
            }
            try await request.authorize(
                "volume:read", on: IAMNode(type: .volumeSnapshot, id: resourceID))
            return try AcceptedMutation(SnapshotResponse(from: snapshot), accepted).acceptedResponse()

        case .vmCheckpoint:
            guard let accepted else {
                throw Abort(.internalServerError, reason: "The idempotency response is unsupported")
            }
            guard let snapshot = try await VMSnapshot.find(resourceID, on: request.db) else {
                return try cachedResponse(from: claim)
            }
            try await request.authorize(
                "vm:read", on: IAMNode(type: .vmSnapshot, id: resourceID))
            return try AcceptedMutation(VMSnapshotResponse(from: snapshot), accepted).acceptedResponse()

        case .sandboxSnapshot:
            guard let accepted else {
                throw Abort(.internalServerError, reason: "The idempotency response is unsupported")
            }
            guard let snapshot = try await SandboxSnapshot.find(resourceID, on: request.db) else {
                return try cachedResponse(from: claim)
            }
            try await request.authorize(
                "sandbox:read", on: IAMNode(type: .sandboxSnapshot, id: resourceID))
            return try AcceptedMutation(
                SandboxSnapshotResponse(from: snapshot), accepted
            ).acceptedResponse()
        }
    }

    private func storeSuccessfulBody(
        _ response: Response,
        for context: IdempotencyRequestContext,
        on request: Request
    ) async throws -> Response {
        guard (200..<300).contains(response.status.code), let body = response.body.data else {
            return response
        }
        do {
            _ = try await IdempotencyService.storeResponseBody(body, for: context, on: request.db)
        } catch {
            // The mutation and its stable outcome already committed together.
            // This write only caches a richer body for later replay, so its
            // failure must not turn an accepted mutation into an ambiguous 500.
            request.logger.warning(
                "Failed to cache idempotency response body",
                metadata: ["error": .string(error.localizedDescription)])
        }
        return response
    }

    private func cachedResponse(from claim: IdempotencyKey) throws -> Response {
        guard let body = claim.responseBody, let responseStatus = claim.responseStatus else {
            throw Abort(.internalServerError, reason: "The idempotency response is incomplete")
        }
        var headers = HTTPHeaders()
        headers.contentType = .json
        return Response(
            status: HTTPStatus(statusCode: responseStatus),
            headers: headers,
            body: .init(data: body))
    }
}
