import Vapor

extension Route {
    /// Declare only routes whose every successful mutation path reserves and
    /// completes a principal-scoped claim in the mutation's transaction.
    /// Credential/session minting and partially participating handlers must
    /// stay unmarked. See docs/architecture/idempotency.md for the inventory.
    @discardableResult
    func supportsIdempotency() -> Route {
        precondition(IdempotencyMiddleware.isMutation(method))
        userInfo["strato.idempotency.supported"] = true
        return self
    }

    var isIdempotencySupported: Bool {
        userInfo["strato.idempotency.supported"] as? Bool == true
    }
}
