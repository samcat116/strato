import Vapor

extension Request {
    /// The authenticated user, or a 401.
    ///
    /// The policy-set controllers — roles, policies, guardrails — gate on a
    /// user and *then* run their own permission checks, and each carried an
    /// identical private copy of this. One definition instead: "who is asking"
    /// is the same question everywhere; what is done with the answer is what
    /// differs per route.
    func requireUser() throws -> User {
        guard let user = auth.get(User.self) else { throw Abort(.unauthorized) }
        return user
    }
}
