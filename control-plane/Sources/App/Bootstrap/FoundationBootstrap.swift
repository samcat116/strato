import Foundation
import StratoShared
import Vapor

extension Application {
    /// Resolves immutable startup configuration and installs process-wide
    /// facilities before any client or request pipeline is constructed.
    func bootstrapFoundation(environmentVariables: [String: String]) async throws {
        // Resolve every operator setting before constructing any service. A value
        // that is present but malformed must stop startup rather than being treated
        // as absent and replaced by a default at its eventual call site.
        let configuration = try await ControlPlaneConfiguration.load(
            environmentVariables: environmentVariables,
            for: environment)
        try bootstrapFoundation(
            resolvedConfiguration: configuration,
            preparedObservability: nil)
    }

    /// Installs foundation facilities from the configuration and logging
    /// backend prepared before `Application.make` by the executable entrypoint.
    func bootstrapFoundation(
        resolvedConfiguration: ControlPlaneConfiguration,
        preparedObservability: PreparedControlPlaneObservability?
    ) throws {
        controlPlaneConfiguration = resolvedConfiguration

        // Capture this process's identity once, before anything else, so the boot log
        // and the /health endpoints can report exactly who is answering. Two control
        // planes on the same port will report different instanceIds — the tell we
        // lacked when a stale duplicate silently intercepted port 8080.
        let identity = InstanceIdentity(
            instanceId: UUID(uuidString: replicaID)!,
            environment: environment.name)
        instanceIdentity = identity
        let baseLoggingMetadata = ControlPlaneLoggingMetadata.base(
            serviceName: controlPlaneConfiguration.string(.otelServiceName)!,
            serviceInstanceID: identity.instanceId.uuidString,
            environmentName: identity.environment,
            serviceVersion: BuildInfo.version(configuration: controlPlaneConfiguration))
        for (key, value) in baseLoggingMetadata {
            logger[metadataKey: key] = value
        }
        logger.info(
            "Control plane booting",
            metadata: [
                "vcs.revision": .string(BuildInfo.gitSHA(configuration: controlPlaneConfiguration))
            ])

        try bootstrapObservability(preparedObservability)

        // Track fire-and-forget background work (async VM operations) so shutdown
        // can drain it before Fluent closes its connection pools. Registered
        // before anything that can spawn work.
        setUpBackgroundTaskRegistry()

        // How far to trust `X-Forwarded-For`, shared by rate limiting, audit
        // `sourceIP`, and API-key `lastUsedIP` so one request resolves to one
        // address everywhere. Set before any middleware that reads it.
        proxyTrust = .fromConfiguration(controlPlaneConfiguration)

        configureSharedHTTPClientPolicy()
        configureRequestBodyLimit()
    }

    private func configureSharedHTTPClientPolicy() {
        // The shared HTTP client is for OPERATOR-CONFIGURED destinations only —
        // Loki, the audit/SSF forwarders, the SPIRE issuance-metrics endpoint, and
        // `AgentUpdateArtifacts`. Anything whose destination a tenant can influence
        // (image `sourceURL` fetches, OCI registry manifests and token realms,
        // webhook deliveries, OIDC discovery/token/userinfo/JWKS) goes through
        // `app.guardedHTTPClient`, which validates the host, pins the connection to
        // the address it approved, and refuses redirects. Reaching for `app.client`
        // or `app.http.client.shared` on a tenant-influenced fetch is the bug that
        // class of endpoint keeps reintroducing.
        //
        // Redirect-following is off here as a backstop: a 3xx from a validated host
        // would otherwise let the client silently follow it to an internal address
        // (cloud metadata, loopback, private services), defeating the check.
        // Callers that legitimately need redirects follow them explicitly:
        // `ImageFetchService` makes one guarded request per hop, and
        // `AgentUpdateArtifacts` follows the release host's CDN redirect by hand
        // (its base URL is operator-configured, never tenant-supplied, and carries
        // no credentials — that exemption is documented on `GuardedHTTPClient`).
        http.client.configuration.redirectConfiguration = .disallow
    }

    private func configureRequestBodyLimit() {
        // The ceiling on any request body Vapor collects into memory before a
        // handler sees it (STR-195). Vapor's default is 16 MB, which was the only
        // size bound in the entire persist path — no column is length-limited, so
        // 16 MB was the implicit contract of every endpoint, including `POST
        // /api/vms`.
        //
        // 1 MiB is chosen against the largest legitimate collected body: a VM
        // create carrying `CloudInitUserDataFormat.maxBytes` (64 KiB) of user data
        // plus a 4 KiB `cmdline` and its metadata, with an order of magnitude of
        // headroom for the JSON-heavy bodies (Cedar policy text, SCIM payloads)
        // that have no single large field but many.
        //
        // The three routes that legitimately carry gigabytes — image upload, image
        // artifact upload, and sandbox snapshot artifact transfer — are registered
        // with `body: .stream` and are unaffected: a streaming route never
        // collects, and each already enforces its own byte ceiling.
        routes.defaultMaxBodySize = "1mb"
    }
}
