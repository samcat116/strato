# API Reference

The Strato control plane exposes a JSON HTTP API described by a **spec-first**
OpenAPI 3.0 document. The document is authored in
[`control-plane/Sources/App/openapi.yaml`](https://github.com/samcat116/strato/blob/main/control-plane/Sources/App/openapi.yaml),
consumed at build time by
[swift-openapi-generator](https://github.com/apple/swift-openapi-generator), and
served by every running control plane.

## Live endpoints

A running control plane serves:

- **`GET /api/openapi.yaml`** — the OpenAPI document itself.
- **`GET /api/docs`** — an interactive Swagger UI viewer rendered from that
  document.

Both are reachable without authentication. Point any OpenAPI-aware client
(code generators, Postman/Insomnia, `openapi-generator`) at
`https://<your-control-plane>/api/openapi.yaml`.

## Conventions

### Authentication

Every operation requires authentication unless the spec marks it public. Two
schemes are accepted interchangeably:

- **API key** (`Authorization: Bearer <key>`) — mint one with
  `POST /api/api-keys`. A key acts *on behalf of* its owner and may carry a
  **restriction**: an action list (`vm:read`, `vm:*`, `*`) and optionally one
  node it may act at or below. The effective permission is the owner's role
  bindings intersected with it, so a restriction can only ever subtract. The
  older `scopes` array (`read`, `write`, `admin`) is deprecated and read only
  when no restriction is stored.
- **Session cookie** (`vapor-session`) — set after a WebAuthn/passkey login.

Per-object access is enforced by the built-in IAM system (an in-process Cedar
policy evaluator), and a credential's restriction is intersected by that same
evaluator rather than by a separate gate, so every refusal appears in the
decision log with a tier. An authenticated-but-unauthorized caller receives
`403`.

### Pagination

List endpoints page by default (issue #700): `limit` (default 50, max 500)
and `offset` (default 0) query parameters select the slice, and the response
is a paged envelope — `items` (the requested slice), `total` (the count after
authorization filtering), plus the clamped `limit` and `offset` actually
applied. Non-integer values are rejected with `400`.

### Input size limits

Every caller-supplied string and list is bounded, and a value past its ceiling
is a `400` naming the field (STR-195). Two ceilings cover almost the whole
surface:

- **128 characters** for a `name` — and for anything else that behaves like one
  (a quota's `environment`, a project's environment labels). Names are trimmed
  of surrounding whitespace before they are measured and stored, and a name that
  is empty after the trim is rejected rather than accepted as blank.
- **4096 characters** for free text — every `description`, plus `cmdline`,
  an image's `defaultCmdline`, and `sshPublicKey`.

Fields with a grammar of their own keep it and are stricter: `userData` is
capped at 64 KiB and must open with a cloud-init header, a network's
`domainName` must be a sequence of RFC 1123 labels, and `sshPublicKey` must be a
single `<type> <base64 key> [comment]` line whose blob carries the same
algorithm name as its prefix. List inputs are bounded by cardinality too —
notably `securityGroupIds`, which is held to the same five-per-interface cap at
create that the attach endpoint enforces.

Characters are counted the way Postgres counts them, and the same ceilings are
enforced by `CHECK` constraints on the columns, so the API and the database
reject exactly the same values. Independently of any field, a collected request
body is capped at **1 MiB**; the image-upload and snapshot-transfer routes
stream instead of collecting and carry their own, much larger limits.

### Asynchronous mutations

VM, sandbox, volume and snapshot mutations (create/start/stop/restart/delete,
VM pause/resume/resize, volume attach/detach/resize, snapshot capture/delete/
export, and restore) are **asynchronous**. Each persists its desired-state
change plus an append-only audit record in one transaction and returns
`202 Accepted` with `{resource, targetGeneration, mutationId}`. Refetch the
resource and read its `conditions` (below); a **delete** is the one mutation the
resource cannot answer for — its success is the row's absence — so poll
`GET /api/operations/{mutationId}` for that one.

There is deliberately **no** "an operation is already pending" `409`: desired
state is level-triggered, so overlapping mutations are safe and the last one
written is the one the agent converges on. Restart and restore are counted
rather than commanded (a monotonic nonce on the resource's desired entry), so
they overlap safely too; both are refused with `409` only when the owning agent
is too old to apply them.

Responses carry a **`conditions`** block, which is how a mutation is followed:

```json
"conditions": {
  "converged": false,
  "targetGeneration": 14,
  "observedGeneration": 12,
  "phase": "downloading image",
  "degraded": { "reason": "image download failed", "sinceGeneration": 13 }
}
```

`converged` is true once the owning agent has confirmed converging to
`targetGeneration`, what it observes satisfies the desired state, and no attempt
at that same generation failed. A mutation is done when `observedGeneration`
reaches the `targetGeneration` its `202` returned and `converged` is true; it
failed when `degraded.sinceGeneration` equals that generation. **The two are
mutually exclusive** — a `degraded` naming `targetGeneration` always comes with
`converged: false` — so you never see both and never have to break a tie. The
block also reports *what* the agent is doing (`phase`), and `degraded` can name
an older generation than `targetGeneration` while a retry is in flight, which is
the case where a converged resource does carry one. Nothing stores it: it is
derived on read from the resource's generation counters and the convergence
progress its agent reports
([ADR 0001](/adr/0001-declarative-agent-protocol)).

`GET /api/operations/{id}` survives as a compatibility façade, synthesizing the
old operation shape from the audit record and these same conditions.

Image mutations are synchronous at the API layer: they return the resource
immediately (often in a transitional status such as `pending` or `creating`)
and converge in the background.

### Errors

Errors use a single envelope — a JSON object with a boolean `error` flag and a
human-readable `reason`.

## Scope

The document describes the **whole** JSON API: virtual machines, operations,
sandboxes and snapshots, images and artifacts, volumes, networks and floating
IPs, log queries, users and authentication, API keys, organizations, folders and
groups, projects and members, quotas, agents, sites, workload identity, IAM and
audit, and the identity-provider surfaces (OIDC, SCIM, and Shared Signals).

A CI route-drift test (`AppPlatformTests/OpenAPISpecDriftTests`) boots the app and
enforces both directions: no registered route may go undocumented, and no
operation may describe a route that does not exist. There is no quarantine list
— adding a route without documenting it fails the build.

WebSocket endpoints (the agent channel, VM consoles, and sandbox exec) are
intentionally **not** modeled as OpenAPI operations, since OpenAPI 3.0 cannot
express a protocol upgrade; they are documented as prose in the specification's
description.

## Generated code

The spec is not just documentation — three consumers are generated from it, so a
change to `openapi.yaml` propagates instead of drifting.

### Server handlers

Surfaces are being migrated off hand-written Vapor controllers onto handlers
generated by swift-openapi-generator, one at a time. `openapi-generator-config.yaml`
carries a `filter.operations` list naming the migrated operations; the generator
emits `APIProtocol` from exactly those, so the compiler forces the implementing
type to serve them all with the spec's parameter and body types. **Projects**
(`ProjectsAPIService`) is the first migrated surface.

Migrating a surface means: port its controller to a type conforming to
`APIProtocol`, list its operations in the generator config, delete the
controller, and drop its registration from `routes.swift`. Handlers reach the
Vapor `Request` — database, authenticated user, logger — through a task local
published by `OpenAPIRequestInjectionMiddleware`, which also unwraps the
runtime's `ServerError` so a thrown `Abort` still renders the standard error
envelope.

`OpenAPISpecDriftTests` additionally asserts, for migrated surfaces, that the
generated transport registered exactly the filtered operations, on the spec's
own paths and methods, and that no hand-written route shadows them.

### Swift client

[`clients/swift`](https://github.com/samcat116/strato/tree/main/clients/swift)
is a standalone SwiftPM package (`StratoAPIClient`) generating a client for the
**whole** API, plus a `BearerTokenMiddleware` for API-key auth. Its
`openapi.yaml` is a symlink to the control plane's, so there is one spec in the
repository and no sync step:

```swift
let client = Client(
    serverURL: URL(string: "https://strato.example.com")!,
    transport: AsyncHTTPClientTransport(),
    middlewares: [BearerTokenMiddleware(token: apiKey)]
)
let projects = try await client.listProjects().ok.body.json
```

### TypeScript types

The frontend generates `control-plane/web/src/types/openapi.ts` from the same
document with [openapi-typescript](https://openapi-ts.dev): run
`bun run generate:api-types` in `control-plane/web`. The generated file is
checked in, and CI fails if regenerating changes it.

The hand-maintained `src/types/api.ts` is being replaced surface by surface
rather than all at once — the projects API module already aliases the generated
schemas (`components["schemas"]["ProjectSummary"]`), which is the pattern to
follow for the rest.

### SCIM

The SCIM 2.0 data plane is registered in Vapor as a catch-all and dispatched
internally by SwiftSCIM's request processor. The spec describes the concrete
resource endpoints that processor serves — `/Users`, `/Groups`,
`/ServiceProviderConfig`, `/ResourceTypes`, `/Schemas` — so that generated
clients can call them, and the drift test matches those operations against the
catch-all registration.

SCIM requests authenticate with an org-scoped `scim_` bearer token rather than a
user session, and return RFC 7644 errors rather than the envelope above.
