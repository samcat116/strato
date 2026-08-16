# STR-154 Disk Attachments Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace host-path disk attachments with a shared file/block-device/RBD sum type carried verbatim through storage, wire state, persistence, and hypervisor realization.

**Architecture:** `StratoShared` defines the one attachment value used at package boundaries. The filesystem backend continues to produce `.file`; agent reconciliation reports that value, the control plane stores it as JSON and echoes it in VM specs, and each hypervisor switches on the case without re-inferring format from a path.

**Tech Stack:** Swift 6, swift-testing, Vapor/Fluent/PostgreSQL, swift-libvirt XML builders, SwiftFirecracker.

## Global Constraints

- No Ceph storage backend or RBD lifecycle operations in STR-154.
- Preserve existing file-backed volume, boot materialization, attach/detach, and Firecracker rootfs behavior.
- Bump the exact-match wire contract from v50 to v51; do not add a legacy capability bag or mixed-version compatibility path.
- The control plane stores and returns the complete agent-reported value without deriving storage layout.
- Existing `dataset_path` rows migrate losslessly to `.file`, with `.raw` selecting `raw` and every other extension retaining the historical `qcow2` fallback.
- Follow red-green-refactor for every behavior change.

---

### Task 1: Shared Attachment Contract

**Files:**
- Create: `shared/Sources/StratoShared/DiskAttachment.swift`
- Create: `shared/Tests/StratoSharedTests/DiskAttachmentTests.swift`
- Modify: `shared/Sources/StratoShared/VMSpec.swift`
- Modify: `shared/Sources/StratoShared/ReconciliationProtocol.swift`
- Modify: `shared/Sources/StratoShared/WireProtocol.swift`
- Modify: `shared/Tests/StratoSharedTests/WireProtocolTests.swift`
- Modify: `agent/Sources/StratoAgentCore/StorageBackend.swift`

**Interfaces:**
- Produces: `DiskFormat`, `DiskAttachment.file(path:format:)`, `.blockDevice(path:)`, and `.rbd(pool:image:user:monHosts:)` in `StratoShared`.
- Produces: `VolumeSpec.attachment: DiskAttachment?` and `ObservedVolumeState.attachment: DiskAttachment?`.
- Removes: package-boundary `storagePath` fields and the agent-local `DiskAttachment` struct.

- [ ] **Step 1: Write failing shared contract tests**

Add literal JSON round-trip expectations for all cases, including this RBD fixture:

```swift
let attachment = DiskAttachment.rbd(
    pool: "volumes", image: "volume-1", user: "client.project-1",
    monHosts: ["10.0.0.10:6789", "10.0.0.11:6789"])
#expect(try decode(encode(attachment)) == attachment)
```

Also construct `VolumeSpec(attachment:)` and `ObservedVolumeState(attachment:)`, and change the pinned current wire version expectation to 51.

- [ ] **Step 2: Run the shared tests and verify RED**

Run: `swift test --package-path shared --filter DiskAttachmentTests`

Expected: compile failures because `DiskAttachment` is not in `StratoShared` and the DTO initializers still accept `storagePath`.

- [ ] **Step 3: Implement the shared types and DTO fields**

Use synthesized `Codable` for the associated-value enum:

```swift
public enum DiskAttachment: Codable, Equatable, Sendable {
    case file(path: String, format: DiskFormat)
    case blockDevice(path: String)
    case rbd(pool: String, image: String, user: String, monHosts: [String])
}
```

Move `DiskFormat` beside it, replace both wire `storagePath` fields with `attachment`, remove the agent-local definitions, and bump `WireProtocol.currentVersion` to 51 with an STR-154 comment.

- [ ] **Step 4: Run shared tests and verify GREEN**

Run: `swift test --package-path shared`

Expected: all shared tests pass after call-site fixture updates needed only for the DTO rename.

- [ ] **Step 5: Commit**

```bash
git add shared agent/Sources/StratoAgentCore/StorageBackend.swift
git commit -m "Add shared disk attachment variants"
```

### Task 2: Storage and Agent Reconciliation

**Files:**
- Modify: `agent/Sources/StratoAgentCore/FileSystemStorageBackend.swift`
- Modify: `agent/Sources/StratoAgentCore/MockStorageBackend.swift`
- Modify: `agent/Sources/StratoAgentCore/Reconciliation.swift`
- Modify: `agent/Sources/StratoAgent/Agent.swift`
- Modify: `agent/Tests/StratoAgentTests/FileSystemStorageBackendTests.swift`
- Modify: `agent/Tests/StratoAgentTests/MockStorageBackendTests.swift`
- Modify: `agent/Tests/StratoAgentTests/VolumeReconciliationTests.swift`

**Interfaces:**
- Consumes: shared `DiskAttachment`.
- Produces: `ObservedVolumeFacts.attachment: DiskAttachment`.
- Produces: explicit file-only extraction for current `qemu-img` operations; no general `path` property on the sum type.

- [ ] **Step 1: Convert storage expectations to `.file` and add a non-file guard test**

