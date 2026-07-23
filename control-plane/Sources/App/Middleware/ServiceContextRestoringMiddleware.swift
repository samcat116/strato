import Tracing
import Vapor

/// Re-binds the task-local `ServiceContext` from `request.serviceContext`, so
/// spans opened downstream nest under the per-request server span instead of
/// each starting a trace of their own.
///
/// Vapor's `TracingMiddleware` opens the server span with `withSpan`, which
/// binds `ServiceContext.$current` for its operation closure *and* stores the
/// span's context on `request.serviceContext`. Every tracer we depend on —
/// `withSpan` at our own call sites, FluentKit's `fluent.query`, valkey-swift's
/// per-command spans, async-http-client's per-request spans — reads the
/// task-local, not the request property, to find its parent.
///
/// The task-local does not survive the middleware chain. Vapor 4 still has
/// `EventLoopFuture`-based middleware, and those chain downstream from inside a
/// future callback:
///
/// ```swift
/// // Vapor's RequestAuthenticator / SessionAuthenticator / SessionsMiddleware
/// return future.flatMap { _ in next.respond(to: request) }
/// ```
///
/// A `flatMap` callback runs on the event loop, outside any Swift task, so the
/// task-local storage bound further up is gone. The `AsyncMiddleware` bridge
/// downstream then spawns a fresh `Task` (`EventLoopPromise.completeWithTask`)
/// with no enclosing task to inherit from, and `ServiceContext.current` reads
/// back `nil` for the whole rest of the request. Anything that starts a span
/// from there — the rate limiter's Valkey `EVAL`, `iam.authorize`, every
/// controller's Fluent queries — becomes a root span in its own trace.
///
/// `request.serviceContext` is unaffected: it lives on the `Request` object and
/// `TracingMiddleware` only restores it after the whole chain returns. So this
/// middleware just puts it back where the tracers look, and must be registered
/// after the last future-based middleware in the stack.
struct ServiceContextRestoringMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        try await ServiceContext.$current.withValue(request.serviceContext) {
            try await next.respond(to: request)
        }
    }
}
