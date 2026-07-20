import Foundation
import Testing

@testable import StratoCLICore

@Suite("DeviceFlow")
struct DeviceFlowTests {
    let serverURL = URL(string: "https://strato.example.com")!

    private func authorization(expiresIn: Int = 300, interval: Int = 5) -> DeviceAuthorizationResponse {
        DeviceAuthorizationResponse(
            deviceCode: "dc_test", userCode: "BCDF-GHJK",
            verificationUri: "https://strato.example.com/activate",
            verificationUriComplete: "https://strato.example.com/activate?code=BCDF-GHJK",
            expiresIn: expiresIn, interval: interval)
    }

    @Test("start posts a form-encoded request and decodes the response")
    func testStart() async throws {
        let transport = MockTransport(responses: [
            .init(
                statusCode: 200,
                json: """
                    {"device_code": "dc_abc", "user_code": "BCDF-GHJK",
                     "verification_uri": "https://strato.example.com/activate",
                     "verification_uri_complete": "https://strato.example.com/activate?code=BCDF-GHJK",
                     "expires_in": 900, "interval": 5}
                    """)
        ])
        let flow = DeviceFlow(serverURL: serverURL, transport: transport, sleeper: { _ in })

        let response = try await flow.start(clientName: "test host", scopes: "read write")
        #expect(response.deviceCode == "dc_abc")
        #expect(response.userCode == "BCDF-GHJK")
        #expect(response.interval == 5)

        let request = try #require(transport.recordedRequests.first)
        #expect(request.url.path == "/oauth/device_authorization")
        #expect(request.headers["Content-Type"] == "application/x-www-form-urlencoded")
        let body = String(decoding: try #require(request.body), as: UTF8.self)
        #expect(body.contains("client_name=test%20host"))
        #expect(body.contains("scope=read%20write"))
    }

    @Test("poll rides out pending and slow_down, then succeeds")
    func testPollStateMachine() async throws {
        let pendingBody = #"{"error": "authorization_pending"}"#
        let slowDownBody = #"{"error": "slow_down"}"#
        let tokenBody = """
            {"access_token": "st_abc", "token_type": "Bearer", "expires_in": 3600,
             "refresh_token": "rt_abc", "scope": "read write"}
            """
        let transport = MockTransport(responses: [
            .init(statusCode: 400, json: pendingBody),
            .init(statusCode: 400, json: slowDownBody),
            .init(statusCode: 400, json: pendingBody),
            .init(statusCode: 200, json: tokenBody),
        ])

        let sleeps = Sleeps()
        let flow = DeviceFlow(
            serverURL: serverURL, transport: transport,
            sleeper: { seconds in await sleeps.record(seconds) })

        let token = try await flow.pollForToken(authorization())
        #expect(token.accessToken == "st_abc")
        #expect(token.refreshToken == "rt_abc")

        // slow_down after the second poll bumps every later wait by 5s.
        let recorded = await sleeps.values
        #expect(recorded == [5, 5, 10, 10])
    }

    @Test("access_denied and expired_token abort the poll")
    func testPollAborts() async throws {
        let denied = MockTransport(responses: [.init(statusCode: 400, json: #"{"error": "access_denied"}"#)])
        let deniedFlow = DeviceFlow(serverURL: serverURL, transport: denied, sleeper: { _ in })
        await #expect(throws: CLIError.self) {
            try await deniedFlow.pollForToken(authorization())
        }

        let expired = MockTransport(responses: [.init(statusCode: 400, json: #"{"error": "expired_token"}"#)])
        let expiredFlow = DeviceFlow(serverURL: serverURL, transport: expired, sleeper: { _ in })
        await #expect(throws: CLIError.self) {
            try await expiredFlow.pollForToken(authorization())
        }
    }

    @Test("polling stops when the code's lifetime runs out")
    func testPollDeadline() async throws {
        // Every response is pending; the deadline (0s) exits immediately.
        let transport = MockTransport(responses: [])
        let flow = DeviceFlow(serverURL: serverURL, transport: transport, sleeper: { _ in })
        await #expect(throws: CLIError.self) {
            try await flow.pollForToken(authorization(expiresIn: 0))
        }
        #expect(transport.recordedRequests.isEmpty)
    }
}

private actor Sleeps {
    private(set) var values: [Double] = []
    func record(_ seconds: Double) {
        values.append(seconds)
    }
}
