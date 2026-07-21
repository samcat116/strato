import Vapor

extension Request {
    /// Whether any authorization decision this request was allowed by the
    /// `platform-system-admin` policy, so `AuditMiddleware` can record it as a
    /// first-class admin audit event (issue #39). Since cutover (#482) this is
    /// derived from the evaluator's determining policies — there is no code
    /// bypass to flag anymore.
    var adminBypassUsed: Bool {
        iamAuthState.adminPolicyUsed.withLockedValue { $0 }
    }
}

/// Records an audit event for API requests (issue #39):
/// - every mutation (non-GET/HEAD/OPTIONS) under `/api/`,
/// - every request served via the system-admin bypass (including reads, so
///   admin activity leaves a granular trail — absorbed issue #58),
/// - reads too, when `AUDIT_INCLUDE_READS` is set.
///
/// Registered after the authenticators (so events carry the resolved user and
/// API key) and before `SpiceDBAuthMiddleware` (so denied requests are audited
/// with their 401/403 status). Like `RequestLoggingMiddleware`, the error path
/// derives the status the client will see from the thrown error, then
/// rethrows.
struct AuditMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        guard request.url.path.hasPrefix("/api/"), request.audit.isEnabled else {
            return try await next.respond(to: request)
        }

        do {
            let response = try await next.respond(to: request)
            await recordIfNeeded(request: request, status: response.status)
            return response
        } catch {
            let status = (error as? any AbortError)?.status ?? .internalServerError
            await recordIfNeeded(request: request, status: status, error: error)
            throw error
        }
    }

    private func recordIfNeeded(
        request: Request, status: HTTPResponseStatus, error: (any Error)? = nil
    ) async {
        let isRead: Bool
        switch request.method {
        case .GET, .HEAD, .OPTIONS:
            isRead = true
        default:
            isRead = false
        }
        guard !isRead || request.audit.config.includeReads || request.adminBypassUsed else {
            return
        }

        let user = request.auth.get(User.self)
        let resource = parseResource(path: request.url.path, method: request.method)

        var metadata: [String: String]? = nil
        if let error {
            metadata = ["error": "\(error)"]
        }

        await request.audit.record(
            AuditRecord(
                eventType: AuditEventType.apiRequest.rawValue,
                userID: user?.id,
                username: user?.username,
                apiKeyID: request.apiKey?.id,
                organizationID: resource.organizationID ?? user?.currentOrganizationId,
                method: request.method.rawValue,
                path: request.url.path,
                status: Int(status.code),
                resourceType: resource.type,
                resourceID: resource.id,
                action: resource.action,
                sourceIP: request.auditClientIP,
                adminBypass: request.adminBypassUsed,
                metadata: metadata
            ))
    }
}

struct AuditResourceRef: Equatable {
    var type: String?
    var id: String?
    var action: String?
    var organizationID: UUID?
}

/// Derive a coarse resource reference from an `/api/...` path. Best-effort —
/// the full path is stored on every event, so this only needs to make common
/// shapes filterable: `/api/vms/:id/start`, `/api/organizations/:orgID/groups/:id`, ...
func parseResource(path: String, method: HTTPMethod) -> AuditResourceRef {
    var components = path.split(separator: "/").map(String.init)
    guard components.first == "api" else { return AuditResourceRef() }
    components.removeFirst()

    var ref = AuditResourceRef()

    // Org-scoped routes: capture the organization, then describe the nested
    // resource. A bare `/api/organizations/:id` stays the resource itself.
    if components.count > 2, components[0] == "organizations",
        let orgID = UUID(uuidString: components[1])
    {
        ref.organizationID = orgID
        components.removeFirst(2)
    }

    guard !components.isEmpty else { return ref }
    ref.type = components[0]
    if components.count > 1 {
        ref.id = components[1]
    }

    // Trailing path component after the id (e.g. `start`, `stop`, `members`):
    // for a POST that's the action being performed.
    if components.count > 2, method == .POST {
        ref.action = components[2...].joined(separator: "/")
    } else {
        switch method {
        case .GET, .HEAD, .OPTIONS:
            ref.action = "read"
        case .POST:
            ref.action = ref.id == nil ? "create" : "update"
        case .PUT, .PATCH:
            ref.action = "update"
        case .DELETE:
            ref.action = "delete"
        default:
            ref.action = method.rawValue.lowercased()
        }
    }
    return ref
}
