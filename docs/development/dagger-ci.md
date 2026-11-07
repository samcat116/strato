# Dagger CI

Strato's Dagger module is `.dagger/modules/strato-ci/main.dang`. It runs
containerized checks locally with Docker and a local cache, and the same checks
run on Dagger Cloud for Entire Trails (see [Dagger Cloud and Entire](#dagger-cloud-and-entire)).
Use Dagger **1.0.0-beta.21**, matching `dagger-module.toml`. Local runs need no
Dagger Cloud account.

## Run checks

Start Docker, then select the local engine from the repository root. This
explicit selection overrides any inherited remote engine setting:

```bash
export DAGGER_ENGINE=image://registry.dagger.io/engine:v1.0.0-beta.21
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
dagger api call strato-ci swift-test --package shared stdout
dagger api call strato-ci swift-test --package agent stdout
dagger api call strato-ci swift-test --package cli stdout
```

The test environment includes Python and the guest-agent bootstrap fixture
used by the shared suite.

Use the existing **Full Test Suite (manual)** GitHub workflow for the complete
Swift suite, including control-plane tests with disposable PostgreSQL and cvc5.
The Dagger browser check does not exercise real passkeys, an actual control
plane, or guest VMs. Containers running on macOS are Linux checks; macOS package
resolution and native Apple Virtualization validation remain separate.

The existing GitHub Actions workflows still handle automatic PR checks,
releases, deployment, Helm, Rust guests, shell/artifact checks, and macOS
validation. Dagger Cloud runs the checks for Entire Trails only; GitHub pull
requests are still gated by Actions.

## Dagger Cloud and Entire

The repository is connected to the `sam-personal` Dagger Cloud organization
through Entire's Dagger plugin. Pushing a Trail or merging to `main` runs
`dagger check` on Dagger Cloud, and the results appear as Entire **Gates** on
the Trail. Gate settings in Entire decide which checks must pass before a Trail
can merge.

The connection is configured in the web UIs, not in this repository:

1. On entire.com, open the project's **Plugins**, install **Dagger**, and grant
   it access to `samcat116/strato` on the Dagger integrations page.
2. On Dagger's **Sources** page, enable the plugin for the Entire repository and
   turn on **Head** and **Trails** checks.

`dagger cloud integration list` lists only GitHub integrations, so it does not
show the Entire connection. Look for runs on the Dagger dashboard and Gates on
the Trail instead.

### Local traces

Log in to upload traces from local runs:

```bash
dagger cloud login
dagger cloud org use sam-personal   # if you belong to more than one org
```

Each run then prints a `cloud url=https://dagger.cloud/...` trace link.
`DAGGER_NO_NAG=1` hides that link along with the signup prompts. Run
`dagger cloud logout` (and unset `DAGGER_CLOUD_TOKEN`) to go back to local-only
runs; the local cache stays reusable. Local execution still downloads container
images and package dependencies when needed; it is not an offline build.

Dagger reads git metadata with go-git, which refuses a repository that sets
`extensions.worktreeConfig`. Dagger then logs `failed to open git repository`
and runs without branch or commit information. If no worktree uses a
`config.worktree` file, remove the setting with
`git config --unset extensions.worktreeConfig`.

## Check inputs and caches

Each check reads selected workspace paths; docs changes do not become Swift
build inputs, and frontend changes do not become backend build inputs.
Dependencies install before application source is copied so source changes can
reuse package installation. Swift scratch caches use locked mounts to prevent
concurrent builds from writing the same tree.

See the official [checking guide](https://docs.dagger.io/using/checking/).
