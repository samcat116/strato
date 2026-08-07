import Foundation
import OpenAPIRuntime
import StratoAPIClient

/// Client side of the RFC 8628 device authorization grant.
///
/// Runs against a client without the error-mapping middleware: the whole
/// polling state machine is driven by the machine-readable OAuth code in a
/// `400` body, so those responses have to arrive intact.
public struct DeviceFlow: Sendable {
    private let client: any APIProtocol
    /// Injectable so tests don't actually sleep.
    private let sleeper: @Sendable (_ seconds: Double) async throws -> Void

    public init(
        serverURL: URL,
        transport: any ClientTransport = URLSessionClientTransport(),
        sleeper: @escaping @Sendable (_ seconds: Double) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.init(
            client: StratoClient.publicEndpoints(serverURL: serverURL, transport: transport),
            sleeper: sleeper)
    }

    public init(
        client: any APIProtocol,
        sleeper: @escaping @Sendable (_ seconds: Double) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.client = client
        self.sleeper = sleeper
    }

    /// Starts the flow: the server mints a device/user code pair.
    ///
    /// - Parameter restriction: what this session is asking to be able to do
    ///   (STR-115). A request, not a grant — the approving browser shows it and
    ///   may narrow it further. A restriction is a nested object, so it goes
    ///   over JSON; without one the form encoding stays, since the endpoint
    ///   accepts both and the form shape is what RFC 8628 clients expect.
    public func start(
        clientName: String,
        scopes: String,
        restriction: Components.Schemas.CredentialRestriction? = nil
    ) async throws -> Components.Schemas.DeviceAuthorizationResponse {
        let body: Operations.OauthDeviceAuthorization.Input.Body =
            restriction == nil
            ? .urlEncodedForm(.init(clientName: clientName, scope: scopes))
            : .json(.init(clientName: clientName, scope: scopes, restriction: restriction))
        let output = try await client.oauthDeviceAuthorization(body: body)
        switch output {
        case .ok(let ok):
            return try ok.body.json
        case .badRequest(let badRequest):
            throw CLIError.api(status: 400, message: Self.message(for: try badRequest.body.json))
        case .undocumented(let statusCode, _):
            throw CLIError.api(status: statusCode, message: "Could not start sign-in.")
        }
    }

    /// Polls the token endpoint until the user approves, denies, or the code
    /// expires. Honors the server's interval, backing off 5 extra seconds on
    /// `slow_down` per RFC 8628 §3.5.
    public func pollForToken(
        _ authorization: Components.Schemas.DeviceAuthorizationResponse
    ) async throws -> Components.Schemas.OAuthTokenResponse {
        var interval = Double(authorization.interval)
        let deadline = Date().addingTimeInterval(TimeInterval(authorization.expiresIn))

        while Date() < deadline {
            try await sleeper(interval)

            let output = try await client.oauthToken(
                body: .urlEncodedForm(
                    .init(
                        // The generated case name for
                        // `urn:ietf:params:oauth:grant-type:device_code`.
                        grantType: .urn_colon_ietf_colon_params_colon_oauth_colon_grantType_colon_deviceCode,
                        deviceCode: authorization.deviceCode)))

            switch output {
            case .ok(let ok):
                return try ok.body.json
            case .badRequest(let badRequest):
                let error = try badRequest.body.json
                switch error.error {
                case .authorizationPending:
                    continue
                case .slowDown:
                    interval += 5
                case .accessDenied:
                    throw CLIError.notLoggedIn("The sign-in request was denied in the browser.")
                case .expiredToken:
                    throw CLIError.timedOut("The sign-in code expired before it was approved. Try again.")
                default:
                    throw CLIError.api(status: 400, message: Self.message(for: error))
                }
            case .undocumented(let statusCode, _):
                throw CLIError.api(status: statusCode, message: "Could not complete sign-in.")
            }
        }

        throw CLIError.timedOut("Timed out waiting for browser approval. Try again.")
    }

    /// Best-effort server-side revocation (RFC 7009) used by `strato logout`.
    public func revoke(token: String) async throws {
        _ = try await client.oauthRevoke(body: .urlEncodedForm(.init(token: token)))
    }

    private static func message(for error: Components.Schemas.OAuthErrorResponse) -> String {
        error.errorDescription ?? error.error.rawValue
    }
}
