import Vapor

extension Application {
    /// Installs the complete HTTP middleware pipeline. Statement order is part
    /// of this module's interface.
    func bootstrapHTTPPipeline() throws {
        if controlPlaneConfiguration.bool(.requestLogging)! {
            middleware.use(RequestLoggingMiddleware())
            logger.info("Request logging enabled")
        }

        middleware.use(TracingMiddleware())
        middleware.use(MetricsMiddleware())

        configureBrowserTransportSecurity()
        try bootstrapStateStores()
        installAuthenticationAndAuthorizationMiddleware()
        configureBrowserIdentity()
    }

    private func configureBrowserTransportSecurity() {
        let servedOverTLS = controlPlaneConfiguration.bool(.httpTLSEnabled)!
        middleware.use(SecurityHeadersMiddleware(enableHSTS: servedOverTLS), at: .beginning)
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
        middleware.use(BearerAuthorizationHeaderAuthenticator())
        middleware.use(User.sessionAuthenticator())
        middleware.use(ServiceContextRestoringMiddleware())
        installRateLimitingMiddleware()
        middleware.use(AuditMiddleware())
        middleware.use(CredentialRestrictionMiddleware())
        middleware.use(UserSecurityMiddleware())
    }

    private func installRateLimitingMiddleware() {
        let rateLimitConfig = RateLimitConfig.fromConfiguration(controlPlaneConfiguration)
        let rateLimitFallbackStore = InMemoryRateLimitStore()
        let valkeyRateLimitStore =
            valkeyEnabled ? ValkeyRateLimitStore(client: coordinationValkey) : nil

        agentGuestIdentityRateLimiter = AgentGuestIdentityRateLimiter(
            config: rateLimitConfig,
            fallbackStore: rateLimitFallbackStore,
            valkeyStore: valkeyRateLimitStore)
        if rateLimitConfig.enabled {
            middleware.use(
                RateLimitMiddleware(
                    config: rateLimitConfig,
                    fallbackStore: rateLimitFallbackStore,
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
        configureWebAuthn(
            relyingPartyID: controlPlaneConfiguration.string(.webauthnRelyingPartyID)!,
            relyingPartyName: controlPlaneConfiguration.string(.webauthnRelyingPartyName)!,
            relyingPartyOrigin: controlPlaneConfiguration.string(.webauthnRelyingPartyOrigin)!
        )

        registrationPolicy = .fromConfiguration(controlPlaneConfiguration)
        if !registrationPolicy.selfRegistrationEnabled {
            logger.info(
                "Self-registration is disabled; only the first (bootstrap) account may be self-created",
                metadata: ["setting": .string(RegistrationPolicy.environmentKey)]
            )
        }

        middleware.use(AuthorizationMiddleware())
    }
}
