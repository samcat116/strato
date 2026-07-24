import Vapor

/// Offset pagination for resource list endpoints (issue #700).
///
/// Every list endpoint pages by default: `limit` (default 50, max 500) and
/// `offset` (default 0) query parameters select the slice, and the response is
/// always a `PagedResponse` envelope. The page is sliced *after* authorization
/// filtering, so `total` counts the rows the caller is allowed to see —
/// SQL-level LIMIT/OFFSET can't compose with the in-memory `canFilter` scoping
/// and would return short pages.
struct ListPaging: Sendable {
    let limit: Int
    let offset: Int

    static let defaultLimit = 50
    static let maxLimit = 500

    /// Decodes `limit`/`offset` from the request, clamping to sane bounds.
    /// Non-integer values are a 400, not a silent fallback.
    static func decode(from req: Request) throws -> ListPaging {
        ListPaging(
            limit: min(max(try intQuery(req, "limit") ?? defaultLimit, 1), maxLimit),
            offset: max(try intQuery(req, "offset") ?? 0, 0)
        )
    }

    private static func intQuery(_ req: Request, _ name: String) throws -> Int? {
        guard let raw = req.query[String.self, at: name] else { return nil }
        guard let value = Int(raw) else {
            throw Abort(.badRequest, reason: "Query parameter '\(name)' must be an integer")
        }
        return value
    }

    /// Wraps an already authorization-filtered, deterministically ordered list
    /// in the envelope, echoing the clamped limit/offset actually applied.
    func page<Item: Content & Sendable>(_ items: [Item]) -> PagedResponse<Item> {
        let slice: [Item]
        if offset < items.count {
            slice = Array(items[offset..<min(offset + limit, items.count)])
        } else {
            slice = []
        }
        return PagedResponse(items: slice, total: items.count, limit: limit, offset: offset)
    }
}

/// The paged envelope: the requested slice plus the post-authorization total.
struct PagedResponse<Item: Content & Sendable>: Content {
    let items: [Item]
    let total: Int
    let limit: Int
    let offset: Int
}
