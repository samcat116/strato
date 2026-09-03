# Claude Code configuration

`settings.json` registers two repository hooks:

- `hooks/startup.sh` installs the pinned Swift toolchain and system build
  dependencies when `CLAUDE_CODE_REMOTE=true`. Local sessions exit without
  changing the host.
- `hooks/entire.sh <event>` forwards lifecycle events to Entire when its CLI is
  installed. A remote session-start reports the installation link when it is
  unavailable.

Run either script directly to exercise its local no-op path. The startup hook's
package list and platform checks are the source of truth for remote setup.
