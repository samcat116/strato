---
name: e2e
description: Run Strato's full stack and real VM lifecycle when asked for system E2E validation or VM boot proof.
---

# Strato E2E validation

Use `deploy/compose/e2e-up.sh` and `e2e-agent.sh` for setup. The
[runbook](../../../docs/development/e2e-testing.md) owns commands and platform
requirements. Consult its prerequisites and setup sections when bringing up a
host, VM sections for lifecycle checks, and traps when diagnosing failures.

## Execution boundaries

- Reuse the deployment unless a reset is requested. `--fresh` removes Compose
  volumes, including users, VM records, and passkey credentials; agent `reset`
  also removes cached SVIDs and local VM state. Obtain authorization for that
  deletion if the user has not already given it. Preserve the scripts' guards.
- `--no-build` tests existing images. To validate source changes, use the
  runbook's build override and rebuild the affected images and agent. A rebuild
  does not require `--fresh`. Allow cold builds to run in the background.
- Run the printed agent command with its exact `RUN_DIR`. If root access needs
  an interactive password, relay the command and wait for that step; otherwise
  use available authorized root access and continue through registration.
- If UI access is part of the request, supply `--admin-email` at bootstrap;
  see the runbook's headless-admin recovery for an existing deployment.

## Completion

A full E2E request includes create, start, guest boot evidence, console,
stop/start, and deletion with host cleanup evidence, as described in the
runbook. Continue through these checks and diagnose failures within the
requested scope. A setup smoke test or `Running` status alone is insufficient.
For a request limited to setup or one contract, stop at that requested outcome.

Report the source or images tested, host/backend, checks passed or failed,
evidence, and any remaining environment or user-action blocker. Consult
[teardown](../../../docs/development/e2e-testing.md#tearing-down) for requested
cleanup; volume deletion retains the authorization boundary above.
