import Foundation
import Testing
import Vapor

@testable import App

@Suite("Control-plane configuration")
struct ControlPlaneConfigurationTests {
    @Test("Malformed values fail with the setting name and accepted input")
    func malformedValueIsActionable() async {
        do {
            _ = try await ControlPlaneConfiguration.load(
                environmentVariables: ["HTTP_TLS_ENABLED": "definitely"],
                for: .testing)
            Issue.record("Expected malformed HTTP_TLS_ENABLED to fail configuration")
        } catch let error as ControlPlaneConfigurationError {
            #expect(error.description.contains("HTTP_TLS_ENABLED"))
            #expect(error.description.contains("definitely"))
            #expect(error.description.contains("true, false, yes, no, 1, 0"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Malformed and out-of-range integers fail instead of defaulting")
    func invalidIntegersAreRejected() async {
        for raw in ["2x", "0", "65536"] {
            await #expect(throws: ControlPlaneConfigurationError.self) {
                _ = try await ControlPlaneConfiguration.load(
                    environmentVariables: ["DATABASE_PORT": raw],
                    for: .testing)
            }
        }
    }

    @Test("Unknown enum values fail instead of selecting a default")
    func invalidEnumIsRejected() async {
        await #expect(throws: ControlPlaneConfigurationError.self) {
            _ = try await ControlPlaneConfiguration.load(
                environmentVariables: ["SCHEDULING_STRATEGY": "bestfit"],
                for: .testing)
        }
    }

    @Test("Explicit strings remain distinguishable from loader defaults")
    func explicitStringsRemainDistinguishable() async throws {
        let defaulted = try await ControlPlaneConfiguration.load(
            environmentVariables: [:], for: .testing)
        #expect(defaulted.string(.webauthnRelyingPartyOrigin) == "http://localhost:8080")
        #expect(defaulted.explicitlyConfiguredString(.webauthnRelyingPartyOrigin) == nil)

        let configured = try await ControlPlaneConfiguration.load(
            environmentVariables: [
                "WEBAUTHN_RELYING_PARTY_ORIGIN": "https://identity.example.com"
            ],
            for: .testing)
        #expect(
            configured.explicitlyConfiguredString(.webauthnRelyingPartyOrigin)
                == "https://identity.example.com")
    }

    @Test("OAuth keeps its frontend fallback until an origin is explicitly configured")
    func oauthFrontendFallbackUsesExplicitOrigins() async throws {
        let defaulted = try await ControlPlaneConfiguration.load(
            environmentVariables: [:], for: .testing)
        #expect(OAuthController.publicOrigin(configuration: defaulted) == "http://localhost:3000")

        let webauthn = try await ControlPlaneConfiguration.load(
            environmentVariables: [
                "WEBAUTHN_RELYING_PARTY_ORIGIN": "https://identity.example.com/"
            ],
            for: .testing)
        #expect(OAuthController.publicOrigin(configuration: webauthn) == "https://identity.example.com")

        let publicURL = try await ControlPlaneConfiguration.load(
            environmentVariables: [
                "STRATO_PUBLIC_URL": "https://strato.example.com/",
                "WEBAUTHN_RELYING_PARTY_ORIGIN": "https://identity.example.com",
            ],
            for: .testing)
        #expect(OAuthController.publicOrigin(configuration: publicURL) == "https://strato.example.com")
    }

    @Test("SSF push delivery requires an explicitly configured callback origin")
    func ssfPushEndpointUsesExplicitOrigins() async throws {
        let streamID = UUID(uuidString: "6AD6BE4A-599A-4FE4-B862-DB06994B7075")!
        let defaulted = try await ControlPlaneConfiguration.load(
            environmentVariables: [:], for: .testing)
        #expect(
            SSFService.pushEndpointURL(for: streamID, configuration: defaulted) == nil)

        let webauthn = try await ControlPlaneConfiguration.load(
            environmentVariables: [
                "WEBAUTHN_RELYING_PARTY_ORIGIN": "https://identity.example.com/"
            ],
            for: .testing)
        #expect(
            SSFService.pushEndpointURL(for: streamID, configuration: webauthn)
                == "https://identity.example.com/ssf/events/\(streamID.uuidString)")

        let callback = try await ControlPlaneConfiguration.load(
            environmentVariables: [
                "SSF_CALLBACK_BASE_URL": "https://signals.example.com/",
                "WEBAUTHN_RELYING_PARTY_ORIGIN": "https://identity.example.com",
            ],
            for: .testing)
        #expect(
            SSFService.pushEndpointURL(for: streamID, configuration: callback)
                == "https://signals.example.com/ssf/events/\(streamID.uuidString)")
    }

    @Test("The registry contains every typed key exactly once")
    func registryIsComplete() {
        let entries = ControlPlaneConfiguration.registry(for: .production)
        let names = entries.map(\.name)
        let expected =
            ControlPlaneBoolKey.allCases.map(\.rawValue)
            + ControlPlaneIntKey.allCases.map(\.rawValue)
            + ControlPlaneDoubleKey.allCases.map(\.rawValue)
            + ControlPlaneStringKey.allCases.map(\.rawValue)

        #expect(Set(names).count == names.count)
        #expect(Set(names) == Set(expected))
    }
}
