import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix

/// Shared transport for the two local SPIRE agent APIs this module speaks: the
/// SPIFFE Workload API (`WorkloadAPIClient`) and the Delegated Identity API
/// (`DelegatedIdentityClient`). Both are plaintext gRPC over a Unix domain
/// socket the SPIRE agent owns — the socket's filesystem permissions are the
/// access control, which is why there is no TLS here to configure.
enum SPIFFEUnixGRPC {
    /// Run `body` against a gRPC client connected to `socketPath`, tearing the
    /// connection down when it returns.
    ///
    /// Connections are per-call rather than pooled: these RPCs are either
    /// one-shot fetches or long-lived subscriptions, and scoping the transport
    /// to the call means a broken stream cannot leave a half-dead connection
    /// behind for the next caller to trip over.
    static func withClient<Result: Sendable>(
        socketPath: String,
        _ body: @Sendable @escaping (GRPCClient<HTTP2ClientTransport.Posix>) async throws -> Result
    ) async throws -> Result {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw SPIFFEError.workloadAPIUnavailable("Socket not found: \(socketPath)")
        }

        let transport: HTTP2ClientTransport.Posix
        do {
            transport = try HTTP2ClientTransport.Posix(
                target: .unixDomainSocket(path: socketPath),
                transportSecurity: .plaintext
            )
        } catch {
            throw SPIFFEError.connectionFailed("Failed to create SPIRE agent transport: \(error)")
        }

        return try await withGRPCClient(transport: transport) { client in
            try await body(client)
        }
    }
}
