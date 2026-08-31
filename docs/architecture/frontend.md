# Frontend Architecture

The dashboard is a Next.js (App Router) + React 19 application at
`control-plane/web/`, deployed as the separate `strato-frontend` container.
It is a pure API consumer: all state comes from the control plane's JSON API
over cookie-authenticated `fetch`, and the app never hardcodes a backend host —
requests use relative paths (`/api/...`, `/auth/...`) and a reverse proxy (or
Next dev rewrites) routes them.

Package management and scripting use **Bun** (`bun install`, `bun run build`,
`bun run lint`).

## Route structure

Everything lives under `control-plane/web/src/`:

- `app/layout.tsx` — root server component: fonts, `globals.css`, and the
  provider stack.
- `app/page.tsx` — client redirect gate to `/dashboard` or `/login`.
- **`(auth)` group** — unauthenticated flows: `login`, `register`, `claim`
  (passkey claim for admin-created accounts), `onboarding` (first-run org
  creation).
- **`(dashboard)` group** — `(dashboard)/layout.tsx` is the auth wall: it
  redirects unauthenticated users to `/login` (and users with zero orgs to
  `/onboarding`), and mounts the `Sidebar`, `Header`, and the global
  `MutationWatcher`. Pages cover VMs, sandboxes, images, agents, networks,
  sites, storage (volumes/snapshots), projects, hierarchy, quotas,
  workload identity, admin (users/audit), and settings (API keys/org).

Two conventions worth knowing:

- Resource details use dynamic segments (`vms/[id]`, `sandboxes/[id]`,
  `agents/[id]`, and `images/[projectId]/[id]`). The former `/detail?...`
  URLs remain as server-side compatibility redirects, not duplicate page
  implementations.
- The nav is data-driven: `components/layout/nav.ts` defines a two-level
  `navTree` with `adminOnly` gating and active-state helpers. Frontend routes
  must not live under `/organizations` — the deploy proxy routes that prefix
  to the control plane (see Deployment below).

## Data layer

**API client** (`lib/api/client.ts`): a single generic `apiClient<T>` over
`fetch` with `credentials: "include"` — auth is entirely cookie-session based;
no tokens are stored in JS. It parses Vapor `{reason}`/`{error}` bodies into
an `ApiError`, hard-redirects to `/login` on 401 (except on auth endpoints),
and rewrites generic 403s into a permissions message. Per-resource endpoint
modules (`lib/api/vms.ts`, `sandboxes.ts`, `agents.ts`, `images.ts`,
`networks.ts`, `quotas.ts`, `workload-identity.ts`, ...) carry the types.
`bun run generate:api-types` (openapi-typescript) generates
`src/types/openapi.ts` from the control plane's OpenAPI document — the same
one its handlers are generated from, so the types cannot drift from the
server, and CI fails when the committed file is stale. API modules import
`types/api-contracts.ts`, which binds their request and response shapes to the
generated schema while retaining the UI compatibility guarantees in
`types/api.ts`; feature components do not import raw wire schemas directly.
Domain-specific error prettifying lives in `lib/errors.ts`.

**Server state — TanStack Query** (`providers/query-provider.tsx`; defaults:
60s stale time, stale-query window-focus refetch, one retry). Hooks live one file per
resource under `lib/hooks/`:

- Query keys are arrays led by the resource name — `["vms", { orgId }]`,
  `["vms", id]` — so invalidation can target the leading segment.
- Mutations invalidate in `onSuccess`; live resources poll via
  `refetchInterval` (VMs every 5s; image status polls until it settles).
- `lib/hooks/use-permissions.ts` batches permission checks to the
  authorization API and caches them fail-closed — UI gating asks the backend
  rather than hardcoding roles.

**Refetch until converged.** VM and sandbox lifecycle mutations answer
**202 + `{resource, targetGeneration, mutationId}`** (see the
async-mutations section of [overview](./overview.md)). The frontend flow:

1. The mutating component passes what came back to
   `useMutationsStore().watch(acceptedMutation(...))`.
2. `components/vms/mutation-watcher.tsx` — a singleton mounted in the
   dashboard layout so it survives navigation — refetches the resource every
   2s and reads its `conditions` against `targetGeneration`, then toasts the
   outcome and invalidates the resource list for its `resourceKind`. The poll
   re-schedules itself rather than running on an interval, so passes over
   several watched mutations cannot pile up, and a mutation is given up on only
   after several consecutive read failures — one 502 from the proxy must not
   silently kill the toast for a create the user is waiting on.

Snapshot mutations and deletes take a different observation path, and the
watched entry says which (`source`) rather than the watcher guessing from the
verb. They return the same accepted-mutation envelope as every other mutation;
snapshot entries are adapted with `acceptedSnapshotMutation(...)` because
snapshots have no single-resource GET, while deletes have no resource left to
refetch after success. Both poll `operationsApi.get(mutationId)`, whose answer
is derived from the resource event and conditions rather than an operation
job.

`degraded` is matched by generation, not presence: a failure can stand against
an older generation while a newer mutation is in flight, and reporting that as
*this* mutation's failure would be wrong. A failure matching the generation is
that mutation's verdict, and the resource reads `converged: false` beside it —
the watcher checks `degraded` first anyway, which is what kept it right while
the two could both hold (STR-191).

Volume Snapshot and Clone are the one place the UI must *not* gate on
`conditions.converged`. Both mirror the backend's guards, and the backend asks
`Volume.bytesAtRest` there — "nothing is mid-write" rather than "the last change
landed" — because nothing clears a failed resize's generation, so gating on
convergence would grey the two verbs out permanently. `lib/volume-guards.ts`
holds that mirror.

