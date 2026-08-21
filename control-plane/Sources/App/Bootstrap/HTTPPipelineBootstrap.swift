import Vapor

extension Application {
    /// Installs the complete HTTP middleware pipeline. Statement order in this
    /// method is significant: authentication, tracing, auditing, and default-
    /// deny authorization depend on the effective middleware order.
    func bootstrapHTTPPipeline() throws {
        // Request logging: one structured line per HTTP request (method/path/status/
        // duration). Registered first so it's the outermost middleware and times the
        // full request. Default on outside production; override with REQUEST_LOGGING.
        let requestLoggingEnabled =
            controlPlaneConfiguration.bool(.requestLogging)!
        if requestLoggingEnabled {
            middleware.use(RequestLoggingMiddleware())
            logger.info("Request logging enabled")
        }

        // Observability middleware, registered high in the stack so they time the
        // full request and so downstream child spans (authz, scheduler, etc.) nest
        // under the per-request server span:
        //  - Vapor's TracingMiddleware extracts inbound W3C trace context, opens one
        //    server span per request with HTTP semantic-convention attributes, and
        //    publishes it on request.serviceContext for the rest of the chain.
        //  - MetricsMiddleware emits RED metrics (count + duration) for every route.
        // Both go through the swift-otel-backed facades, which are no-ops when the
        // respective pillar is disabled, so they are always safe to register.
        middleware.use(TracingMiddleware())
        middleware.use(MetricsMiddleware())

        configureBrowserTransportSecurity()
        try bootstrapStateStores()
        installAuthenticationAndAuthorizationMiddleware()
        configureBrowserIdentity()
    }

    private func configureBrowserTransportSecurity() {
        // Whether browsers reach us over HTTPS. This can't be inferred from the Vapor
        // environment: the published image, single-host compose, and Helm chart all
        // run `--env production` yet default to serving plaintext HTTP (TLS, when
        // present, is terminated at an ingress/proxy we don't see). Defaulting
        // production to TLS would set `Secure` on the session cookie, and browsers on
        // http:// would then drop it — breaking login. So this is opt-in: deployments
        // that terminate TLS set HTTP_TLS_ENABLED=true (the Helm chart derives it from
        // the resolved browser-facing origin). Governs both HSTS and the Secure cookie
        // flag below.
        let servedOverTLS = controlPlaneConfiguration.bool(.httpTLSEnabled)!
        // Insert at the front so it wraps Vapor's default ErrorMiddleware (which is
        // registered ahead of any `.use`-appended middleware). Otherwise the 4xx/5xx
        // responses ErrorMiddleware synthesizes from thrown errors would flow back out
        // above this middleware and miss the security headers.
        middleware.use(SecurityHeadersMiddleware(enableHSTS: servedOverTLS), at: .beginning)

        // Harden the session cookie: always HTTPOnly, and Secure whenever we're
        // behind TLS so the cookie can't leak over a downgraded/plaintext request.
        // SameSite=lax keeps the cookie on top-level navigations (needed for the
        // OAuth/OIDC redirect back into the app) while blocking cross-site sends.
        sessions.configuration = .init(cookieName: "vapor-session") { sessionID in
            HTTPCookies.Value(
                string: sessionID.string,
                path: "/",
                isSecure: servedOverTLS,
                isHTTPOnly: true,
                sameSite: .lax
            )
        }
    }

