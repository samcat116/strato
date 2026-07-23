import Fluent
import NIOConcurrencyHelpers
import Vapor

// Issue #686: the request-scoped authorization cache.
//
// A single check used to cost ~7 sequential queries and nothing was reused,
// even within one request — so an object route that checks in the middleware
// and re-checks in the handler (the deliberate defense-in-depth of
// `Request.authorizedVM`) paid for two full evaluations, two entity slices and
// two decision-log rows to answer the same question twice.
//
// Everything cached here is immutable for the life of a request by
// construction: the caller's group and organization memberships, the resource
// tree above a node, and the verdict for one `(principal, action, node)`
// triple. A mutation landing mid-request cannot make a decision already made
// wrong — the request was authorized against the state it read.

/// The per-principal facts every check in a request needs: the memberships the
/// tier-1 policies read and the groups whose bindings count as the principal's.
///
/// Loaded once per user per request. Machine principals have none by design —
/// the schema declares them memberships-less, so their grants are exactly their
/// own bindings.
struct IAMUserFacts: Sendable, Equatable {
    let isSystemAdmin: Bool
    let groupIDs: [UUID]
    let organizationIDs: [UUID]

    /// The memberships-less principal: machine principals, and a user id with
    /// no row behind it.
    static let none = IAMUserFacts(isSystemAdmin: false, groupIDs: [], organizationIDs: [])

    /// Load the facts for `userID`, answering from `cache` when it holds them.
    ///
    /// - Parameter cache: nil outside a request (background sweeps, tests),
    ///   which simply loads every time.
    static func load(
        userID: UUID, cache: IAMRequestCache?, on db: any Database
    ) async throws -> IAMUserFacts {
        if let cached = cache?.userFacts(userID) { return cached }
        let facts = try await load(userID: userID, seededUser: cache?.seededUser(userID), on: db)
        cache?.store(userFacts: facts, for: userID)
        return facts
    }

    /// The three loads are independent, so they go out together. `seededUser`
    /// is the authenticated `User` the request already has in `req.auth`:
    /// having it saves the redundant re-read of the row the session
    /// authenticated with.
    private static func load(
        userID: UUID, seededUser: User?, on db: any Database
    ) async throws -> IAMUserFacts {
        async let groups = UserGroup.query(on: db)
            .filter(\.$user.$id == userID)
            .all()
            .map { $0.$group.id }
        async let organizations = UserOrganization.query(on: db)
            .filter(\.$user.$id == userID)
            .all()
            .map { $0.$organization.id }

        let isSystemAdmin: Bool
        if let seededUser {
            isSystemAdmin = seededUser.isSystemAdmin
        } else {
            isSystemAdmin = try await User.find(userID, on: db)?.isSystemAdmin ?? false
        }
        return IAMUserFacts(
            isSystemAdmin: isSystemAdmin,
            groupIDs: try await groups,
            organizationIDs: try await organizations)
    }
}

/// A memo of the authorization work one request has already done.
///
/// Deliberately a dumb store: it holds values and never loads anything, so
/// there is exactly one code path that reads the database for each kind of
/// fact (`IAMUserFacts.load`, `IAMResourceTree.resolve`, the authorizer's
/// evaluation) and the cache cannot drift from it.
final class IAMRequestCache: Sendable {
    /// The identity of a decided check. Two checks with the same triple in one
    /// request are the same question — the middleware's and the handler's, for
    /// the object routes that deliberately ask twice.
    struct DecisionKey: Hashable, Sendable {
        let principal: IAMPrincipal
        let action: String
        let node: IAMNode
    }

    private struct State {
        var seededUsers: [UUID: User] = [:]
        var userFacts: [UUID: IAMUserFacts] = [:]
        var chains: [IAMNode: IAMResourceTree.Resolution] = [:]
        var decisions: [DecisionKey: CedarCheckDecision] = [:]
    }

    private let state = NIOLockedValueBox(State())

    init() {}

    /// Offer an already-loaded `User` row (the authenticated one) so the facts
    /// load need not re-read it.
    func seed(user: User) {
        guard let id = user.id else { return }
        state.withLockedValue { $0.seededUsers[id] = user }
    }

    func seededUser(_ userID: UUID) -> User? {
        state.withLockedValue { $0.seededUsers[userID] }
    }

    func userFacts(_ userID: UUID) -> IAMUserFacts? {
        state.withLockedValue { $0.userFacts[userID] }
    }

    func store(userFacts: IAMUserFacts, for userID: UUID) {
        state.withLockedValue { $0.userFacts[userID] = userFacts }
    }

    func chain(of node: IAMNode) -> IAMResourceTree.Resolution? {
        state.withLockedValue { $0.chains[node] }
    }

    func store(chain: IAMResourceTree.Resolution, of node: IAMNode) {
        state.withLockedValue { $0.chains[node] = chain }
    }

    func decision(for key: DecisionKey) -> CedarCheckDecision? {
        state.withLockedValue { $0.decisions[key] }
    }

    func store(decision: CedarCheckDecision, for key: DecisionKey) {
        state.withLockedValue { $0.decisions[key] = decision }
    }
}

extension Request {
    private struct IAMRequestCacheKey: StorageKey {
        typealias Value = IAMRequestCache
    }

    /// This request's authorization cache, created on first use and seeded
    /// with the authenticated user when there is one.
    var iamCache: IAMRequestCache {
        if let existing = storage[IAMRequestCacheKey.self] { return existing }
        let created = IAMRequestCache()
        if let user = auth.get(User.self) { created.seed(user: user) }
        storage[IAMRequestCacheKey.self] = created
        return created
    }
}
