import Crypto
import Fluent
import Foundation
import StratoShared
import Vapor

/// Snapshot mobility handlers (issue #428), registered by
/// `SandboxController.boot`: the user-facing export endpoint, and the
/// artifact-transfer routes agents stream through.
///
/// Transfer routes are agent routes, not user routes: like image downloads
/// (issue #493) they authenticate the SPIFFE SVID forwarded by the Envoy
/// mTLS sidecar (`AgentMTLSAuthenticator`; see the `SpiceDBAuthMiddleware`
/// carve-out), and there is deliberately no user-session fallback — a
/// browser has no business streaming raw snapshot artifacts. Authorization
/// is the same coarse model as image downloads: any enrolled agent identity
/// may transfer any snapshot's artifacts, on the accepted premise that an
/// enrolled agent is a trusted hypervisor node (narrowing to assignment-
/// scoped access is issue #562's territory). Bytes flow through the control
/// plane into `imageObjectStore` — agents never talk to the store directly.
extension SandboxController {

    // MARK: - Export

    /// POST /api/sandboxes/:sandboxID/snapshots/:snapshotID/export
    ///
    /// Copies a ready snapshot's artifacts off its agent into control-plane
    /// object storage, making the checkpoint durable against agent loss and
    /// eligible for cross-agent restore and fork. 202 + operation; the agent
    /// streams each artifact to a pre-signed upload URL, the upload route
    /// records size + SHA-256 as the bytes land, and the operation stamps
    /// `exportedAt` once all four artifacts are recorded. Re-exporting is
    /// idempotent: uploads replace the objects at their deterministic keys.
    func exportSnapshot(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let sandbox = try await fetchSandboxWithPermission(req: req, permission: "read")
        let snapshot = try await fetchSnapshot(req: req, sandbox: sandbox)
        let snapshotID = try snapshot.requireID()
        let sandboxID = try sandbox.requireID()

        // `export`, not `read`: this copies the whole archive into project
        // storage and occupies the snapshot's agent for the duration, so it
        // is a mutation, not a view. Gating it on `read` let any project
        // viewer trigger unbounded writes (issue #428 review).
        let canExport = try await req.spicedb.checkPermission(
            subject: try user.requireID().uuidString,
            permission: "export",
            resource: "sandbox_snapshot",
            resourceId: snapshotID.uuidString)
        guard canExport else {
            throw Abort(.forbidden, reason: "You don't have permission to export this snapshot")
        }

        guard snapshot.isReady else {
            throw Abort(
                .conflict,
                reason: "Snapshot cannot be exported in status '\(snapshot.status.rawValue)'")
        }
        guard let agentId = snapshot.agentId else {
            throw Abort(
                .conflict,
                reason: "Snapshot has no owning agent; its artifacts are unreachable")
        }
        do {
            try await SandboxSnapshotService.requireCapableAgent(agentId, app: req.application)
        } catch let error as SandboxSnapshotServiceError {
            throw Abort(.conflict, reason: error.localizedDescription)
        }
        // The export message postdates wire v13: a pre-v14 agent cannot even
        // decode the envelope, so refuse up front instead of timing out.
        guard let agent = await req.application.agentService.getAgentInfo(agentId),
            WireProtocol.supportsSandboxSnapshotMobility(agent.wireProtocolVersion ?? 0)
        else {
            throw Abort(
                .conflict,
                reason:
                    "The snapshot's agent is too old for snapshot export (need wire protocol >= \(WireProtocol.sandboxSnapshotMobilityMinimumVersion)). Upgrade the agent."
            )
        }

        // One upload slot per artifact: control-plane-relative paths the
        // agent resolves against the Envoy mTLS listener it already dials
        // and PUTs with its SVID as the credential.
        let uploads = SandboxSnapshotArtifactKind.allCases.map { kind in
            SandboxSnapshotArtifactUploadTarget(
                kind: kind,
                uploadURL: SandboxSnapshot.artifactTransferPath(
                    sandboxId: sandboxID, snapshotId: snapshotID, kind: kind))
        }

        let operation = try await beginOperation(
            .snapshotExport, sandbox: sandbox, user: user, on: req.db
        ) { db in
            try await Self.lockSnapshotLineage([snapshotID], on: db)
            guard let current = try await SandboxSnapshot.find(snapshotID, on: db), current.isReady
            else {
                throw Abort(.conflict, reason: "Snapshot is no longer exportable")
            }
            // The exported copy is a second copy of the same bytes and draws
            // its own storage from the project's pool (issue #428). Reserve it
            // here, in the operation's transaction, so a doomed export is
            // rejected before it occupies an agent — but skip it when a
            // complete copy already exists, since re-exporting overwrites the
            // same keys and adds nothing.
            guard !current.isExported else { return }
            guard let project = try await Project.find(current.$project.id, on: db) else {
                throw Abort(.conflict, reason: "Snapshot's project no longer exists")
            }
            try await QuotaEnforcementService.reserveSandboxSnapshotExport(
                for: project, environment: current.environment,
                size: current.size ?? 0, on: db)
        }

        Self.runSnapshotExport(
            operation, snapshotID: snapshotID, agentId: agentId, uploads: uploads,
            app: req.application)

        req.logger.info(
            "Sandbox snapshot export accepted",
            metadata: [
                "sandbox_id": .string(sandboxID.uuidString),
                "snapshot_id": .string(snapshotID.uuidString),
                "agent_id": .string(agentId),
            ])
        return try Self.accepted(operation)
    }

