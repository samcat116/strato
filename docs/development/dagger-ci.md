# Dagger CI

Strato's Dagger module is `.dagger/modules/strato-ci/main.dang`. It runs the
same containerized checks locally and through Dagger Cloud Checks. Use Dagger
**1.0.0-beta.21**, matching `dagger-module.toml`, and a running Docker engine
for local execution. This integration uses the beta's native Cloud Checks;
older Dagger releases do not support this workflow.

## Run checks

From the repository root:

```bash
dagger check -l                         # list available checks
dagger check                            # run every check
dagger check --check web-test            # frontend unit/component tests
dagger check --check web-browser         # Chromium tests with the mock API
dagger check --check control-plane-build # Linux compile check
dagger check -j 2                        # limit concurrent checks locally
dagger check -i                          # shell in a failed container
```

To see cache reuse, run the same command twice without changing its inputs:

```bash
time dagger check --progress plain
time dagger check --progress plain
```

The second run should show cached operations and complete much faster. This is
reuse of a previous result for identical inputs; it does not execute the test
body again. Changing a check's source, command, or dependencies invalidates the
affected operations. Images and external module references are pinned in
`dagger.lock`; commit that file with the configuration and module source.

## Coverage

| Check | Scope |
| --- | --- |
| `web-lint` | ESLint |
| `web-test` | Vitest unit/component tests |
| `web-build` | Next.js production build and TypeScript |
| `web-browser` | Chromium smoke tests with the checked-in mock backend |
| `api-types` | Regenerate OpenAPI TypeScript and compare with checked-in output |
| `openapi` | Redocly OpenAPI lint |
| `agent-build`, `cli-build`, `client-build`, `control-plane-build` | Swift 6.4 Linux production compilation |
| `swift-format` | Strict formatting of the PR CI source and test folders |
| `docs` | VitePress build and internal page links |

Swift tests remain opt-in, following the repository's existing CI policy:

```bash
dagger api call strato-ci swift-test --package shared sync
dagger api call strato-ci swift-test --package agent sync
dagger api call strato-ci swift-test --package cli sync
```

Use the existing **Full Test Suite (manual)** GitHub workflow for the complete
Swift suite, including control-plane tests with disposable PostgreSQL and cvc5.
The Dagger browser check does not exercise real passkeys, an actual control
plane, or guest VMs. Containers running on macOS are Linux checks; macOS package
resolution and native Apple Virtualization validation remain separate.

The existing GitHub Actions workflows still handle releases, deployment, Helm,
Rust guests, shell/artifact checks, and macOS validation. Their overlapping PR
checks also remain enabled. Migrating those required checks to Cloud Checks is
a separate change: verify GitHub branch protection before removing old jobs.
Until then, overlapping Actions and Cloud checks can execute twice on a cold
change; Dagger's cache does not eliminate that duplication across systems.

## Automatic Cloud Checks

After signing in and granting the Dagger GitHub integration access to
`samcat116/strato`:

```bash
dagger cloud checks on
dagger cloud checks status
```

Commit `dagger.toml`, `dagger.lock`, and `.dagger/modules/strato-ci/`, then push
your branch. Dagger Cloud receives the GitHub event and runs `dagger check` on
managed Cloud Engines. No additional Actions workflow or repository secret is
needed. Inspect the run with:

```bash
dagger workspace activity
dagger cloud checks status
dagger check --engine cloud             # run working-tree checks remotely
dagger cloud checks off                  # disable automatic runs
```

Cloud execution needs an active Dagger Cloud organization and plan. Inspect
`dagger cloud usage` and `dagger cloud billing` to manage usage and any trial.
Enabling the integration does not itself commit or push the local config.

## Feedback, compute, and agents

Independent checks can run concurrently. Dependencies install before source is
copied, so editing application code can reuse package installation. Each check
reads selected workspace paths; docs changes do not become Swift build inputs,
and frontend changes do not become backend build inputs. Swift scratch caches
use locked mounts to prevent concurrent builds from writing the same tree.

On a cache hit, Dagger reuses a successful operation instead of allocating
compute to repeat it. Cloud Engines can move work off a developer's machine
and share a cache among users of the same organization. Cache reuse depends
on matching inputs, platform, and engine/cache availability: a local ARM64
result does not promise a hit on a cold AMD64 cloud engine.

For coding agents, give a narrow command such as
`dagger check --check web-test`. The stable environment and check names reduce
repeated setup work and speculative debugging. Inspect the failing check or
its trace instead of repeatedly feeding a full build log into an LLM. The
module invokes no LLM and consumes no model tokens by itself; token savings
come from how the agent uses the feedback, not from an automatic reduction in
model pricing or context size.

See the official [checking guide](https://docs.dagger.io/using/checking/) and
[Cloud Checks setup](https://docs.dagger.io/cloud-checks/).
