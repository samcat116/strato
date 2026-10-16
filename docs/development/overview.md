# Developer guide

Strato contains independent Swift packages and a Next.js frontend. Start with
[Local development](./local-development.md) for prerequisites and commands;
[Getting started](../guide/getting-started.md) is the installation path.

## Choose the component and checks

| Working on | Start here | Validation |
| --- | --- | --- |
| API, database, scheduler, IAM | [Control plane](../architecture/control-plane.md) | Control-plane package checks; tests require disposable PostgreSQL |
| Hypervisor, storage, networking, reconciliation | [Agent](../architecture/agent.md) | Agent package checks; real backend behavior requires Linux fixtures |
| Protocol or shared DTOs | [Wire protocol](../architecture/wire-protocol.md) | Shared package and affected consumers |
| Browser UI | [Frontend](../architecture/frontend.md) | Bun scripts in `control-plane/web/` |
| CLI | [CLI onboarding](../guide/getting-started.md#install-the-cli) | CLI package checks |
| Documentation | [Documentation map](../documentation.md) | Root npm toolchain, `npm run docs:build`, and link/fragment checks |

The generated Swift API client lives in `clients/swift/`; `SwiftFirecracker/`
is a vendored package. Package checks are independent. Use the
[validation scope](./local-development.md#validation-scope) to choose the
checks for your change and report what actually ran. Swift PR CI compiles
production targets; it does not substitute for Swift test evidence.

## Read the contract before changing behavior

The [architecture overview](../architecture/overview.md) maps subsystem
boundaries. The [architecture decisions](../documentation.md#architecture-decisions)
record why the contracts exist. Preserve generation guards, agent-pulled desired
state, default-deny authorization, and the distinction between coordination and
session storage failures.

For integrated Linux VM lifecycle checks, follow
[End-to-end testing](./e2e-testing.md). A documentation build, mock agent, or
macOS package check cannot validate KVM, libvirt, Firecracker, or OVN behavior.
Do not describe unrun acceptance cases as verified.

## Prepare a change for review

Follow the repository's `AGENTS.md`, preserve unrelated work, and read the
[code review guide](./code-review.md). Keep subsystem documentation with its
implementation, update relevant API types when the spec changes, and describe
validation coverage and remaining blockers in the PR.

Documentation contributors should keep existing page URLs and anchors where
possible. Add new pages to the navigation and [documentation map](../documentation.md),
link to canonical configuration guides rather than duplicating them, and label
proposal, opt-in, and untested behavior explicitly. Internal `docs/agents/`
guidance is repository-only and excluded from the public site.
