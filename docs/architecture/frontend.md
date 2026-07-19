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
  `OperationWatcher`. Pages cover VMs, sandboxes, images, agents, networks,
  sites, storage (volumes/snapshots), projects, hierarchy, quotas,
  workload identity, admin (users/audit), and settings (API keys/org).

Two conventions worth knowing:

- Detail pages use a static `/detail` segment reading the ID from query params
  (`vms/detail?id=...`), not dynamic routes; `projects/[projectId]` is the
  only dynamic segment.
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
`networks.ts`, `quotas.ts`, `workload-identity.ts`, ...) are typed against the
hand-maintained DTO definitions in `types/api.ts` (there is no codegen).
Domain-specific error prettifying lives in `lib/errors.ts`.

**Server state — TanStack Query** (`providers/query-provider.tsx`; defaults:
60s stale time, no window-focus refetch, one retry). Hooks live one file per
resource under `lib/hooks/`:

- Query keys are arrays led by the resource name — `["vms", { orgId }]`,
  `["vms", id]` — so invalidation can target the leading segment.
- Mutations invalidate in `onSuccess`; live resources poll via
  `refetchInterval` (VMs every 5s; image status polls until it settles).
- `lib/hooks/use-permissions.ts` batches permission checks to the
  authorization API and caches them fail-closed — UI gating asks the backend
  rather than hardcoding roles.

**Async operation polling.** VM and sandbox lifecycle mutations return a
**202 + Operation** rather than the resource (see the async-operations
section of [overview](./overview.md)). The frontend flow:

1. The mutating component passes the returned operation to
   `useOperationsStore().watch(operation, resourceName)`.
2. `components/vms/operation-watcher.tsx` — a singleton mounted in the
   dashboard layout so it survives navigation — polls each watched operation
   every 2s until terminal, then toasts the outcome and invalidates the
   resource list for the operation's `resourceKind`.

**Client state — Zustand.** Exactly one store:
`lib/stores/operations-store.ts` (the watched-operations map above, plus a
`usePendingOperation(resourceId)` selector for status badges). Everything
else is server cache or React context: the provider stack
(`providers/index.tsx`) nests Theme → Query → Auth → Organization → Project,
and project selection persists to `localStorage` per organization.

## Components

One directory per feature under `components/` (vms, sandboxes, images,
agents, networks, quotas, hierarchy, workload-identity, audit, terminal, ...),
with shadcn/ui primitives ("new-york" style, Radix under the hood) in
`components/ui/`. Forms use react-hook-form + zod; toasts are sonner; icons
are lucide-react.

The most involved pieces:

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

`providers/auth-provider.tsx` probes `GET /auth/session` on mount and exposes
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
  added at runtime by `src/middleware.ts`, gated on `X-Forwarded-Proto`.
- Anything an operator must be able to change **without rebuilding** cannot live
  in `next.config.ts` — `NEXT_PUBLIC_*` values are inlined into the bundle at
  build time, and deployments run a prebuilt image. Such settings are read per
  request in `src/middleware.ts` instead: `STRATO_API_URL` for same-origin API
  proxying, and `STRATO_GRAVATAR_ENABLED` (default on), which middleware
  publishes to the browser on a non-`httpOnly` `strato_gravatar` cookie that
  `components/ui/user-avatar.tsx` reads. Disabling it stops the UI from sending
  any email hash to gravatar.com and falls back to initials avatars.
- **Dev**: `rewrites()` (development only) proxy `/api`, `/auth`, `/agent`,
  `/health`, and `/organizations` to `NEXT_PUBLIC_API_URL` (default
  `http://localhost:8080`) — this is what makes `bun run dev` work against a
  natively-running control plane.
- **Deployed**: `control-plane/web/Dockerfile` builds with Bun and runs the
  standalone server on Node as a non-root user. In the compose deployment,
  `deploy/compose/nginx.conf` splits traffic: `/api/`, `/auth/`, `/agent/`,
  `/health`, `/organizations/` go to the control plane (with hour-long read
  timeouts for the WebSockets), everything else to the frontend.
- **Tailwind v4** is configured CSS-first: no `tailwind.config`; the theme
  lives in `app/globals.css` via `@theme`, processed by
  `@tailwindcss/postcss`.

## Linting and testing

ESLint 9 flat config extends `eslint-config-next` (`bun run lint`);
TypeScript is strict with the `@/*` path alias. There is currently no
frontend test suite — CI enforces `lint` and `build` only.
