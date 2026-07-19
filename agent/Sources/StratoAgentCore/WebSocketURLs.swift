import Foundation

public enum WebSocketURLs {
    /// Builds the URL the agent dials: the configured control-plane WebSocket
    /// URL plus the `name` query parameter. The URL carries no credential —
    /// the agent authenticates with its SPIFFE X.509 SVID over mTLS.
    /// Returns nil if `base` is unparseable.
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
    /// control-plane URL.
    public static func removingQuery(from urlString: String) -> String? {
        guard var components = URLComponents(string: urlString) else {
            return nil
        }
        components.queryItems = nil
        components.query = nil
        return components.string
    }
}
