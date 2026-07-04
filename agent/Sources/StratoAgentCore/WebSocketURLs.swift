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

    /// Builds the URL the agent dials when reconnecting from persisted state:
    /// the bare control-plane WebSocket URL plus the `name` query parameter.
    /// The reconnect token is deliberately NOT part of the URL — it travels in
    /// the Authorization header. Returns nil if `base` is unparseable.
    public static func appendingNameQueryParameter(to base: String, name: String) -> String? {
        guard var components = URLComponents(string: base) else {
            return nil
        }
        var items = (components.queryItems ?? []).filter { $0.name != "name" }
        items.append(URLQueryItem(name: "name", value: name))
        components.queryItems = items
        return components.string
    }

    /// Returns `urlString` stripped of its query, for persisting as the bare
    /// control-plane URL (tokens must not be stored inside the URL).
    public static func removingQuery(from urlString: String) -> String? {
        guard var components = URLComponents(string: urlString) else {
            return nil
        }
        components.queryItems = nil
        components.query = nil
        return components.string
    }
}
