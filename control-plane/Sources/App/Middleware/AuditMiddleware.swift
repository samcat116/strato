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

    /// Append the generic request fact shared by ordinary HTTP middleware and
    /// handlers that discover a refusal only after a WebSocket upgrade.
    ///
    /// `force` bypasses the normal successful-read suppression. This is used
    /// for 401/403 outcomes: authorization refusals must remain visible even
    /// when the upgraded route began as a GET and read auditing is disabled.
    func recordAPIRequestAudit(
        status: HTTPResponseStatus,
        error: (any Error)? = nil,
        force: Bool = false,
        failOpen: Bool = false,
        redactErrorDetails: Bool = false
    ) async {
        let isRead: Bool
        switch method {
        case .GET, .HEAD, .OPTIONS:
            isRead = true
        default:
            isRead = false
        }
        guard force || !isRead || audit.config.includeReads || adminBypassUsed else {
            return
        }

        let user = auth.get(User.self)
        let resource = parseResource(path: url.path, method: method)

        var metadata: [String: String]? = nil
        if let error, !redactErrorDetails {
            metadata = ["error": "\(error)"]
        }

        let record = AuditRecord(
            eventType: AuditEventType.apiRequest.rawValue,
            userID: user?.id,
            // A JWT-SVID request has no user record, so `user_id` stays
            // nil — but the row must still name who acted. The verified
            // SPIFFE ID goes in `username`, which is free text, rather
            // than inventing a user id for a machine principal (#495).
            // Without this, workload requests would audit as nobody.
            username: user?.username ?? authenticatedWorkload?.spiffeID.uri,
            apiKeyID: apiKey?.id,
            organizationID: resource.organizationID ?? user?.currentOrganizationId,
            method: method.rawValue,
            path: url.path,
            status: Int(status.code),
            resourceType: resource.type,
            resourceID: resource.id,
            action: resource.action,
            sourceIP: auditClientIP,
            adminBypass: adminBypassUsed,
            metadata: metadata)
        if failOpen {
            await audit.recordFailOpen(record)
        } else {
            await audit.record(record)
        }
    }
}

/// Records an audit event for API requests (issue #39):
/// - every mutation (non-GET/HEAD/OPTIONS) under `/api/`,
/// - every request served via the system-admin bypass (including reads, so
///   admin activity leaves a granular trail — absorbed issue #58),
/// - reads too, when `AUDIT_INCLUDE_READS` is set.
///
/// Registered after the authenticators (so events carry the resolved user and
/// API key) and before `AuthorizationMiddleware` (so denied requests are audited
/// with their 401/403 status). Like `RequestLoggingMiddleware`, the error path
/// derives the status the client will see from the thrown error, then
/// rethrows.
struct AuditMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        guard request.url.path.hasPrefix("/api/"), request.audit.isEnabled else {
            return try await next.respond(to: request)
        }

        let guestExecution = isVMGuestExecutionAuditPath(request.url.path)
        do {
            let response = try await next.respond(to: request)
            await request.recordAPIRequestAudit(
                status: response.status,
                failOpen: guestExecution,
                redactErrorDetails: guestExecution)
            return response
        } catch {
            let status = (error as? any AbortError)?.status ?? .internalServerError
            await request.recordAPIRequestAudit(
                status: status,
                error: error,
                force: guestExecution || status == .unauthorized || status == .forbidden,
                failOpen: guestExecution,
                redactErrorDetails: guestExecution)
            throw error
        }
    }
}

/// Guest execution request and attach facts remain buffered even when ordinary
/// request auditing is configured synchronously. This keeps both accepted and
/// refused execution attempts independent of database or SIEM availability.
func isVMGuestExecutionAuditPath(_ path: String) -> Bool {
    let components = path.split(separator: "/").map(String.init)
    guard components.count >= 4,
        components[0] == "api",
        components[1] == "vms"
    else { return false }

    let suffix = Array(components.dropFirst(3))
    if suffix == ["actions", "run"] || suffix == ["exec"] {
        return true
    }
    return suffix.count == 3 && suffix[0] == "exec" && suffix[2] == "attach"
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
        let rawID = components[1]
        // VM domain events and VM-filtered audit queries use UUID.uuidString.
        // Normalize the generic request fact too, so a denied request cannot
        // disappear merely because its route parameter used lowercase hex.
        ref.id = ref.type == "vms" ? UUID(uuidString: rawID)?.uuidString ?? rawID : rawID
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
