# STR-261 File Hashing Deduplication Design

## Goal

Replace four duplicate streaming SHA-256 file-hash loops in
`StratoAgentCore` with one shared implementation without changing the existing
call-site APIs, error domains, or lowercase hexadecimal digest values.

## Architecture

Add an internal `FileHashing` namespace to `StratoAgentCore` with one
`sha256Hex(ofFileAt:)` function. The helper opens the file, streams it through
`Crypto.SHA256` in fixed-size chunks, closes the handle, and returns the digest
as lowercase hexadecimal text. It exposes a generic hashing error rather than
depending on transfer, update, OCI, or image-cache domain types.

Keep the existing helpers on `SnapshotArtifactTransfer`, `AgentUpdater`,
`OCIRegistryClient`, and `ImageCacheService` as thin wrappers. Each wrapper
delegates to `FileHashing` and maps a helper failure to the same domain error
and message it currently uses for an unavailable file. This preserves their
current access levels and signatures while removing the duplicated file loop.

The adjacent `OCIRegistryClient.sha256Hex(of data: Data)` remains unchanged.
It hashes an in-memory value and is not part of the streaming-file primitive.

## Error behavior

- `FileHashing` reports file-open and streaming-read failures through its own
  internal error type.
- `SnapshotArtifactTransfer.sha256Hex(of:)` maps failure to
  `TransferError.fileNotFound(path)`.
- `AgentUpdater.sha256Hex(ofFileAt:)` maps failure to
  `AgentUpdateError.downloadFailed("downloaded artifact missing at \(path)")`.
- `OCIRegistryClient.sha256Hex(ofFileAt:)` maps failure to
  `OCIError.transferFailed(detail: "downloaded file missing at \(path)")`.
- `ImageCacheService.computeChecksum(filePath:)` maps failure to
  `ImageCacheError.fileNotFound(path)`.

No helper exposes file contents or retains a whole artifact in memory.

## Tests

- Test the shared helper with an empty file and a file larger than one chunk,
  comparing its result with `SHA256.hash(data:)`.
- Test the helper's missing-file error directly.
- Test the accessible call-site wrappers to confirm their existing domain
  error mapping remains intact.
- Run the focused `StratoAgentTests` package tests after the refactor.

## Out of scope

- Deduplicating in-memory SHA-256 hashing.
- Adding other digest algorithms or configurable hashing policies.
- Changing checksum comparison behavior, download flow, or artifact
  publication semantics.
