import Foundation
import Logging
import Testing
import Vapor

@testable import App

@Suite("Observability bootstrap")
struct ObservabilityBootstrapTests {
    @Test("Required signal combinations select backends without global bootstrap")
    func signalConfigurationMatrix() async throws {
        let cases = [
            SignalCase(metrics: true, logs: false, traces: false),
            SignalCase(metrics: false, logs: false, traces: true),
            SignalCase(metrics: false, logs: true, traces: false),
            SignalCase(metrics: true, logs: true, traces: true),
        ]

        for signalCase in cases {
            let configuration = try await ControlPlaneConfiguration.load(
                environmentVariables: signalCase.environment,
                for: .production)
            let plan = ObservabilityBootstrap.plan(for: configuration)
            let otel = ObservabilityBootstrap.makeOTelConfiguration(
                controlPlaneConfiguration: configuration,
                environment: .production,
                replicaID: "test-replica")

            #expect(plan.metricsEnabled == signalCase.metrics)
            #expect(plan.logsEnabled == signalCase.logs)
            #expect(plan.tracesEnabled == signalCase.traces)
            #expect(plan.logSinks == (signalCase.logs ? [.console, .otlp] : [.console]))
            #expect(otel.metrics.enabled == signalCase.metrics)
            #expect(otel.logs.enabled == signalCase.logs)
            #expect(otel.traces.enabled == signalCase.traces)
        }
    }

    @Test("Logs-disabled selection emits to the console handler only")
    func consoleOnlyHandler() {
        let console = LogRecorder()
        let handler = ObservabilityBootstrap.composeLogHandlers(
            console: RecordingLogHandler(recorder: console),
            otel: nil)

        handler.log(event: Self.testEvent)

        #expect(console.messages == ["startup"])
    }

    @Test("Logs-enabled selection emits to console and OTLP handlers")
    func multiplexedHandler() {
        let console = LogRecorder()
        let otlp = LogRecorder()
        let handler = ObservabilityBootstrap.composeLogHandlers(
            console: RecordingLogHandler(recorder: console),
            otel: RecordingLogHandler(recorder: otlp))

        handler.log(event: Self.testEvent)

        #expect(handler is MultiplexLogHandler)
        #expect(console.messages == ["startup"])
        #expect(otlp.messages == ["startup"])
    }

    private static let testEvent = LogEvent(
        level: .info,
        message: "startup",
        metadata: nil,
        source: "App",
        file: #fileID,
        function: #function,
        line: #line)
}

private struct SignalCase {
    let metrics: Bool
    let logs: Bool
    let traces: Bool

    var environment: [String: String] {
        [
            "OTEL_METRICS_ENABLED": String(metrics),
            "OTEL_LOGS_ENABLED": String(logs),
            "OTEL_TRACES_ENABLED": String(traces),
        ]
    }
}

private struct RecordingLogHandler: LogHandler {
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace
    let recorder: LogRecorder

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        recorder.append(event.message.description)
    }
}

private final class LogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedMessages: [String] = []

    var messages: [String] {
        lock.withLock { recordedMessages }
    }

    func append(_ message: String) {
        lock.withLock { recordedMessages.append(message) }
    }
}
