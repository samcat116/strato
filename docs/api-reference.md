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
  `POST /api/api-keys`. Keys carry scopes (`read`, `write`).
- **Session cookie** (`vapor-session`) — set after a WebAuthn/passkey login.

Per-object access is additionally enforced by the built-in IAM system (an
in-process Cedar policy evaluator); an authenticated-but-unauthorized caller
receives `403`.

### Asynchronous mutations

VM and sandbox lifecycle mutations (create/start/stop/restart/delete, VM
pause/resume, sandbox snapshot/restore) are **asynchronous**. They persist a
desired-state change plus a `ResourceOperation` in one transaction and return
`202 Accepted` with that operation. Poll `GET /api/operations/{operationID}`
until `status` is terminal (`succeeded` or `failed`). A second mutation on a
resource that already has a pending operation is rejected with `409`.

Image and volume mutations are synchronous at the API layer: they return the
resource immediately (often in a transitional status such as `pending` or
`creating`) and converge in the background.

### Errors

Errors use a single envelope — a JSON object with a boolean `error` flag and a
human-readable `reason`.

## Scope

The document describes the **whole** JSON API: virtual machines, operations,
sandboxes and snapshots, images and artifacts, volumes, networks and floating
IPs, log queries, users and authentication, API keys, organizations, folders and
groups, projects and members, quotas, agents, sites, workload identity, IAM and
audit, and the identity-provider surfaces (OIDC, SCIM, and Shared Signals).

A CI route-drift test (`AppTests/OpenAPISpecDriftTests`) boots the app and
enforces both directions: no registered route may go undocumented, and no
operation may describe a route that does not exist. There is no quarantine list
— adding a route without documenting it fails the build.

WebSocket endpoints (the agent channel, VM consoles, and sandbox exec) are
intentionally **not** modeled as OpenAPI operations, since OpenAPI 3.0 cannot
express a protocol upgrade; they are documented as prose in the specification's
description.

### SCIM

The SCIM 2.0 data plane is registered in Vapor as a catch-all and dispatched
internally by SwiftSCIM's request processor. The spec describes the concrete
resource endpoints that processor serves — `/Users`, `/Groups`,
`/ServiceProviderConfig`, `/ResourceTypes`, `/Schemas` — so that generated
clients can call them, and the drift test matches those operations against the
catch-all registration.

SCIM requests authenticate with an org-scoped `scim_` bearer token rather than a
user session, and return RFC 7644 errors rather than the envelope above.
