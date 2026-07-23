import Testing
import Tracing
import Vapor
import VaporTesting

@testable import App

/// Marker carried through `ServiceContext` so a probe can prove it saw the
/// *same* context the middleware above bound, not merely a non-nil one.
private enum ContextMarkerKey: ServiceContextKey {
    typealias Value = String
}

/// Stands in for Vapor's `TracingMiddleware`: binds the task-local and mirrors
/// the same value onto `request.serviceContext`, which is the pair the
/// restoring middleware relies on.
private struct MarkerBindingMiddleware: AsyncMiddleware {
    let marker: String

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        var context = request.serviceContext
        context[ContextMarkerKey.self] = marker
        request.serviceContext = context
        return try await ServiceContext.$current.withValue(context) {
            try await next.respond(to: request)
        }
    }
}

/// Stands in for the future-based middleware Vapor still ships (its
/// `SessionsMiddleware`, `RequestAuthenticator`, `SessionAuthenticator`): it
/// chains downstream from inside an `EventLoopFuture` callback, which runs on
/// the event loop outside any Swift task and so drops task-local storage.
private struct EventLoopChainingMiddleware: Middleware {
    func respond(to request: Request, chainingTo next: any Responder) -> EventLoopFuture<Response> {
        request.eventLoop.flatSubmit {
            next.respond(to: request)
        }
    }
}

/// Reports what the task-local `ServiceContext` looked like at the innermost
/// point of the chain — as a response header, so no shared mutable state is
/// needed. `absent` means `ServiceContext.current` was nil, i.e. any span
/// started here would have begun a brand-new trace.
private struct ContextProbeMiddleware: AsyncMiddleware {
    static let headerName = "X-Test-Service-Context"

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let observed: String
        if let context = ServiceContext.current {
            observed = context[ContextMarkerKey.self] ?? "bound"
        } else {
            observed = "absent"
        }
        let response = try await next.respond(to: request)
        response.headers.replaceOrAdd(name: Self.headerName, value: observed)
        return response
    }
}

@Suite("Tracing context propagation", .serialized)
struct TracingContextPropagationTests {

    /// The regression this guards: a future-based middleware severs the Swift
    /// task, and everything below it loses the request's `ServiceContext`.
    /// Without a restore, spans started downstream have no parent to attach to.
    @Test("future-based middleware drops the task-local context")
    func eventLoopChainSeversContext() async throws {
        let app = try await Application.makeForTesting()
        app.middleware.use(MarkerBindingMiddleware(marker: "request-span"))
        app.middleware.use(EventLoopChainingMiddleware())
        app.middleware.use(ContextProbeMiddleware())
        app.get("probe") { _ in "ok" }

        try await app.test(.GET, "/probe") { res async throws in
            let observed = res.headers.first(name: ContextProbeMiddleware.headerName)
            #expect(observed == "absent")
        }

        try await app.shutdownForTesting()
    }

    @Test("the restoring middleware puts the request's context back")
    func restoringMiddlewareRebindsContext() async throws {
        let app = try await Application.makeForTesting()
        app.middleware.use(MarkerBindingMiddleware(marker: "request-span"))
        app.middleware.use(EventLoopChainingMiddleware())
        app.middleware.use(ServiceContextRestoringMiddleware())
        app.middleware.use(ContextProbeMiddleware())
        app.get("probe") { _ in "ok" }

        try await app.test(.GET, "/probe") { res async throws in
            let observed = res.headers.first(name: ContextProbeMiddleware.headerName)
            #expect(observed == "request-span")
        }

        try await app.shutdownForTesting()
    }

    /// End-to-end over the real middleware stack: by the time a request reaches
    /// the router, the context `TracingMiddleware` opened must still be bound,
    /// or every `fluent.query` / `iam.authorize` / Valkey span below it starts
    /// its own trace. Tests never bootstrap OpenTelemetry, so the context here
    /// is the no-op tracer's — empty, but bound, which is exactly the
    /// distinction that matters.
    @Test("the configured stack keeps the request context bound to the router")
    func configuredStackKeepsContextBound() async throws {
        let app = try await Application.makeForTesting()
        try await configure(app)
        // Appended after `configure`, so it runs innermost — immediately before
        // the router, where controllers and their queries run.
        app.middleware.use(ContextProbeMiddleware())

        try await app.test(.GET, "/health") { res async throws in
            #expect(res.status == .ok)
            let observed = res.headers.first(name: ContextProbeMiddleware.headerName)
            #expect(observed == "bound")
        }

        try await app.shutdownForTesting()
    }
}
