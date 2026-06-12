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
}
