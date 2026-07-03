import Foundation

public enum WebSocketURLs {
    /// Removes the `token` query parameter from `urlString`, returning the token-free
    /// URL together with the extracted token value.
    ///
    /// Registration tokens must not travel in the request URL: even over TLS the
    /// plaintext token lands in proxy/ingress/load-balancer access logs and any
    /// intermediary that records URLs. The agent instead dials the returned token-free
    /// URL and presents the token in an `Authorization: Bearer` header.
    ///
    /// Returns nil if the URL is unparseable or has no `token` parameter.
    public static func extractingToken(from urlString: String) -> (url: String, token: String)? {
        guard var components = URLComponents(string: urlString),
              var items = components.queryItems,
              let index = items.firstIndex(where: { $0.name == "token" }),
              let token = items[index].value else {
            return nil
        }
        items.remove(at: index)
        // Drop the query entirely if `token` was the only parameter, so the dialed
        // URL doesn't carry a dangling `?`.
        components.queryItems = items.isEmpty ? nil : items
        guard let stripped = components.string else {
            return nil
        }
        return (stripped, token)
    }
}
