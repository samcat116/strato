import Foundation
import NIOCore
import NIOPosix
import Vapor

@main
enum Entrypoint {
    static func main() async throws {
        var env = try Environment.detect()
        let environmentVariables = ProcessInfo.processInfo.environment
        let controlPlaneConfiguration = try await ControlPlaneConfiguration.load(
            environmentVariables: environmentVariables,
            for: env)
        let replicaID = UUID().uuidString
        let observability = try PreparedControlPlaneObservability.prepare(
            controlPlaneConfiguration: controlPlaneConfiguration,
            environment: env,
            replicaID: replicaID)

        // Application.make constructs the logger retained by Vapor, so the one
        // process-global logging decision must happen first. It always includes
        // the console and adds the OTLP handler when configured.
        try observability.bootstrapLogging(from: &env)

        let app = try await Application.make(env)
        app.replicaID = replicaID

        // This attempts to install NIO as the Swift Concurrency global executor.
        // You can enable it if you'd like to reduce the amount of context switching between NIO and Swift Concurrency.
        // Note: this has caused issues with some libraries that use `.wait()` and cleanly shutting down.
        // If enabled, you should be careful about calling async functions before this point as it can cause assertion failures.
        // let executorTakeoverSuccess = NIOSingletons.unsafeTryInstallSingletonPosixEventLoopGroupAsConcurrencyGlobalExecutor()
        // app.logger.debug("Tried to install SwiftNIO's EventLoopGroup as Swift's global concurrency executor", metadata: ["success": .stringConvertible(executorTakeoverSuccess)])

        do {
            try await configure(
                app,
                resolvedConfiguration: controlPlaneConfiguration,
                preparedObservability: observability)
        } catch {
            app.logger.report(error: error)
            try? await app.asyncShutdown()
            throw error
        }
        try await app.execute()
        try await app.asyncShutdown()
    }
}
