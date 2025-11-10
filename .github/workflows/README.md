# GitHub Actions Workflows

This directory contains GitHub Actions workflows for the Strato project. All workflows are configured to run on self-hosted runners for security and performance.

## Workflows

### PR Validation (`build.yaml`)
Runs on pull requests to validate code quality:
- JavaScript linting
- Swift package building and testing
- Security scanning with Trivy

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

## Runner Configuration

Workflows use a hybrid approach with both self-hosted and GitHub-hosted runners:

### Self-Hosted Runners (x64/AMD64)
Used for:
- PR validation (build.yaml)
- Main branch x64 builds (main-build.yaml)
- Release x64 builds (release.yaml)
- Helm tests (helm-test.yml)
- Claude Code workflows (claude.yml, claude-code-review.yml)

Requirements for self-hosted runners:
- Swift 6.0+
- Docker
- Node.js 20+
- Helm (for helm tests)
- QEMU dependencies (for agent builds)

### GitHub-Hosted Runners (ARM64)
Used for:
- Main branch ARM64 builds (`ubuntu-24.04-arm`)
- Release ARM64 Docker images (`ubuntu-latest-arm`)
- macOS binary builds (`macos-latest`)

This hybrid approach:
- Reduces load on self-hosted infrastructure
- Provides ARM64 build capability without ARM64 self-hosted runners
- Maintains security controls via PR approval for self-hosted jobs

## PR Approval Requirement

For security, workflows triggered by pull requests require manual approval from a maintainer before they can run. This is controlled by the `pr-approval` environment.

### Setting Up PR Approval

1. Go to your repository settings
2. Navigate to **Environments**
3. Create a new environment named `pr-approval`
4. Configure environment protection rules:
   - Enable **Required reviewers**
   - Add maintainers/admins as reviewers
   - Optionally set **Wait timer** (e.g., 0 minutes for immediate review)

Once configured, any workflow job that runs on PRs will require a maintainer to review and approve the workflow run before it executes on self-hosted runners.

### Why PR Approval?

PR approval is critical for security when using self-hosted runners because:
- Self-hosted runners have access to your infrastructure
- Malicious PRs could execute arbitrary code on your runners
- Approval ensures maintainers review the code before it runs
- Prevents unauthorized access to secrets and resources

Note: ARM64 and macOS builds run on GitHub-hosted runners and don't require the same approval process since they run in isolated, ephemeral environments provided by GitHub.

### Approving Workflow Runs

When a PR is opened or updated:
1. GitHub will pause the workflow and wait for approval
2. Maintainers will receive a notification
3. Review the PR code changes carefully
4. If safe, approve the workflow run in the Actions tab
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
- Check if self-hosted runners are online in repository settings
- Verify runner labels match `self-hosted`
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