    /// Background half of `exportSnapshot`: the agent RPC, then the
    /// completeness check over what the upload route actually recorded. The
    /// agent's success alone is deliberately not trusted to stamp
    /// `exportedAt` — the integrity entries written as each stream landed
    /// are the ground truth.
    private static func runSnapshotExport(
        _ operation: ResourceOperation,
        snapshotID: UUID,
        agentId: String,
        uploads: [SandboxSnapshotArtifactUploadTarget],
        app: Application
    ) {
        guard let operationId = operation.id else { return }
        let sandboxID = operation.resourceID

        app.backgroundTasks.spawn {
            do {
                try await SandboxSnapshotService.requestSnapshotExport(
                    sandboxId: sandboxID, snapshotId: snapshotID, uploads: uploads,
                    agentId: agentId, app: app)

                // The agent RPC above can span shutdown's drain; bail before the
                // completeness check if it cancelled us (see `Application.liveDB`).
                guard let db = app.liveDB else { return }
                guard let current = try await SandboxSnapshot.find(snapshotID, on: db) else {
                    throw Abort(.conflict, reason: "Snapshot was deleted while its export ran")
                }
                let recorded = Set((current.exportedArtifacts ?? []).map(\.kind))
                let missing = SandboxSnapshotArtifactKind.allCases.filter { !recorded.contains($0) }
                guard missing.isEmpty else {
                    throw Abort(
                        .internalServerError,
                        reason:
                            "Agent reported the export complete but artifacts [\(missing.map(\.rawValue).joined(separator: ", "))] never arrived"
                    )
                }
                current.exportedAt = Date()
                try await current.save(on: db)

                await completeOperation(
                    operationId, sandboxID: sandboxID, as: .succeeded, error: nil,
                    settingSandboxStatus: nil, app: app)
            } catch {
                await completeOperation(
                    operationId, sandboxID: sandboxID, as: .failed,
                    error: error.localizedDescription,
                    settingSandboxStatus: nil, app: app)
            }
        }
    }

    // MARK: - Artifact transfer (agent mTLS routes)

