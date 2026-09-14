# Repository guidance

Work in the current session's worktree; preserve unfamiliar changes and leave
sibling checkouts alone. Resolve the root with `git rev-parse --show-toplevel`.

Complete the requested change and its relevant validation, fixing regressions
caused by the change before handing it back. Local builds and tests against
configured disposable fixtures can proceed without repeated approval. Report
which packages and platforms were verified and any remaining blockers.

## References by task

- Build, test, or local service setup: [local development](docs/development/local-development.md).
  Swift packages are independent; the frontend uses Bun.
- Review or prepare a PR: [code review](docs/development/code-review.md).
- Change service boundaries or reconciliation: [architecture overview](docs/architecture/overview.md)
  and the relevant component or subsystem page beside it.
- Resolve domain terminology or architecture decisions: [domain guidance](docs/agents/domain.md).
- Run a full stack and real VM lifecycle: [E2E skill](.agents/skills/e2e/SKILL.md).
- Work on the `strato-dev` VM: [host notes](docs/agents/strato-dev.md).
- Deploy with Kubernetes: [deployment guide](docs/deployment/kubernetes.md).
- Work with tickets: [issue tracker](docs/agents/issue-tracker.md);
  assign triage labels using [the label mapping](docs/agents/triage-labels.md).

## Cross-cutting invariants

- Authentication stays enabled. Agents use SPIFFE/SPIRE X.509 SVIDs over mTLS;
  local UI access uses a real WebAuthn passkey user.
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
