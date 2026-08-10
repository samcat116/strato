# Strato web frontend

This directory contains Strato's Next.js dashboard. It is a separate API
consumer: browser requests use same-origin `/api`, `/auth`, and WebSocket paths,
which Next.js proxies to the control plane during development and the deployment
proxy routes in production.

## Local development

Install [Bun](https://bun.sh), start a control plane, then run:

```bash
bun install --frozen-lockfile
NEXT_PUBLIC_API_URL=http://localhost:8080 bun run dev
```

The dashboard is served at `http://localhost:3000`. Authentication is not
stubbed in development, so use an account from the control plane you started.

## Commands

| Command | Purpose |
| --- | --- |
| `bun run dev` | Start the development server with API rewrites |
| `bun run lint` | Run ESLint |
| `bun run build` | Create the production standalone build |
| `bun run start` | Serve a completed build on `${PORT:-3000}` |
| `bun run generate:api-types` | Refresh `src/types/openapi.ts` from the control-plane OpenAPI document |

The generated OpenAPI types are committed. After changing
`../Sources/App/openapi.yaml`, run `bun run generate:api-types` and include the
result in the same change. Most endpoint modules still use the hand-maintained
DTOs in `src/types/api.ts`; new migrations to generated types happen one API
surface at a time.

## Architecture and deployment

See [Frontend Architecture](../../docs/architecture/frontend.md) for the route,
state, authentication, and mutation-convergence design. The production image is
built by this directory's `Dockerfile` and runs Next.js standalone output as a
non-root user.