Change existing expectations to literals such as:

```swift
#expect(attachment == .file(path: "\(root)/vol-1/volume.qcow2", format: .qcow2))
```

Add a reconciliation test proving a non-file clone source is rejected by the current filesystem-only path rather than treated as a host path.

- [ ] **Step 2: Run focused agent tests and verify RED**

Run: `swift test --package-path agent --filter FileSystemStorageBackendTests`

Expected: compile failures at struct initializers and `.path`/`.format` assumptions.

- [ ] **Step 3: Make filesystem producers explicit and update observed facts**

Return `.file(path:format:)` everywhere. Replace `ObservedVolumeFacts.path` and `.format` with `attachment`, and update observed-state reporting to send that exact value. At path-only backend calls, switch explicitly:

```swift
guard case .file(let path, _) = attachment else {
    throw VolumeConvergenceError.unsupported(
        "the filesystem storage backend cannot operate on \(attachment)")
}
```

When building VM manifest entries, store `attachment: disk`, not `storagePath: disk.path`.

- [ ] **Step 4: Run reconciliation/storage tests and verify GREEN**

Run: `swift test --package-path agent --filter 'FileSystemStorageBackendTests|MockStorageBackendTests|VolumeReconciliationTests'`

Expected: selected suites pass.

- [ ] **Step 5: Commit**

```bash
git add agent/Sources/StratoAgentCore agent/Sources/StratoAgent/Agent.swift agent/Tests
git commit -m "Carry disk attachments through agent storage"
```

### Task 3: Hypervisor Case Handling

**Files:**
- Modify: `agent/Sources/StratoAgentCore/ResolvedDisk.swift`
- Modify: `agent/Sources/StratoAgentCore/DomainXMLBuilder.swift`
- Modify: `agent/Sources/StratoAgentCore/DomainDeviceXML.swift`
- Modify: `agent/Sources/StratoAgent/HypervisorProtocol.swift`
- Modify: `agent/Sources/StratoAgent/LibvirtService.swift`
- Modify: `agent/Sources/StratoAgent/FirecrackerService.swift`
- Modify: `agent/Sources/StratoAgent/MockHypervisorService.swift`
- Modify: `agent/Tests/StratoAgentTests/DomainXMLBuilderTests.swift`
- Create: `agent/Tests/StratoAgentTests/DomainDeviceXMLTests.swift`
- Modify: relevant Firecracker service tests under `agent/Tests/StratoAgentTests/`

**Interfaces:**
- Produces: `ResolvedDisk(attachment:readonly:bootOrder:volumeId:)`.
- Produces: `HypervisorService.attachDisk(... attachment: DiskAttachment, ...)`.
- Produces: one attachment-aware libvirt disk-node builder shared by domain creation and hot-plug.

- [ ] **Step 1: Add failing XML behavior tests**

Assert literal XML semantics:

```swift
#expect(fileXML.contains("<disk type=\"file\" device=\"disk\">"))
#expect(blockXML.contains("<disk type=\"block\" device=\"disk\">"))
#expect(blockXML.contains("<source dev=\"/dev/rbd0\"></source>"))
#expect(rbdXML.contains("<disk type=\"network\" device=\"disk\">"))
#expect(rbdXML.contains("<source protocol=\"rbd\" name=\"volumes/volume-1\">"))
#expect(rbdXML.contains("<auth username=\"client.project-1\">"))
```

Add a Firecracker boundary test that `.rbd` yields `notSupported`, while `.file` and `.blockDevice` resolve their paths.

- [ ] **Step 2: Run focused XML/driver tests and verify RED**

Run: `swift test --package-path agent --filter 'DomainXMLBuilderTests|DomainDeviceXMLTests|Firecracker'`

Expected: failures because builders and services still accept only path plus inferred format.

- [ ] **Step 3: Implement exhaustive switches**

Change `ResolvedDisk` and the protocol signature to carry the enum. Render:

- `.file`: libvirt `type="file"`, `driver type=<format>`, `source file=<path>`.
- `.blockDevice`: libvirt `type="block"`, `driver type="raw"`, `source dev=<path>`.
- `.rbd`: libvirt `type="network"`, `driver type="raw"`, `source protocol="rbd" name="<pool>/<image>"`, one host per monitor, and ceph auth username.

At create time, validate filesystem existence only for `.file` and `.blockDevice`; do not call `FileManager` for `.rbd`. Firecracker extracts a host path from `.file`/`.blockDevice` and rejects `.rbd`.

- [ ] **Step 4: Run all agent tests and verify GREEN**

Run: `swift test --package-path agent`

Expected: all agent tests pass.

- [ ] **Step 5: Commit**

```bash
git add agent/Sources agent/Tests
git commit -m "Switch hypervisors over disk attachment cases"
```

### Task 4: Control-plane Persistence and Echo

