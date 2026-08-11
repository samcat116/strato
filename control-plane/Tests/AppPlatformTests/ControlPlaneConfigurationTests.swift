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
