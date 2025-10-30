# Claude Code Configuration

This directory contains Claude Code configuration and hooks for the Strato repository.

## Hooks

### `hooks/startup.sh`

This startup hook automatically installs Swift and required dependencies when running in the Claude web environment.

**Environment Detection:**
- The hook only runs when `CLAUDE_CODE_REMOTE=true` (Claude web environment)
- On local Claude Code installations, the hook exits early without making any changes

**Installed Dependencies:**
- Swift 6.0.2 toolchain
- System libraries: libssl-dev, libsqlite3-dev, libcurl4-openssl-dev, libxml2-dev
- Build tools: binutils, git, pkg-config, unzip, wget
- Runtime dependencies required for Swift Package Manager

**How it works:**
1. Checks if running in Claude remote environment (`CLAUDE_CODE_REMOTE=true`)
2. Verifies if Swift is already installed (to avoid re-installation)
3. Updates package lists and installs system dependencies
4. Downloads and installs Swift 6.0.2 from official Swift releases
5. Creates symlinks for swift, swiftc, and swift-package commands
6. Verifies the installation

**Manual testing:**
```bash
# Test locally (should skip installation):
./.claude/hooks/startup.sh

# Simulate remote environment:
CLAUDE_CODE_REMOTE=true ./.claude/hooks/startup.sh
```

## Future Enhancements

Potential additions for the hooks:
- PostgreSQL client tools (if needed for database migrations)
- Docker/Podman for container-based development
- Additional Swift development tools
