import Foundation
import OpenAPIRuntime
import StratoAPIClient

/// The server-side page-size cap (`ListLimitQuery`). List commands request one
/// max-size page; per-command `--limit`/`--offset` flags are follow-up work.
public let listPageLimit = 500

/// Builds the generated `StratoAPIClient` clients the CLI talks to.
///
/// There are no hand-written request paths or DTOs left: every call site uses
/// a generated operation against `Components.Schemas.*`, so a breaking change
/// to the control plane's `openapi.yaml` is a CLI compile error.
public enum StratoClient {
    /// The generated HTTP client and the credential actor that signs it. A
    /// streaming caller uses the same actor for its WebSocket upgrade so token
    /// rotation cannot race between the mint and attach halves.
    public struct AuthenticatedSession: Sendable {
        public let client: StratoAPIClient.Client
        public let credentials: CredentialSession
    }

    /// A client for one context: signs each request with the context's stored
    /// access token, rotates the pair once on a 401 and replays, and raises a
    /// `CLIError` for any other non-2xx response.
    ///
    /// - Important: because every non-2xx response is raised as an error before
    ///   the generated code decodes it, the failure cases of an operation's
    ///   `Output` — `.badRequest`, `.notFound`, `.forbidden`, and the rest — are
    ///   unreachable through this client. That is what lets a call site read
    ///   `.ok`/`.accepted` directly; a `switch` written over those cases would
    ///   silently never fire. Catch `CLIError.api` and read its `status`
    ///   instead.
    public static func authenticated(
        serverURL: URL,
        contextName: String,
        credentialStore: CredentialStore,
        transport: any ClientTransport = URLSessionClientTransport()
    ) -> StratoAPIClient.Client {
        authenticatedSession(
            serverURL: serverURL, contextName: contextName,
            credentialStore: credentialStore, transport: transport
        ).client
    }

    public static func authenticatedSession(
        serverURL: URL,
        contextName: String,
        credentialStore: CredentialStore,
        transport: any ClientTransport = URLSessionClientTransport()
    ) -> AuthenticatedSession {
        let session = CredentialSession(
            contextName: contextName,
            store: credentialStore,
            tokenEndpoint: publicEndpoints(serverURL: serverURL, transport: transport)
        )
        let client = StratoAPIClient.Client(
            serverURL: serverURL,
            transport: transport,
            // Outermost first: the authentication middleware has to see a 401
            // and retry before the error mapper turns it into a thrown error.
            middlewares: [ErrorMappingMiddleware(), AuthenticationMiddleware(session: session)]
        )
        return AuthenticatedSession(client: client, credentials: session)
    }

    /// A client for the endpoints that declare `security: []` — the `/oauth/*`
    /// device flow and token rotation. No error mapping: those callers
    /// dispatch on the machine-readable OAuth code in a 400 body.
    public static func publicEndpoints(
        serverURL: URL,
        transport: any ClientTransport = URLSessionClientTransport()
    ) -> StratoAPIClient.Client {
        StratoAPIClient.Client(serverURL: serverURL, transport: transport)
    }
}