**Files:**
- Create: `control-plane/Sources/App/Migrations/ReplaceVolumeReplicaDatasetPath.swift`
- Modify: `control-plane/Sources/App/Migrations/CurrentSchema.sql`
- Modify: `control-plane/Sources/App/configure.swift`
- Modify: `control-plane/Sources/App/Models/VolumeReplica.swift`
- Modify: `control-plane/Sources/App/Models/Volume.swift`
- Modify: `control-plane/Sources/App/Services/VolumeService.swift`
- Modify: `control-plane/Sources/App/Services/DesiredStateAssembler.swift`
- Modify: `control-plane/Sources/App/Services/VMSpecBuilder.swift`
- Modify: `control-plane/Sources/App/Services/ObservedStateApplier.swift`
- Create or modify: `control-plane/Tests/AppResourceTests/DiskAttachmentPersistenceTests.swift`
- Modify: fixture call sites under `control-plane/Tests/`

**Interfaces:**
- Produces: `VolumeReplica.diskAttachment: DiskAttachment?` stored in `disk_attachment` JSON.
- Produces: `VolumeService.diskAttachments(...)->[UUID: DiskAttachment]`.
- Produces: `VolumeReplicaResponse.diskAttachment`.

- [ ] **Step 1: Add failing round-trip persistence test**

Report an RBD `ObservedVolumeState`, reload its `VolumeReplica`, assemble the VM desired state, and assert the exact value at both boundaries:

```swift
let rbd = DiskAttachment.rbd(
    pool: "volumes", image: volumeID.uuidString,
    user: "client.project", monHosts: ["10.0.0.10:6789"])
#expect(reloaded.diskAttachment == rbd)
#expect(assembledVM.spec.volumes.first?.attachment == rbd)
```

Add a migration test that inserts a legacy `dataset_path`, runs the migration, and decodes `.file(path:format:)` from `disk_attachment`.

- [ ] **Step 2: Run focused control-plane tests and verify RED**

Run with the repository's test database settings: `DATABASE_PORT=55432 swift test --package-path control-plane --filter DiskAttachmentPersistenceTests`

Expected: compile failures because the model and assemblers still use `datasetPath`/`storagePath`.

- [ ] **Step 3: Implement JSON persistence, migration, and projections**

Use `@OptionalField(key: "disk_attachment") var diskAttachment: DiskAttachment?`. In PostgreSQL, backfill with the synthesized enum shape:

```sql
jsonb_build_object(
  'file', jsonb_build_object(
    'path', dataset_path,
    'format', CASE WHEN lower(dataset_path) LIKE '%.raw' THEN 'raw' ELSE 'qcow2' END
  )
)
```

Then drop `dataset_path`. Update the current-schema baseline and every builder/applier to pass `DiskAttachment` values unchanged.

- [ ] **Step 4: Run control-plane tests and verify GREEN**

Run: `DATABASE_PORT=55432 swift test --package-path control-plane`

Expected: all control-plane tests pass, apart from a separately identified known baseline failure if one exists before these changes.

- [ ] **Step 5: Commit**

```bash
git add control-plane/Sources control-plane/Tests
git commit -m "Persist reported disk attachments verbatim"
```

### Task 5: Documentation and Final Verification

**Files:**
- Modify: `docs/architecture/storage.md`
- Modify: `docs/architecture/wire-protocol.md`
- Modify: any stale code comments found by `rg 'storagePath|datasetPath|host path'` in changed volume-attachment paths.

**Interfaces:**
- Consumes: completed shared/agent/control-plane contract.
- Produces: documentation that describes the shipped sum type and v51 flow.

- [ ] **Step 1: Update the architecture docs**

Document the three attachment cases, current `.file` production, observed-state persistence and VM-spec echo, exact v51 cutover, Libvirt case handling, and Firecracker's native-RBD rejection/krbd future.

- [ ] **Step 2: Format and lint changed Swift files**

Run: `swift format --in-place --recursive shared/Sources shared/Tests agent/Sources agent/Tests control-plane/Sources control-plane/Tests`

Run: `swift format lint --strict --recursive shared/Sources shared/Tests agent/Sources agent/Tests control-plane/Sources control-plane/Tests`

Expected: zero lint failures.

- [ ] **Step 3: Run complete touched-package tests**

Run:

```bash
swift test --package-path shared
swift test --package-path agent
DATABASE_PORT=55432 swift test --package-path control-plane
```

Expected: all tests pass, with any environment-only boundary reported precisely.

- [ ] **Step 4: Review the diff against acceptance**

Run: `git diff --check && git status --short && git diff --stat origin/main...HEAD && git diff origin/main...HEAD`

Confirm: no path inference remains in hypervisor drivers; filesystem volume operations still return `.file`; both wire directions carry `DiskAttachment`; persistence is verbatim; version is 51; docs are current.

- [ ] **Step 5: Rebase/merge current main and reverify before completion**

Run: `git fetch origin main && git merge origin/main`, resolve only STR-154 overlaps, then repeat the three package tests and lint.

- [ ] **Step 6: Finish the branch**

Use the requested branch name `samcat116/str-154-disk-attachments-as-a-sum-type-replace-the-host-path` when publishing the detached worktree commit chain.