    /// PUT /api/sandboxes/:sandboxID/snapshots/:snapshotID/artifacts/:artifactKind
    ///
    /// One exported artifact's bytes, streamed as the raw request body into
    /// object storage. Size and SHA-256 are computed here, from the bytes
    /// actually stored — never agent-supplied — and recorded on the snapshot
    /// row for later download verification. The running export operation
    /// stamps `exportedAt` once every artifact has arrived.
    ///
    /// A re-upload deliberately leaves an existing `exportedAt` alone.
    /// Snapshot artifacts are immutable once `.ready` and every key is
    /// deterministic, so a re-export replaces each object with identical bytes
    /// and the previous export record keeps describing what is actually
    /// stored. Clearing it per-PUT meant a re-export that died partway (agent
    /// crash, expired budget) permanently demoted a snapshot that still had a
    /// complete, valid copy — and the only documented recovery was another
    /// re-export, which could fail the same way (issue #428 review).
    func uploadSnapshotArtifact(req: Request) async throws -> HTTPStatus {
        let (snapshot, kind) = try await authenticatedSnapshotArtifactRequest(req: req)
        let snapshotID = try snapshot.requireID()
        let key = SandboxSnapshotObjectKey.artifact(
            projectId: snapshot.$project.id, snapshotId: snapshotID, kind: kind)

        // No single artifact can legitimately exceed the recorded archive
        // footprint; double it for filesystem rounding, with a floor for
        // rows whose size estimate was small.
        let maxBytes = max((snapshot.size ?? 0) * 2, Int64(1) << 30)

        let store = req.application.imageObjectStore
        let writer = try await store.openWriter(key: key)
        var hasher = SHA256()
        var size: Int64 = 0
        do {
            for try await chunk in req.body {
                try Task.checkCancellation()
                size += Int64(chunk.readableBytes)
                guard size <= maxBytes else {
                    throw Abort(
                        .payloadTooLarge,
                        reason: "Artifact exceeds the maximum allowed size of \(maxBytes) bytes")
                }
                let readable = chunk
                if let bytes = readable.getBytes(at: readable.readerIndex, length: readable.readableBytes) {
                    hasher.update(data: bytes)
                }
                try await writer.write(chunk)
            }
            guard size > 0 else {
                throw Abort(.badRequest, reason: "Artifact upload carried no bytes")
            }
            try await writer.finish()
        } catch {
            await writer.abort()
            throw error
        }

        let sha256 = hasher.finalize().map { String(format: "%02x", $0) }.joined()

        // Record the integrity entry. Agents upload sequentially, so this
        // read-modify-write never races itself; a lost entry only means the
        // export completeness check fails closed.
        guard let current = try await SandboxSnapshot.find(snapshotID, on: req.db) else {
            try? await store.delete(key: key)
            throw Abort(.notFound, reason: "Snapshot no longer exists")
        }
        var artifacts = current.exportedArtifacts ?? []
        artifacts.removeAll { $0.kind == kind }
        artifacts.append(
            SandboxSnapshotExportedArtifact(kind: kind, sizeBytes: size, sha256: sha256))
        current.exportedArtifacts = artifacts
        try await current.save(on: req.db)

        req.logger.info(
            "Sandbox snapshot artifact stored",
            metadata: [
                "snapshot_id": .string(snapshotID.uuidString),
                "kind": .string(kind.rawValue),
                "size": .stringConvertible(size),
            ])
        return .ok
    }

    /// GET /api/sandboxes/:sandboxID/snapshots/:snapshotID/artifacts/:artifactKind
    ///
    /// Streams one exported artifact back to an importing agent, range-aware
    /// via the object store.
    func downloadSnapshotArtifact(req: Request) async throws -> Response {
        let (snapshot, kind) = try await authenticatedSnapshotArtifactRequest(req: req)
        let snapshotID = try snapshot.requireID()
        guard snapshot.exportedArtifact(for: kind) != nil else {
            throw Abort(.notFound, reason: "Artifact '\(kind.rawValue)' has not been exported")
        }
        let key = SandboxSnapshotObjectKey.artifact(
            projectId: snapshot.$project.id, snapshotId: snapshotID, kind: kind)
        return try await req.application.imageObjectStore.stream(
            key: key, filename: kind.filename, on: req)
    }

    /// Shared preflight for both transfer directions: authenticate the
    /// caller's SVID from the forwarded client certificate, then parse the
    /// path and load the snapshot row. Authentication first — an
    /// unauthenticated caller learns nothing about which snapshot IDs exist.
    /// There is deliberately no session fallback, unlike image downloads:
    /// these routes exist only for agents.
    private func authenticatedSnapshotArtifactRequest(
        req: Request
    ) async throws -> (SandboxSnapshot, SandboxSnapshotArtifactKind) {
        guard AgentMTLSAuthenticator.hasClientCertificate(req) else {
            throw Abort(
                .unauthorized,
                reason: "Snapshot artifact transfer requires agent mTLS authentication")
        }
        let agentName = try await AgentMTLSAuthenticator.authenticateAgent(req: req)

        guard let sandboxID = req.parameters.get("sandboxID", as: UUID.self),
            let snapshotID = req.parameters.get("snapshotID", as: UUID.self),
            let kindRaw = req.parameters.get("artifactKind"),
            let kind = SandboxSnapshotArtifactKind(rawValue: kindRaw)
        else {
            throw Abort(.badRequest, reason: "Invalid snapshot artifact path")
        }
        guard let snapshot = try await SandboxSnapshot.find(snapshotID, on: req.db),
            snapshot.$sandbox.id == sandboxID
        else {
            throw Abort(.notFound, reason: "Snapshot not found")
        }
        req.logger.info(
            "Agent snapshot artifact transfer authenticated",
            metadata: [
                "agent": .string(agentName),
                "snapshot_id": .string(snapshotID.uuidString),
                "kind": .string(kind.rawValue),
                "method": .string(req.method.rawValue),
            ])
        return (snapshot, kind)
    }
}
