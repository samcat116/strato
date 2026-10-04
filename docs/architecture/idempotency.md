# Mutation idempotency

The matched Vapor route opts in with `.supportsIdempotency()` at registration.
Every POST, PUT, PATCH and DELETE route without that declaration rejects any
`Idempotency-Key` header before principal/replay lookup or handler execution:

```http
HTTP/1.1 400 Bad Request
Content-Type: application/json

{"error":true,"reason":"Idempotency-Key is not supported for this route"}
```

Authentication, credential restrictions and user-security middleware still run
first. Requests without the header and non-mutation methods retain their existing
behavior. Empty or oversized keys on supported routes still return 400.

Supported handlers reserve and complete claims in their existing transactions.
Keys remain scoped to the acting principal, expire after 24 hours, bind method,
path (including query) and canonical JSON body, and reject mismatched reuse with
422. Replays retain the existing resource reauthorization and concurrent winner
semantics; the route declaration adds no replay or resource abstraction.

## Audited supported inventory

This inventory was audited against main `7cb24c7b` for STR-359 / #1429.
The 32 operations below correspond to OpenAPI `IdempotencyKey` parameters.

| Method | Route | Claim path |
| --- | --- | --- |
| POST | `/api/vms` | VM creation workflow |
| PUT | `/api/vms/{vmID}` | Controller reservation / ResourceMutation |
| DELETE | `/api/vms/{vmID}` | ResourceMutation.accept |
| POST | `/api/vms/{vmID}/start` | ResourceMutation.accept |
| POST | `/api/vms/{vmID}/interfaces` | ResourceMutation.accept |
| DELETE | `/api/vms/{vmID}/interfaces/{interfaceID}` | ResourceMutation.accept |
| POST | `/api/vms/{vmID}/interfaces/{interfaceID}/retry` | ResourceMutation.accept |
| POST | `/api/vms/{vmID}/stop` | ResourceMutation.accept |
| POST | `/api/vms/{vmID}/restart` | ResourceMutation.accept |
| POST | `/api/vms/{vmID}/pause` | ResourceMutation.accept |
| POST | `/api/vms/{vmID}/resume` | ResourceMutation.accept |
| POST | `/api/vms/{vmID}/snapshots` | Snapshot capture transaction |
| DELETE | `/api/vms/{vmID}/snapshots/{snapshotID}` | SnapshotArtifactMutation → ResourceMutation |
| POST | `/api/vms/{vmID}/snapshots/{snapshotID}/restore` | ResourceMutation.accept |
| POST | `/api/sandboxes` | Sandbox creation workflow |
| DELETE | `/api/sandboxes/{sandboxID}` | ResourceMutation.accept |
| POST | `/api/sandboxes/{sandboxID}/start` | ResourceMutation.accept |
| POST | `/api/sandboxes/{sandboxID}/stop` | ResourceMutation.accept |
| POST | `/api/sandboxes/{sandboxID}/restart` | ResourceMutation.accept |
| POST | `/api/sandboxes/{sandboxID}/snapshots` | Snapshot capture transaction |
| DELETE | `/api/sandboxes/{sandboxID}/snapshots/{snapshotID}` | SnapshotArtifactMutation → ResourceMutation |
| POST | `/api/sandboxes/{sandboxID}/snapshots/{snapshotID}/restore` | ResourceMutation.accept |
| POST | `/api/sandboxes/{sandboxID}/snapshots/{snapshotID}/export` | SnapshotArtifactMutation → ResourceMutation |
| POST | `/api/volumes` | Controller reservation / ResourceMutation |
| DELETE | `/api/volumes/{volumeId}` | ResourceMutation.accept |
| POST | `/api/volumes/{volumeId}/attach` | ResourceMutation.accept |
| POST | `/api/volumes/{volumeId}/detach` | ResourceMutation.accept |
| POST | `/api/volumes/{volumeId}/resize` | ResourceMutation.accept |
| POST | `/api/volumes/{volumeId}/io-limits` | ResourceMutation.accept |
| POST | `/api/volumes/{volumeId}/snapshot` | Snapshot capture transaction |
| POST | `/api/volumes/{volumeId}/clone` | Controller reservation / ResourceMutation |
| DELETE | `/api/volumes/{volumeId}/snapshots/{snapshotId}` | SnapshotArtifactMutation → ResourceMutation |

## Unsupported inventory and future routes

All other mutation routes are unsupported, including floating-IP allocation,
network mutations, VM metadata PATCH, sandbox/volume metadata PUT, VM recorded
commands, VM/sandbox exec, console/session/API-key minting, identity and IAM
mutations, generated project handlers, SCIM/SSF, agent control and artifact
uploads. There are no keyed-mutation exemptions. The update-only
`GET /agent/update/v1` exchange is outside this mutation inventory: like other
reads it ignores the header and needs no support annotation.

Sandbox exec is deliberately unsupported even though its suspended-wake branch
uses ResourceMutation: its running branch mints a session without a claim.
Natural repeatability of an update or artifact upload is not a replay guarantee.

Adding support requires auditing every successful branch and all side effects,
then changing the route declaration, this inventory, and OpenAPI together.
Structural tests compare registered declarations with the bundled OpenAPI
supported set and inventory, and exercise every unmarked registered mutation
through the guard with a side-effect sentinel. New unmarked routes are rejected
automatically and included in that coverage. Existing principal, concurrent
claim and replay tests remain in IdempotencyTests.

The CLI generates keys only for the same supported OpenAPI operation IDs.
Unsupported calls (including both exec/wake attempts) stay headerless by default;
explicit caller keys pass through for the server to accept or reject. The key
stays outside the existing authentication middleware so token-refresh replay
retains the same key and body. CLI tests check the OpenAPI operation inventory,
unsupported defaults and supported refresh replay without changing auth retries.
