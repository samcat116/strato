import Foundation

/// Client side of the RFC 8628 device authorization grant.
public struct DeviceFlow: Sendable {
    public let serverURL: URL
    private let transport: any HTTPTransport
    /// Injectable so tests don't actually sleep.
    private let sleeper: @Sendable (_ seconds: Double) async throws -> Void

    public init(
        serverURL: URL,
        transport: any HTTPTransport = URLSessionTransport(),
        sleeper: @escaping @Sendable (_ seconds: Double) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.serverURL = serverURL
        self.transport = transport
        self.sleeper = sleeper
    }

    /// Starts the flow: the server mints a device/user code pair.
    public func start(clientName: String, scopes: String) async throws -> DeviceAuthorizationResponse {
        let request = TransportRequest(
            method: "POST",
            url: APIClient.url(baseURL: serverURL, path: "/oauth/device_authorization", query: []),
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: formEncode([
                ("client_name", clientName),
                ("scope", scopes),
            ])
        )
        let response = try await transport.send(request)
        guard response.statusCode == 200 else {
            throw CLIError.api(
                status: response.statusCode, message: APIClient.errorMessage(from: response.body))
        }
        return try APIClient.jsonDecoder().decode(DeviceAuthorizationResponse.self, from: response.body)
    }

    /// Polls the token endpoint until the user approves, denies, or the code
    /// expires. Honors the server's interval, backing off 5 extra seconds on
    /// `slow_down` per RFC 8628 §3.5.
    public func pollForToken(_ authorization: DeviceAuthorizationResponse) async throws -> TokenResponse {
        var interval = Double(authorization.interval ?? 5)
        let deadline = Date().addingTimeInterval(TimeInterval(authorization.expiresIn))

        while Date() < deadline {
            try await sleeper(interval)

            let request = TransportRequest(
                method: "POST",
                url: APIClient.url(baseURL: serverURL, path: "/oauth/token", query: []),
                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                body: formEncode([
                    ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
                    ("device_code", authorization.deviceCode),
                ])
            )
            let response = try await transport.send(request)

            if response.statusCode == 200 {
                return try APIClient.jsonDecoder().decode(TokenResponse.self, from: response.body)
            }

            let error = try? APIClient.jsonDecoder().decode(OAuthErrorBody.self, from: response.body)
            switch error?.error {
            case "authorization_pending":
                continue
            case "slow_down":
                interval += 5
            case "access_denied":
                throw CLIError.notLoggedIn("The sign-in request was denied in the browser.")
            case "expired_token":
                throw CLIError.timedOut("The sign-in code expired before it was approved. Try again.")
            default:
                throw CLIError.api(
                    status: response.statusCode, message: APIClient.errorMessage(from: response.body))
            }
        }

        throw CLIError.timedOut("Timed out waiting for browser approval. Try again.")
    }

    /// Best-effort server-side revocation (RFC 7009) used by `strato logout`.
    public func revoke(token: String) async throws {
        let request = TransportRequest(
            method: "POST",
            url: APIClient.url(baseURL: serverURL, path: "/oauth/revoke", query: []),
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: formEncode([("token", token)])
        )
        _ = try await transport.send(request)
    }
}
