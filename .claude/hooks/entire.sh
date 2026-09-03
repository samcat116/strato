#!/bin/sh

set -eu

event=${1:?entire hook event is required}

if command -v entire >/dev/null 2>&1; then
    exec entire hooks claude-code "$event"
fi

if [ "$event" = "session-start" ]; then
    printf '%s\n' '{"systemMessage":"\n\nEntire CLI is enabled but not installed or not on PATH.\nInstallation guide: https://docs.entire.io/cli/installation#installation-methods"}'
fi
