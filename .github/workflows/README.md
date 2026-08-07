# GitHub Actions Workflows

This directory contains GitHub Actions workflows for the Strato project. Workflows use a **hybrid runner strategy**: the heavy Swift compile and release binary jobs run on the `swift-runners-strato` runner scale set (self-hosted, managed by [actions-runner-controller](https://github.com/actions/actions-runner-controller)); the static self-hosted runner only builds the Linux release-asset tarball; everything else — Docker image assembly from prebuilt binaries, frontend lint/build, Helm tests, ARM64/macOS builds, release housekeeping — runs on GitHub-hosted runners so it doesn't queue behind Swift work. PR and main-branch workflows also use `concurrency` groups to cancel superseded runs on new pushes.

## No Swift tests run automatically (read this first)

**CI does not run `swift test` anywhere on a push or a pull request.** PR
validation is a *compile check*: it builds each package without
`--build-tests`, so the test targets are not even type-checked. This was a
deliberate trade — the project has no customers or deployments yet, and the
control-plane suite alone was 342s of an 8-minute PR run.

Consequences worth internalizing:
- Running the suite before you merge is a human responsibility. See `CLAUDE.md`
  and `docs/development/local-development.md`.
- A test file that stops compiling will merge green. Building with
  `--build-tests` but not running the suite would close exactly that gap for a
  fraction of the test run's cost, and is the obvious dial to turn if this ever
  bites: the measured 342s was the `swift test` invocation, and dropping the
  test-target compile on top of it is what took the control-plane job from 179s
  to ~65s. It is off because both halves were wanted, not because the middle
  setting doesn't work.
- `Full Test Suite (manual)` (`main-tests.yaml`) is the escape hatch: dispatch
  it from the Actions tab or with `gh workflow run main-tests.yaml --ref
  <branch>` to run everything on the ARC runners.

Two non-Swift test gates do still run on PRs, because both are cheap and
hosted: the Helm chart lint/template/security jobs (`helm-test.yml`, on
`helm/**`) and the Rust `cargo fmt`/`test`/`clippy` gate for the sandbox guest
init (`sandbox-guest.yaml`, on `sandbox-guest/**`).

## Workflows

### PR Validation (`build.yaml`)
Runs on pull requests. Compile and lint only — no tests:
- Swift format lint, OpenAPI spec lint, frontend lint & build (GitHub-hosted)
- Swift compile check — agent, CLI, generated API client, control plane
  (`swift-runners-strato` ARC scale set). `shared/` and `SwiftFirecracker/`
  have no standalone step: both are path dependencies the agent and control
  plane already compile.
- `Package.resolved` macOS drift check (`macos-14`, ~90s, compiles nothing) —
  the one gating step of the deleted macOS agent job. The manifest gates
  Linux-only products with `.when(platforms:)` rather than `#if os(Linux)`, so
  resolving on macOS must produce identical pins; Linux cannot catch a
  regression here by construction.
- Frontend Docker image build check, gated on `control-plane/web/Dockerfile`

A `changes` job (via `dorny/paths-filter`) detects which parts of the repo
changed and gates each job with `if:`, so docs-only PRs skip the Swift build,
frontend-only PRs skip Swift, etc. Because the jobs are skipped via `if:`
(not workflow-level `on.paths`), a skipped job still reports as a passing
check and remains safe to use as a required status check. In-progress runs are
cancelled when a new commit is pushed to the same PR.

#### The Swift Dockerfiles' source path is not covered here — or anywhere on push

Both Swift Dockerfiles branch on a build-arg: with `PREBUILT_ARTIFACTS` unset
they compile Swift in-image (`control-plane/Dockerfile:12,34,49,76`;
`agent/Dockerfile:13,43,57,76`), and with it set they copy a prebuilt binary.
The deleted control-plane/agent image checks passed no build-arg, so they
exercised the **source** branch — which is why they cost an hour. Every
remaining image build (`main-build.yaml`, `release.yaml`) passes
`PREBUILT_ARTIFACTS`, so it takes the **other** branch.

So a break in the in-image `swift build -c release`, either apt-dependency
`RUN` block, or the `--show-bin-path` copy surfaces in no push- or PR-triggered
workflow at all. That path is live — `deploy/compose/docker-compose.yml`
documents commenting out `image:` and uncommenting `build:` to run from source.
Its only coverage is the opt-in `docker_source_build` input on
`main-tests.yaml`; tick it after touching either Dockerfile.

### Full Test Suite (`main-tests.yaml`)
`workflow_dispatch` only — nothing triggers it automatically, so it costs
nothing until someone starts it. Runs the full Swift suite for every package
(shared, agent, CLI, API client, SwiftFirecracker) plus the control-plane suite
against a throwaway Postgres 15 container with cvc5 installed, all on the ARC
scale set. It claims its own scratch-slot pools (`packages-tests`,
`control-plane-tests`) rather than sharing build.yaml's: these jobs build with
`--build-tests` and the compile jobs without, so a shared slot would have each
churning the other's incremental state.

One input, `docker_source_build` (default off): builds the control-plane and
agent images from source, the only coverage the Dockerfiles' compile-in-image
path has. Adds ~40–60 minutes, so the default dispatch stays fast.

### Main Branch Build (`main-build.yaml`)
Builds release binaries and Docker images when code is pushed to the main branch
(no tests):
- Swift release binary builds
- Docker image builds

### Release (`release.yaml`)
Triggered when a new tag is pushed (e.g., `v1.0.0`):
- Creates GitHub release with changelog
- Builds and pushes Docker images to GHCR
- Builds Swift binaries for Linux and macOS
- Uploads release assets

### Helm Chart Tests (`helm-test.yml`)
Tests Helm charts for correctness and security:
- Helm linting
- Template validation
- Security scanning
- Integration tests (disabled in CI, run locally)

### Claude Code (`claude.yml`)
Triggers Claude Code assistant when `@claude` is mentioned in issues or PRs.

### Docs Deployment (`deploy-docs.yml`)
Builds the VitePress documentation site (`npm run docs:build`) and deploys it
when docs change on the main branch.

## Runner Configuration

Workflows use a hybrid approach: an ARC (actions-runner-controller) runner
scale set for Swift work, one static self-hosted machine for Docker image
builds, and GitHub-hosted runners for everything lightweight.

### ARC Runner Scale Set: `swift-runners-strato` (x64)
Used for:
- PR validation — Swift compile check (build.yaml)
- The manually dispatched full test suite (main-tests.yaml)
- Main branch x64 Swift release binaries (main-build.yaml)
- Release x64 Swift image binaries (release.yaml — the jemalloc-linked binaries
  the container images copy in; the static-stdlib release-asset tarballs still
  build on the static self-hosted runner)

Jobs target the scale set with `runs-on: swift-runners-strato`. ARC
scale-set runners match on **exactly one label — the installation name** —
so never combine it with `self-hosted`, `Linux`, or arch labels.

Swift jobs run **directly on the runner pod**: the scale set's runner image
must bake in the pinned Swift toolchain (the jobs used to run inside the
official `swift:<version>-noble` job container, but that pulled the multi-GB
Swift image through dind on every job). vapor/swiftly-action is not used on
these runners (it breaks on ARC pods, where `$USER` is unset). The runner
image is managed in the homelab repo (`roles/github_runner`).

Requirements for the scale set's runner image / pods:
- Swift toolchain matching the `swift:x.y.z-noble` tag the Dockerfiles build
  with, installed so `swift` is on `PATH` (ideally untarred into `/usr` like
  the official image, so `/usr/lib/swift/linux/swift-backtrace-static` exists
  for the release-binary jobs)
- `git` (SwiftPM needs it; without it actions/checkout also falls back to a
  REST tarball download)
- Passwordless `sudo` for the runner user (main-build installs libjemalloc-dev
  and unzip at job time; stock in `ghcr.io/actions/actions-runner`)
- Docker available to jobs (dind mode) — `main-tests.yaml`'s control-plane job
  starts a Postgres container (via plain `docker run`, not `services:`),
  published to the pod on `127.0.0.1:5432`
- A persistent hostPath pool of build-scratch slots, provisioned by the homelab
  `github_runner` role and surfaced to jobs as `RUNNER_BUILD_SCRATCH_ROOT` /
  `RUNNER_BUILD_SCRATCH_SLOTS`; `.github/scripts/claim-build-scratch.sh` flocks
  one slot per job and exports it as `--scratch-path`.
  Without it every job builds cold — the claim script degrades to a pod-local
  directory rather than failing. Each job wipes only the scratch subdirectories
  inside the slot it claimed, automatically past ~10GB (never the shared root —
  concurrent sibling jobs hold other slots on the same volume); slots are always
  safe to delete manually, the next run just rebuilds cold.
- A `/cache/swiftpm` hostPath for the shared SwiftPM cache (`ghr_swiftpm_cache_*`).
  Optional: jobs probe it and fall back to a pod-local cold directory when it is
  absent, because SwiftPM will not create a missing cache root itself.

When bumping the Swift toolchain, rebuild the runner image with the new
toolchain and update the remaining `swift:x.y.z-noble` container tags
(the main-build and release arm64 Swift legs) together with the Dockerfiles and
the `vapor/swiftly-action` pin in the swift-format lint job.

### Static Self-Hosted Runner (x64/AMD64)
Used for:
- The Linux x86_64 release-asset binary tarball (release.yaml,
  `build-swift-binaries`) — the only job left on this machine. Release
  creation, source assets, and all Docker image assembly run on GitHub-hosted
  runners.

Requirements:
- curl (release assets upload via the raw REST endpoint — the runner needs no
  gh CLI)
- swiftly-installable environment (the job installs Swift 6.3.2 via
  vapor/swiftly-action, then pins it as the host's in-use toolchain — swiftly
  state persists between runs on this machine, and `install --use` alone does
  not switch an already-installed toolchain) and libjemalloc

### GitHub-Hosted Runners
Used for:
- PR validation — swift-format lint, frontend lint/build, OpenAPI lint, the
  frontend image build check (`ubuntu-latest`); the `Package.resolved` macOS
  drift check (`macos-14`)
- The opt-in Docker source build in `main-tests.yaml` (`ubuntu-latest`)
- All Helm chart tests (`ubuntu-latest`)
- Claude Code workflows (`ubuntu-latest`)
- Docs deployment (`ubuntu-latest`)
- Release x64 Docker image assembly from prebuilt binaries (`ubuntu-latest`)
- Main branch ARM64 builds (`ubuntu-24.04-arm`)
- Release ARM64 Swift binaries + Docker images (`ubuntu-24.04-arm`; the arm64
  Swift build runs inside the pinned `swift:6.3.2-noble` container so it links
  against the same runtime the Dockerfiles ship, not the runner's newer Swift)
- macOS binary builds (`macos-latest`)

This hybrid approach:
- Lets Swift jobs scale out on the ARC runner set instead of queueing on one machine
- Runs lightweight jobs in parallel on GitHub's cloud instead of queueing
- Provides ARM64/macOS build capability without dedicated runners
- Maintains security controls via PR approval for self-hosted jobs

## PR Approval Requirement

For security, workflows triggered by pull requests should require manual approval from a maintainer before they can run on self-hosted runners.

### Setting Up PR Approval

Configure this using GitHub's built-in repository settings:

1. Go to your repository **Settings**
2. Navigate to **Actions** → **General**
3. Scroll to **Fork pull request workflows from outside collaborators**
4. Select **Require approval for all outside collaborators**
   OR
5. Select **Require approval for first-time contributors**

This ensures that workflows on self-hosted runners require maintainer approval before execution for PRs from external contributors or first-time contributors.

### Why PR Approval?

PR approval is critical for security when using self-hosted runners because:
- Self-hosted runners have access to your infrastructure
- Malicious PRs could execute arbitrary code on your runners
- Approval ensures maintainers review the code before it runs
- Prevents unauthorized access to secrets and resources

Note: ARM64 and macOS builds run on GitHub-hosted runners and don't require the same approval process since they run in isolated, ephemeral environments provided by GitHub.

### Approving Workflow Runs

When a PR from an outside collaborator or first-time contributor is opened or updated:
1. GitHub will pause the workflow and wait for approval
2. Maintainers will see a notification in the Actions tab
3. Review the PR code changes carefully
4. If safe, click "Approve and run" in the Actions tab
5. The workflow will then execute on self-hosted runners

## Security Considerations

- Always review PR code before approving workflow runs
- Keep self-hosted runners isolated from production systems
- Regularly update runner software and dependencies
- Monitor runner activity and logs
- Use least-privilege access for runner service accounts
- Never approve suspicious or unreviewed PRs

## Running Workflows Locally

For testing without triggering CI:

```bash
# Install act (GitHub Actions local runner)
brew install act  # macOS
# or
curl https://raw.githubusercontent.com/nektos/act/master/install.sh | sudo bash  # Linux

# Run a specific workflow
act pull_request -W .github/workflows/build.yaml

# Run with secrets
act pull_request -W .github/workflows/build.yaml --secret-file .secrets
```

## Troubleshooting

### Workflow not starting
- Check if self-hosted runners / the ARC scale set are online in repository settings
- For Swift jobs, verify `runs-on` is exactly `swift-runners-strato` (no extra labels)
- For ARC, check the listener and runner pods: `kubectl get pods -n <arc-namespace>`
- Check runner connectivity and logs

### Approval not appearing
- Ensure `pr-approval` environment is created
- Verify required reviewers are configured
- Check if user has permission to approve

### Runner permission issues
- Ensure runner has necessary permissions
- Check file system permissions
- Verify Docker socket access
- Review runner service account permissions
