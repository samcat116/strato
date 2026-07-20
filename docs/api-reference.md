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

Per-object access is additionally enforced by relationship-based authorization
(SpiceDB); an authenticated-but-unauthorized caller receives `403`.

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

The document is filled in incrementally (see
[issue #557](https://github.com/samcat116/strato/issues/557)). It currently
covers the core compute and infrastructure surfaces — virtual machines,
operations, sandboxes and snapshots, images and artifacts, volumes, networks,
and floating IPs — with the remaining IAM/organization, agent, user, and
identity-provider surfaces to follow. A CI route-drift test keeps the documented
controllers from silently diverging from the spec.

WebSocket and streaming endpoints (the agent channel, VM consoles, sandbox
exec, and Loki-backed log queries) are intentionally **not** modeled as OpenAPI
operations; they are documented as prose in the specification's description.