**Client state — Zustand.** Exactly one store:
`lib/stores/mutations-store.ts` (the watched-mutations map above, plus a
`usePendingMutation(resourceId)` selector for status badges). Everything
else is server cache or React context: the provider stack
(`providers/index.tsx`) nests Theme → Query → Auth → Organization → Project,
and project selection persists to `localStorage` per organization.

## Components

One directory per feature under `components/` (vms, sandboxes, images,
agents, networks, quotas, hierarchy, workload-identity, audit, terminal, ...),
with shadcn/ui primitives ("new-york" style, Radix under the hood) in
`components/ui/`. Forms use feature-local React state and the shared input,
label, select, and dialog primitives; toasts are sonner; icons are
lucide-react.

The most involved pieces:

- **Graphics console** (`components/vms/vnc-display.tsx` + `lib/hooks/use-vnc.ts`):
  noVNC (`@novnc/novnc`) rendering a VM's framebuffer in the Display tab. Two
  steps, like sandbox exec: POST mints a session, then the returned
  `websocketPath` is opened and — after the server's `{"type":"ready"}` — the
  **live WebSocket** is handed to `RFB`. Passing the socket rather than a URL is
  what lets that handshake gate exist; given a URL, noVNC would emit the RFB
  version string before the agent's end of the relay existed and stall with no
  error. noVNC touches `document` at module scope, so it is imported inside the
  effect and the component is loaded through `next/dynamic` with `ssr: false`.
- **Terminals** (`components/terminal/`): `console-terminal.tsx` (VM serial
  console) and `sandbox-terminal.tsx` drive xterm.js; the WebSocket logic is
  in `lib/hooks/use-console.ts` and `use-sandbox-exec.ts`. Sockets are opened
  same-origin (`wss://<host>/api/vms/{id}/console`, and the `websocketPath`
  returned by the sandbox exec endpoint). The hooks memoize callbacks by ref
  so 5-second polling re-renders don't tear down live sockets.
- **Overview dashboard** (`components/overview/`): hand-rolled capacity/
  health charts — there is deliberately no chart library dependency.
- **Workload identity** (`components/workload-identity/`): the SPIFFE/SPIRE
  view, built as a presentational component over data from
  `lib/api/workload-identity.ts`.

## Authentication flow

The root server layout loads session, organization, and project bootstrap data
at request time and seeds the provider/query caches. If a server-side API URL
is unavailable, `providers/auth-provider.tsx` falls back to probing
`GET /auth/session` on mount. It exposes
`user` / `login` / `register` / `logout`. WebAuthn ceremonies live in
`lib/webauthn/client.ts`, which implements all three passkey flows
(register, login, claim) against the `/auth/*` endpoints, handling
base64url ↔ ArrayBuffer conversion. Logout honors an optional `sloUrl` in the
response: OIDC-established sessions get a full navigation to the IdP's
RP-initiated logout.

Route guarding is client-side (the dashboard layout redirect); admin-only UI
keys off `user.isSystemAdmin`. There is no unauthenticated mode: every
environment, development included, goes through the same passkey flows.

## Build and deployment

- `next.config.ts` sets `output: "standalone"` and bakes build identity into
  the bundle (`NEXT_PUBLIC_APP_VERSION`, `NEXT_PUBLIC_GIT_SHA`, rendered in
  the sidebar via `lib/version.ts`). Security headers are set here; HSTS is
  added at runtime by `src/proxy.ts`, gated on `X-Forwarded-Proto`.
- Anything an operator must be able to change **without rebuilding** cannot live
  in `next.config.ts` — `NEXT_PUBLIC_*` values are inlined into the bundle at
  build time, and deployments run a prebuilt image. Such settings are read per
  request in `src/proxy.ts` instead: `STRATO_API_URL` for same-origin API
  proxying and server bootstrap, and `STRATO_GRAVATAR_ENABLED` (default on),
  which the proxy
  publishes to the browser on a non-`httpOnly` `strato_gravatar` cookie that
  `components/ui/user-avatar.tsx` reads. Disabling it stops the UI from sending
  any email hash to gravatar.com and falls back to initials avatars.
- **Dev**: `rewrites()` (development only) proxy `/api`, `/auth`, `/agent`,
  `/health`, and `/organizations` to `NEXT_PUBLIC_API_URL` (default
  `http://localhost:8080`) — this is what makes `bun run dev` work against a
  natively-running control plane.
- **Deployed**: `control-plane/web/Dockerfile` builds with Bun and runs the
  standalone server on Node as a non-root user. In the compose deployment,
  `deploy/compose/nginx.conf` splits traffic: `/api/`, `/auth/`, `/oauth/`
  (the CLI's OAuth device grant), `/agent/`, `/health`, `/organizations/`,
  and `/ssf/` (the Shared Signals receiver) go to the control plane (with
  hour-long read timeouts for the WebSockets), everything else to the
  frontend.
- **Tailwind v4** is configured CSS-first: no `tailwind.config`; the theme
  lives in `app/globals.css` via `@theme`, processed by
  `@tailwindcss/postcss`.

## Linting and testing

ESLint 9 flat config extends `eslint-config-next` (`bun run lint`);
TypeScript is strict with the `@/*` path alias. Vitest and Testing Library
cover hooks, providers, routing helpers, and components (`bun run test`).
Playwright exercises critical browser navigation against a deterministic mock
control plane (`bun run test:e2e`). CI enforces unit tests, browser smoke tests,
lint, and the production build.
