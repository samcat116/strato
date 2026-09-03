import Fluent
import Foundation
import Metrics
import SQLKit
import StratoShared
import Vapor

extension DesiredStateAssembler {
    /// Per-sandbox registry work at sync assembly (issue #414): pins an
    /// unpinned tag to its manifest digest and derives the short-lived pull
    /// credential the sync carries. Best effort throughout — a registry that
    /// is down must not block the sync, which also carries state changes for
    /// already-materialized workloads.
    ///
    /// Digest pinning happens at most once per sandbox: the resolved digest is
    /// persisted (a targeted column update, so concurrent observed-state
    /// writes on the row are untouched) and never re-resolved, which is what
    /// makes convergence immutable — a re-tagged image cannot change a sandbox
    /// out from under its generation. Deliberately no generation bump: the pin
    /// matters to agents that have not materialized the sandbox yet, and must
    /// not re-converge ones that have.
    func sandboxRegistryMaterial(
        _ sandbox: Sandbox,
        secrets: [RegistryPullSecret],
        on db: any Database
    ) async -> RegistryCredential? {
        // A sandbox on its way out pulls nothing: no digest pin, no
        // credential material toward the agent tearing it down.
        guard sandbox.desiredStatus != .absent else { return nil }

        guard let ref = OCIImageReference.parse(sandbox.image) else {
            var metadata: Logger.Metadata = ["image": .string(sandbox.image)]
            if let sandboxID = sandbox.id {
                metadata["strato.sandbox.id"] = .string(sandboxID.uuidString)
            }
            app.logger.warning(
                "Sandbox image reference is unparseable; syncing without digest or credential",
                metadata: metadata)
            return nil
        }

        let secretRow = secrets.first { $0.registry == ref.registry }
        var basic: RegistryBasicCredential?
        if let secretRow {
            do {
                basic = RegistryBasicCredential(
                    username: secretRow.username,
                    password: try app.secretsEncryption.decrypt(secretRow.secret))
            } catch {
                app.logger.error(
                    "Failed to decrypt registry pull secret; treating the image as public",
                    metadata: [
                        "registry": .string(secretRow.registry),
                        "error": .string(error.localizedDescription),
                    ])
            }
        }

        // Tag→digest pinning. Gated on the failure backoff: a pin that cannot
        // succeed (registry down, anonymous rate limit, a pull secret that no
        // longer authenticates) leaves `imageDigest` nil, so without the gate
        // every subsequent assembly would retry it. That retry used to be
        // bounded by the 10-minute forced sync pass; since STR-146 it would be
        // bounded by the poll rate instead, which would have the control plane
        // hammering the registry hardest for exactly the sandbox whose registry
        // is already unhealthy.
        if sandbox.imageDigest == nil, let sandboxId = sandbox.id {
            let backoffKey = RegistryOperationBackoff.Key(
                operation: .resolveDigest, registry: ref.registry, repository: ref.repository)
            guard await app.registryOperationBackoff.shouldAttempt(backoffKey) else {
                return await registryCredential(ref: ref, secretRow: secretRow, basic: basic)
            }
            do {
                if let digest = try await app.registryClient.resolveDigest(for: ref, credential: basic) {
                    sandbox.imageDigest = digest
                    try await Sandbox.query(on: db)
                        .filter(\.$id == sandboxId)
                        .set(\.$imageDigest, to: digest)
                        .update()
                    app.logger.info(
                        "Pinned sandbox image tag to digest",
                        metadata: [
                            "strato.sandbox.id": .string(sandboxId.uuidString),
                            "image": .string(sandbox.image),
                            "digest": .string(digest),
                        ])
                }
                await app.registryOperationBackoff.recordSuccess(backoffKey)
            } catch {
                // The agent then resolves the tag itself (accepting the
                // mutability) and a later sync retries the pin — after the
                // cooldown, not on the very next assembly.
                await app.registryOperationBackoff.recordFailure(backoffKey)
                app.logger.warning(
                    "Failed to resolve sandbox image tag to a digest; syncing unpinned",
                    metadata: [
                        "strato.sandbox.id": .string(sandboxId.uuidString),
                        "image": .string(sandbox.image),
                        "error": .string(error.localizedDescription),
                    ])
            }
        }

        return await registryCredential(ref: ref, secretRow: secretRow, basic: basic)
    }

    /// The pull credential half of `sandboxRegistryMaterial`, split out so the
    /// digest-pin backoff can skip straight to it.
    func registryCredential(
        ref: OCIImageReference,
        secretRow: RegistryPullSecret?,
        basic: RegistryBasicCredential?
    ) async -> RegistryCredential? {
        guard let secretRow, let basic else { return nil }
        let cacheKey = RegistryCredentialCache.Key(
            secretID: secretRow.id,
            registry: ref.registry,
            repository: ref.repository,
            username: secretRow.username,
            encryptedSecret: secretRow.secret)
        if let cached = await app.registryCredentialCache.credential(for: cacheKey) {
            return cached
        }

        // Only *successful* mints are cached, so without a backoff a token
        // service that is down would be re-dialed on every assembly — the same
        // hammering the digest pin above avoids, and on the same trigger.
        let backoffKey = RegistryOperationBackoff.Key(
            operation: .mintPullToken, registry: ref.registry, repository: ref.repository)
        guard await app.registryOperationBackoff.shouldAttempt(backoffKey) else {
            return Self.storedCredential(ref: ref, secretRow: secretRow, basic: basic)
        }

        do {
            if let token = try await app.registryClient.mintPullToken(for: ref, credential: basic) {
                let credential = RegistryCredential(
                    registry: ref.registry,
                    username: secretRow.username,
                    password: token.token,
                    expiresAt: token.expiresAt,
                    bearer: true)
                await app.registryCredentialCache.store(credential, for: cacheKey)
                await app.registryOperationBackoff.recordSuccess(backoffKey)
                return credential
            }
            // A registry with no token service is a permanent property of the
            // registry, not a failure — recording success keeps it off the
            // backoff so the (cheap) probe stays on its normal path.
            await app.registryOperationBackoff.recordSuccess(backoffKey)
        } catch let error as RegistryClientError {
            // Policy refusal (e.g. plaintext token realm), not transience:
            // a Basic fallback would hand the agent the stored secret to
            // present to the very endpoint the client just refused. Send
            // nothing; the pull fails loudly agent-side instead.
            app.logger.warning(
                "Refusing to send registry credential for sandbox image",
                metadata: [
                    "registry": .string(ref.registry),
                    "error": .string(error.localizedDescription),
                ])
            return nil
        } catch {
            await app.registryOperationBackoff.recordFailure(backoffKey)
            app.logger.warning(
                "Failed to mint a registry pull token; falling back to the stored credential",
                metadata: [
                    "registry": .string(ref.registry),
                    "error": .string(error.localizedDescription),
                ])
        }

        return Self.storedCredential(ref: ref, secretRow: secretRow, basic: basic)
    }

    /// Basic-only registry, or its token service is unreachable from the
    /// control plane: the stored credential is the only material that can
    /// authorize the pull. Agents hold it in memory only (wire contract).
    static func storedCredential(
        ref: OCIImageReference,
        secretRow: RegistryPullSecret,
        basic: RegistryBasicCredential
    ) -> RegistryCredential {
        RegistryCredential(
            registry: ref.registry,
            username: secretRow.username,
            password: basic.password,
            expiresAt: nil,
            bearer: false)
    }

}
