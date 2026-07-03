import Foundation

public enum WebSocketURLs {
    /// Returns `urlString` with the value of its `token` query parameter replaced,
    /// or nil if the URL is unparseable or has no `token` parameter.
    ///
    /// Registration tokens are single-use: the control plane consumes the presented
    /// token on connect and returns a rotated one in the registration response, which
    /// must replace the token in the URL the reconnect loop dials.
    public static func replacingTokenQueryParameter(in urlString: String, with token: String) -> String? {
        guard var components = URLComponents(string: urlString),
              var items = components.queryItems,
              let index = items.firstIndex(where: { $0.name == "token" }) else {
            return nil
        }
        items[index].value = token
        components.queryItems = items
        return components.string
    }

    /// Builds the URL the agent dials when reconnecting from persisted state:
    /// the bare control-plane WebSocket URL plus `token` and `name` query
    /// parameters. Returns nil if `base` is unparseable.
    public static func registrationURL(base: String, token: String, name: String) -> String? {
        guard var components = URLComponents(string: base) else {
            return nil
        }
        var items = (components.queryItems ?? []).filter { $0.name != "token" && $0.name != "name" }
        items.append(URLQueryItem(name: "token", value: token))
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
