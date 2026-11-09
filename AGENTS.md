# Repository Guidelines

## Working in this repository

Work in this session's worktree (`git rev-parse --show-toplevel`); preserve unfamiliar
changes and sibling checkouts. Validate and fix regressions. Local builds/disposable-fixture
tests need no repeated approval; report packages, platforms, and blockers.

## Project structure

Independent Swift packages: `control-plane/`, `agent/`, `shared/`, `cli/`,
`clients/swift/` (generated client), and `SwiftFirecracker/` (vendored).
Each uses `Sources/` and `Tests/`. Next.js UI: `control-plane/web/src/`;
browser tests: `control-plane/web/e2e/`; Rust guests: `sandbox-guest/`;
deployment assets: `deploy/` and `helm/`; documentation: `docs/`.

## Build, test, and development

Read [local development](docs/development/local-development.md) for prerequisites,
fixtures, solver-dependent tests, and full-stack setup.

- `swift build --package-path agent`: compile; substitute other package paths.
- `swift test --package-path shared --filter <SuiteName>`: run focused Swift tests.
- In `control-plane/web/`, use Bun: `bun install`, `bun run dev`,
  `bun run lint`, `bun run test`, `bun run test:e2e`, `bun run build`.
- Root: `npm ci`, `npm run docs:build` build/check VitePress.

Use Swift Testing (`@Test`, `#expect`), scenario names, and `*Tests.swift` files;
frontend tests use Vitest (`*.test.ts[x]`) and Playwright.
Control-plane tests require disposable PostgreSQL and the template-clone harness.
Cover affected consumers; broaden suites for shared-contract changes.
PR CI runs focused agent-protocol compatibility tests; complete Swift package
suites remain a local/manual validation responsibility.

## Style and pull requests

Swift uses `.swift-format`: four-space indentation, 120 columns.
Run `swift format lint --strict --recursive <changed dirs>`; frontend lint uses ESLint.
Use UpperCamelCase types and lowerCamelCase members. API changes update OpenAPI and
`bun run generate:api-types` output together.

Use imperative commit subjects; history also uses `fix:`/`docs:` and `STR-123`.
PRs explain behavior, linked issues, and validation;
include screenshots for UI changes. Consult [code review](docs/development/code-review.md).

## Task references

- Architecture/reconciliation: [overview](docs/architecture/overview.md) and subsystem pages.
- Terminology/decisions: [domain guidance](docs/agents/domain.md).
- Real VM validation: [E2E skill](.agents/skills/e2e/SKILL.md).
- `strato-dev`: [host notes](docs/agents/strato-dev.md).
- Kubernetes: [deployment](docs/deployment/kubernetes.md).
- Tickets: [tracker](docs/agents/issue-tracker.md), [triage labels](docs/agents/triage-labels.md).

## Cross-cutting invariants

- Keep authentication enabled: SPIFFE/SPIRE X.509 SVIDs over mTLS for agents;
  real WebAuthn passkeys for local UI access.
- Agents pull level-triggered, generation-guarded desired state;
  Valkey doorbells optimize latency, never provide truth.
- Convergence requires a differing failure generation; same-generation success
  and degradation are mutually exclusive.
- Delete verdicts require terminal events or row absence, never resource conditions.
- Coordination data fails open. Session storage does not: losing it logs users
  out and is a readiness failure when independently configured.
- The `agent:{name}:replica` route and one-way RPC bridge remain live for guest
  execution and recorded command delivery.
- Advertise QEMU/libvirt, Firecracker, and production OVN capabilities only on Linux.
- Say **folder** in UI; database/wire retain `OrganizationalUnit`.

<!-- entire-agent:begin -->
Read .entire/agent-guide.md for this repository's workflow, source inspection, and verification guidance.
@.entire/agent-guide.md
<!-- entire-agent:end -->
