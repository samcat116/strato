import Logging
import NIOCore
import NIOPosix
import OTel
// Terminal / ConsoleLogger below come from ConsoleKit, which Vapor re-exports;
// it is not a direct dependency of this target.
import Vapor

@main
enum Entrypoint {
    static func main() async throws {
        var env = try Environment.detect()

        // Vapor's own `LoggingSystem.bootstrap(from:)` is this, minus the
        // metadata provider — it is re-spelled here only to attach one.
        //
        // The provider stamps `trace_id` / `span_id` / `trace_flags` onto every
        // line logged inside a span, which is what makes a log line
        // addressable from its trace (and vice versa: Grafana's Loki
        // datasource extracts `trace_id` from the rendered metadata and links
        // it to Tempo). Without it the two signals can only be correlated by
        // pod and timestamp.
        //
        // Safe to install unconditionally: it reads `ServiceContext.current`
        // and returns no metadata when there is no active span — which is the
        // case for all logging before OTel bootstraps in `configure`, and for
        // every deployment that leaves tracing disabled.
        let metadataProvider = OTel.makeLoggingMetadataProvider()
        try LoggingSystem.bootstrap(from: &env) { level in
            let console = Terminal()
            return { (label: String) in
                ConsoleLogger(
                    label: label,
                    console: console,
                    level: level,
                    metadataProvider: metadataProvider
                )
            }
        }

        let app = try await Application.make(env)

        // This attempts to install NIO as the Swift Concurrency global executor.
        // You can enable it if you'd like to reduce the amount of context switching between NIO and Swift Concurrency.
        // Note: this has caused issues with some libraries that use `.wait()` and cleanly shutting down.
        // If enabled, you should be careful about calling async functions before this point as it can cause assertion failures.
        // let executorTakeoverSuccess = NIOSingletons.unsafeTryInstallSingletonPosixEventLoopGroupAsConcurrencyGlobalExecutor()
        // app.logger.debug("Tried to install SwiftNIO's EventLoopGroup as Swift's global concurrency executor", metadata: ["success": .stringConvertible(executorTakeoverSuccess)])

        do {
            try await configure(app)
        } catch {
            app.logger.report(error: error)
            try? await app.asyncShutdown()
            throw error
        }
        try await app.execute()
        try await app.asyncShutdown()
    }
}
