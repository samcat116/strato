# Logging & Log Visibility

Operational notes on getting control-plane and agent logs to disk/console reliably,
plus the HTTP request log. Motivated by the 2026-06-12 end-to-end test, where
control-plane logs never reached disk because stdout was block-buffered under
`nohup`, and the real cause of a failure was invisible until far too late.

## Where logs go

Both the control plane and the agent log to **stdout/stderr** via SwiftLog
(`LoggingSystem.bootstrap`). They do not write log files themselves — capture is
the responsibility of whatever supervises the process.

### Production: run under a supervisor that captures stdout/stderr

Run the control plane and agent under a process supervisor that captures their
streams to a durable, queryable sink:

- **systemd**: set `StandardOutput=journal` and `StandardError=journal` (the
  default for most units). `journald` line-buffers and timestamps each line, so
  there is no block-buffering problem.
- **Kubernetes**: the container runtime captures stdout/stderr to the node log
  and `kubectl logs` / your log shipper picks it up. The Helm chart runs the
  binary directly as the container entrypoint, so this works out of the box.

No application change is needed for this path — a console/journal sink is
line-oriented, so logs appear promptly.

### Development: line-buffer when redirecting to a file

The `Taskfile.yml` dev flow runs the binaries under `nohup ... > file.log`. When
stdout is a regular file (not a TTY), glibc **block-buffers** it, so log lines
can sit in a 4–8 KB buffer for minutes — or be lost entirely if the process is
killed — before reaching the file.

The Taskfile works around this by launching under `stdbuf -oL -eL`, which forces
line buffering on stdout/stderr:

```sh
nohup stdbuf -oL -eL swift run > /tmp/strato-control-plane.log 2>&1 &
```

If you launch a binary by hand and redirect to a file, do the same, or `tail -f`
a TTY instead.

## HTTP request logging (control plane)

`RequestLoggingMiddleware` emits one structured line per HTTP request:

```
http_request method=GET path=/health/live status=200 durationMs=1.4
```

It is registered as the outermost middleware so the duration and status reflect
the full request.

**Toggle:** the `REQUEST_LOGGING` environment variable (`true`/`false`). When
unset it defaults to **on outside `.production`** and off in production; set
`REQUEST_LOGGING=true` to enable it in production for debugging.

## Service identity on the health endpoints

`GET /health/live` and `GET /health/ready` include an `identity` object
(`instanceId`, `startedAt`, `version`, `gitSHA`, `environment`). `instanceId` is
unique per process boot, so two control planes answering the same port are
immediately distinguishable — the signal that was missing when a stale duplicate
silently intercepted port 8080. See `BuildInfo.swift`.
