import Valkey

/// Process-local cache of script digests loaded into Valkey.
///
/// Valkey's script cache is server-wide, so one load is enough for every
/// pooled connection. The actor only protects this tiny dictionary; script
/// execution itself remains fully concurrent.
private actor ValkeyScriptCache {
    private var digests: [String: String] = [:]

    func digest(named name: String) -> String? {
        digests[name]
    }

    func store(_ digest: String, named name: String) {
        digests[name] = digest
    }

    func remove(named name: String, ifMatching digest: String) {
        guard digests[name] == digest else { return }
        digests[name] = nil
    }
}

/// Loads Lua scripts once, executes them by SHA, and recovers if Valkey's
/// script cache is flushed or the server is replaced.
struct ValkeyScriptExecutor: Sendable {
    struct Invocation: Sendable {
        let keys: [ValkeyKey]
        let args: [String]
    }

    let client: ValkeyClient
    private let cache = ValkeyScriptCache()

    func execute(
        name: String,
        script: String,
        keys: [ValkeyKey] = [],
        args: [String] = []
    ) async throws -> RESPToken {
        let digest = try await loadedDigest(name: name, script: script)
        do {
            return try await client.evalsha(sha1: digest, keys: keys, args: args)
        } catch let error {
            guard Self.isNoScript(error) else { throw error }
            await cache.remove(named: name, ifMatching: digest)
            let reloaded = try await loadedDigest(name: name, script: script)
            return try await client.evalsha(sha1: reloaded, keys: keys, args: args)
        }
    }

    /// Pipelines independent invocations of the same script in one round trip.
    ///
    /// This is intended for read/idempotent scripts: an external SCRIPT FLUSH
    /// can theoretically land midway through a pipeline, so NOSCRIPT recovery
    /// may retry an invocation that already completed.
    func execute(
        name: String,
        script: String,
        invocations: [Invocation]
    ) async throws -> [RESPToken] {
        guard !invocations.isEmpty else { return [] }

        let digest = try await loadedDigest(name: name, script: script)
        let firstResults = await execute(digest: digest, invocations: invocations)
        if firstResults.contains(where: Self.isNoScript) {
            await cache.remove(named: name, ifMatching: digest)
            let reloaded = try await loadedDigest(name: name, script: script)
            return try values(from: await execute(digest: reloaded, invocations: invocations))
        }
        return try values(from: firstResults)
    }

    private func loadedDigest(name: String, script: String) async throws -> String {
        if let digest = await cache.digest(named: name) {
            return digest
        }

        let digest = try await client.scriptLoad(script: script)
        await cache.store(digest, named: name)
        return digest
    }

    private func execute(
        digest: String,
        invocations: [Invocation]
    ) async -> [Result<RESPToken, ValkeyClientError>] {
        let commands: [any ValkeyCommand] = invocations.map {
            EVALSHA(sha1: digest, keys: $0.keys, args: $0.args)
        }
        return await client.execute(commands)
    }

    private func values(
        from results: [Result<RESPToken, ValkeyClientError>]
    ) throws -> [RESPToken] {
        try results.map { try $0.get() }
    }

    private static func isNoScript(_ error: ValkeyClientError) -> Bool {
        error.errorCode == .commandError
            && error.message?.hasPrefix("NOSCRIPT") == true
    }

    private static func isNoScript(_ result: Result<RESPToken, ValkeyClientError>) -> Bool {
        guard case .failure(let error) = result else { return false }
        return isNoScript(error)
    }
}
