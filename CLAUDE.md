# CLAUDE.md

Repository guidance for Claude Code.

## Worktrees

- Work only in the current session's worktree. Never edit
  `/Users/sam/Projects/Active/strato/` directly.
- Derive paths from `git rev-parse --show-toplevel`; shell calls do not retain a
  previous `cd`.
- Preserve unfamiliar changes. Other sessions can work in sibling worktrees.

## Pull requests

- Before opening a PR and before declaring it ready, fetch and merge
  `origin/main`, then resolve conflicts locally.
- Ignore usage-limit comments from `chatgpt-codex-connector[bot]`.
- Use `/pr-comments` for unresolved review threads.
- Apply the checklist and Strato-specific traps in
  `docs/development/code-review.md`.

## Build, test, and format

The independent Swift packages are `control-plane/`, `agent/`, `shared/`,
`cli/`, `clients/swift/`, and vendored `SwiftFirecracker/`.

- Build with `swift build --package-path <package>` and test with
  `swift test --package-path <package>`. Swift tests use Swift Testing.
- Run every touched package's complete suite. PR CI is a compile check; the
  manual `main-tests.yaml` workflow runs the full suite on CI runners.
- Control-plane tests require PostgreSQL. Defaults are localhost:5432, user
  `strato`, password `strato_password`, database `strato_test`. The harness
  clones a migrated template database per test.
- Treat a one-off `ServeCommand did not shutdown before deinit` failure as the
  known Vapor teardown race only after a clean rerun.
- Swift builds can take more than ten minutes from a cold worktree. Use a
  suitable timeout.
- Format Swift with `swift format --in-place --recursive <changed dirs>` and
  lint with the same repository configuration.
- In `control-plane/web`, use Bun. Run `bun run lint`, `bun run test`, and
  `bun run build` as appropriate.

## Local services and deployment

- Local development and PostgreSQL setup: `docs/development/local-development.md`.
- Control plane: `swift run --package-path control-plane`.
- Agent: `swift run --package-path agent StratoAgent --config-file ./config.toml`.
  Configuration precedence is CLI, environment, then TOML. Start from
  `config.toml.example`.
- Agents authenticate only with SPIFFE/SPIRE X.509 SVIDs over mTLS. Enrollment
  starts at `POST /api/agent-enrollments` or **Agents → Add Agent**.
- Authentication is always enabled. Local setup registers a real WebAuthn
  passkey user.
- Docker Compose is under `deploy/compose/`; run `setup.sh` before bringing up
  the stack. Put local changes in untracked `docker-compose.override.yml`.
- Kubernetes deployment is under `helm/strato-control-plane/`; canonical steps
  are in `docs/deployment/kubernetes.md`.
- The docs site is VitePress: `npm run docs:dev` and `npm run docs:build`.

## strato-dev

On the Ubuntu VM at `/home/sam/strato`:

- The UI is `https://strato-dev.tail21c16.ts.net`; the user browses from their
  Mac. Do not direct them to localhost or bind port 443.
- Compose builds from source. Keep overrides in
  `deploy/compose/docker-compose.override.yml`.
- Control-plane tests use PostgreSQL on port 5433 with the standard test
  credentials above.
- First-user WebAuthn registration requires the user's browser.
- `sudo` requires a password; give the user the exact root command.
- This VM is disposable. A requested deployment cleanup may remove all
  `strato-*` containers and volumes.

## Architecture

Start with `docs/architecture/overview.md`. Component maps live beside it:
`control-plane.md`, `agent.md`, `wire-protocol.md`, `frontend.md`, and the
subsystem pages for scheduling, networking, DNS, storage, sandboxes, IAM,
multi-replica operation, and agent updates. `CONTEXT.md` is the domain glossary;
architectural decisions live in `docs/adr/`.

Preserve these cross-cutting invariants:

- Desired state is level-triggered and generation-guarded. The agent pulls it;
  Valkey doorbells reduce latency but are not a source of truth.
- A generation is converged only when its failure generation differs. Success
  and same-generation degradation are mutually exclusive.
- A delete verdict comes from terminal event evidence or row absence, never
  from resource conditions.
- Coordination data fails open. Session storage does not: losing it logs users
  out and is a readiness failure when independently configured.
- The `agent:{name}:replica` route and one-way RPC bridge remain live for guest
  execution and recorded command delivery.
- QEMU/libvirt, Firecracker, and production OVN networking are Linux-only.
  Non-Linux agents must not advertise those capabilities.
- The user-facing term is **folder**; the database and wire still use
  `OrganizationalUnit` until that compatibility rename is completed.

## Agent references

- Issue tracker workflow: `docs/agents/issue-tracker.md`.
- Triage vocabulary: `docs/agents/triage-labels.md`.
- Domain-document workflow: `docs/agents/domain.md`.
