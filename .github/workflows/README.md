# GitHub Actions Workflows

This directory contains GitHub Actions workflows for the Strato project. Workflows use a **hybrid runner strategy**: the heavy Swift build/test and release binary jobs run on the `swift-runners-strato` runner scale set (self-hosted, managed by [actions-runner-controller](https://github.com/actions/actions-runner-controller)); Docker image builds that need a Docker daemon stay on the single static self-hosted runner; lightweight jobs — frontend lint/build, Trivy scans, Helm tests, ARM64/macOS builds — run on GitHub-hosted runners so they don't queue behind Swift work. PR and main-branch workflows also use `concurrency` groups to cancel superseded runs on new pushes.

## Workflows

### PR Validation (`build.yaml`)
Runs on pull requests to validate code quality:
- Frontend lint & build (GitHub-hosted)
- Swift package building and testing — shared, control plane, and agent
  (`swift-runners-strato` ARC scale set)
- Docker image build checks, gated on Dockerfile changes (GitHub-hosted)
- Security scanning with Trivy (GitHub-hosted)

A `changes` job (via `dorny/paths-filter`) detects which parts of the repo
changed and gates each job with `if:`, so docs-only PRs skip the Swift build,
frontend-only PRs skip Swift, etc. Because the jobs are skipped via `if:`
(not workflow-level `on.paths`), a skipped job still reports as a passing
check and remains safe to use as a required status check. In-progress runs are
cancelled when a new commit is pushed to the same PR.

### Main Branch Build (`main-build.yaml`)
Builds release binaries and Docker images when code is pushed to the main branch:
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

### Claude Code Review (`claude-code-review.yml`)
Automatically reviews pull requests using Claude Code.

### Docs Deployment (`deploy-docs.yml`)
Builds the VitePress documentation site (`npm run docs:build`) and deploys it
when docs change on the main branch.

## Runner Configuration

Workflows use a hybrid approach: an ARC (actions-runner-controller) runner
scale set for Swift work, one static self-hosted machine for Docker image
builds, and GitHub-hosted runners for everything lightweight.

### ARC Runner Scale Set: `swift-runners-strato` (x64)
Used for:
- PR validation — Swift build & test (build.yaml)
- Main branch x64 Swift release binaries (main-build.yaml)

Jobs target the scale set with `runs-on: swift-runners-strato`. ARC
scale-set runners match on **exactly one label — the installation name** —
so never combine it with `self-hosted`, `Linux`, or arch labels.

Requirements for the runner image / scale set:
- `sudo` + `apt` available in the runner image (the default
  `ghcr.io/actions/actions-runner` image has no sudo): `vapor/swiftly-action`
  installs Swift's apt dependencies, and main-build installs `libjemalloc-dev`
- QEMU/glib build dependencies for agent builds
- Docker available to jobs (dind mode, or kubernetes mode with container
  hooks) — the PR test job runs a Postgres **service container**
- Optional but strongly recommended: a persistent volume mounted at
  `RUNNER_TOOL_CACHE`. Swift build state lives in
  `$RUNNER_TOOL_CACHE/strato-swift-build` (via `swift build --scratch-path`),
  and swiftly caches toolchains there too. Without the volume every job runs
  a cold build and re-downloads the toolchain; with it, builds are
  incremental across runs with no cache upload/download. The PR workflow
  wipes the scratch dir automatically past ~25GB; it is always safe to
  delete manually — the next run just rebuilds cold.

### Static Self-Hosted Runner (x64/AMD64)
Used for:
- Main branch x64 Docker image builds (main-build.yaml)
- Release creation and x64 Docker image builds (release.yaml)

Requirements:
- Docker

### GitHub-Hosted Runners
Used for:
- PR validation — frontend lint/build and Trivy scan (`ubuntu-latest`)
- All Helm chart tests (`ubuntu-latest`)
- Claude Code workflows (`ubuntu-latest`)
- Docs deployment (`ubuntu-latest`)
- Main branch ARM64 builds (`ubuntu-24.04-arm`)
- Release ARM64 Docker images (`ubuntu-latest-arm`)
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