    private func installAuthenticationAndAuthorizationMiddleware() {
        // Authenticate bearer credentials before installing the session
        // authenticator. Vapor's SessionAuthenticator persists any User that a
        // downstream middleware authenticated into the session on the response
        // path. With the opposite order, every API-key request silently created a
        // browser session and therefore depended on the session Valkey even when
        // it arrived without a cookie (STR-206). A bearer credential is already
        // self-contained; it must never be promoted into a browser session.
        middleware.use(BearerAuthorizationHeaderAuthenticator())

        // Configure browser-session authentication after bearer auth. Cookie-only
        // requests still restore and refresh their session exactly as before.
        middleware.use(User.sessionAuthenticator())

        // Put the task-local `ServiceContext` back after the last future-based
        // middleware in the stack. Vapor's `SessionsMiddleware` and
        // `User.sessionAuthenticator()` chain downstream from inside an
        // `EventLoopFuture` callback, which severs the Swift task the middleware
        // above was running on and with it the context `TracingMiddleware` bound —
        // so without this every span opened below (`iam.authorize`, the rate
        // limiter's Valkey command, every controller's `fluent.query`) would start
        // its own trace. Anything future-based added after this point needs another
        // one of these behind it; see the middleware's own doc comment.
        middleware.use(ServiceContextRestoringMiddleware())

        installRateLimitingMiddleware()

        // Audit logging (issue #39): durable audit events for API mutations, auth
        // flows, and system-admin activity, fanned out to configurable backends
        // (AUDIT_BACKENDS; database by default). Registered after the
        // authenticators (so events carry the resolved actor) and rate limiter
        // (so throttled spam is not audited), and before the credential-restriction
        // and authorization middleware so denied requests — restricted-credential
        // 403s included — are audited with their real status. No-ops when
        // AUDIT_ENABLED=false.
        middleware.use(AuditMiddleware())

        // Backstop for the routes a credential restriction cannot reach through the
        // evaluator: the identity-plane and public mutations that authorize by row
        // scoping rather than by decision (STR-115). Everything else is enforced
        // inside Cedar. Must run after the bearer authenticator above, which
        // populates request.apiKey / request.cliSession.
        middleware.use(CredentialRestrictionMiddleware())

        // Enforce per-user security state set by SSF signal handlers (issue #38):
        // disabled accounts and revoked sessions (session-epoch mismatch). After
        // both authenticators and the audit middleware (so denials are audited),
        // before authorization.
        middleware.use(UserSecurityMiddleware())
    }

    private func installRateLimitingMiddleware() {
        // Rate limiting: throttle per-IP (unauthenticated) and per-user
        // (authenticated). Registered after the authenticators so it can bucket by
        // the resolved user, and before authorization/controllers so throttled
        // requests are rejected before doing real work. Uses Valkey when configured
        // (shared across replicas), else a process-local counter. See issue #60.
        let rateLimitConfig = RateLimitConfig.fromConfiguration(controlPlaneConfiguration)
        let rateLimitFallbackStore = InMemoryRateLimitStore()
        let valkeyRateLimitStore =
            valkeyEnabled ? ValkeyRateLimitStore(client: coordinationValkey) : nil
        // Agent minting authenticates inside its controller, after this global
        // middleware runs. Give it the same policy and stores but a dedicated,
        // verified-agent key space so every Envoy sidecar request does not share
        // the loopback-IP API bucket.
        agentGuestIdentityRateLimiter = AgentGuestIdentityRateLimiter(
            config: rateLimitConfig,
            fallbackStore: rateLimitFallbackStore,
            valkeyStore: valkeyRateLimitStore)
        if rateLimitConfig.enabled {
            middleware.use(
                RateLimitMiddleware(
                    config: rateLimitConfig,
                    fallbackStore: rateLimitFallbackStore,
                    // Coordination, not sessions: these are cross-replica counters
                    // whose backend errors fail open without rejecting the request,
                    // which is exactly the coordination contract.
                    valkeyStore: valkeyRateLimitStore
                ))
            logger.info(
                "Rate limiting enabled",
                metadata: [
                    "authLimit": .stringConvertible(rateLimitConfig.authLimit),
                    "apiLimit": .stringConvertible(rateLimitConfig.apiLimit),
                ])
        }
    }

    private func configureBrowserIdentity() {
        let relyingPartyID = controlPlaneConfiguration.string(.webauthnRelyingPartyID)!
        let relyingPartyName = controlPlaneConfiguration.string(.webauthnRelyingPartyName)!
        let relyingPartyOrigin = controlPlaneConfiguration.string(.webauthnRelyingPartyOrigin)!

        configureWebAuthn(
            relyingPartyID: relyingPartyID,
            relyingPartyName: relyingPartyName,
            relyingPartyOrigin: relyingPartyOrigin
        )

        // Whether visitors may create their own accounts. Read once at boot: the
        // login page asks for the effective answer over /api/public/registration.
        registrationPolicy = .fromConfiguration(controlPlaneConfiguration)
        if !registrationPolicy.selfRegistrationEnabled {
            logger.info(
                "Self-registration is disabled; only the first (bootstrap) account may be self-created",
                metadata: ["setting": .string(RegistrationPolicy.environmentKey)]
            )
        }

        // Register the authorization middleware in every environment — including
        // .testing. It used to be skipped under .testing, which meant every controller
        // test ran with authorization off and no test could catch an authz regression
        // (issue #196). Since cutover (#482) authorization is evaluated by the
        // in-process Cedar policy set against real `role_bindings` rows, so tests
        // exercise the exact production decision path — there is no permissive mock
        // in front of it.
        middleware.use(AuthorizationMiddleware())
    }
}
