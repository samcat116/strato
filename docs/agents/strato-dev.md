# strato-dev host notes

These notes apply only to the Ubuntu development VM at `/home/sam/strato`.
Verify its current service configuration before relying on these defaults.

- The UI is `https://strato-dev.tail21c16.ts.net`; the user browses from their
  Mac. Use this URL and leave port 443 to the existing proxy.
- Compose builds from source. Keep overrides in untracked
  `deploy/compose/docker-compose.override.yml`.
- Control-plane tests use PostgreSQL on port 5433; credentials and harness
  setup are in [local development](../development/local-development.md).
- First-user WebAuthn registration requires the user's browser.
- If a required root command needs an interactive password, provide the exact
  command to the user and resume when it completes. Existing root access can
  be used within the authorized task.
- This VM is disposable. A requested deployment cleanup may remove its
  `strato-*` containers and volumes; that permission is specific to this host.
