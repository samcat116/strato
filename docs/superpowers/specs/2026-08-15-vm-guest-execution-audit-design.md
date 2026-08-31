# VM Guest Execution Audit Design

**Issue:** STR-84

**Status:** Implemented

## Purpose

Every attempt to execute a command inside a VM must be attributable, and every
execution that reaches the guest must expose its lifecycle in the existing
audit trail. The trail must cover authorization refusals, validation failures,
captured command outcomes, and interactive exec start and end facts.

This design extends the existing `AuditEvent` system. It does not introduce a
second audit ledger or record terminal input or output.

## Decisions

- Captured commands use separate append-only request and completion events.
- Interactive exec uses request, agent-confirmed start, and terminal end
  events.
- Audit delivery remains fail-open. Audit configuration, queue shedding, and
  backend failures must not prevent a command or session from running.
- Session stdin, stdout, stderr, environment variables, and terminal frames are
  never audit metadata.
- A late guest exit that corrects a recorded timeout appends a correction fact;
  it never edits the timeout event.
- The audit UI filters execution events by the existing VM resource identity,
  without requiring a cross-organization VM picker.

## Existing System

The control plane already has three relevant boundaries:

1. `AuditMiddleware` surrounds authorization and records API mutations,
   including 401 and 403 responses, as `api.request` events.
2. `VMCommandExecution` and `VMCommandPayload` durably retain captured command
   status, actor ID, exact argv, output, and exit code. The command service owns
   terminal state changes and timeout recovery.
3. `GuestExecSessionManager` owns the in-memory pending and attached lifecycle
   for interactive sessions. Agent frames confirm process start, process exit,
   and abnormal closure.

Generic `api.request` events do not contain argv or the later asynchronous
outcome. The interactive manager logs lifecycle changes but does not currently
turn them into audit events.

## Event Contract

### Event types

| Event type | When emitted | Outcomes |
| --- | --- | --- |
| `vm.command.requested` | A durable command is accepted for dispatch | `accepted` |
| `vm.command.completed` | A durable command state transition reaches a terminal fact | `exited`, `failed`, `timed_out` |
| `vm.exec.requested` | An interactive session is accepted and minted | `accepted` |
| `vm.exec.started` | The owning agent sends the first valid `guest_exec_started` frame | `started` |
| `vm.exec.ended` | An attached session reaches its first terminal transition | `exited`, `refused`, `timed_out`, `disconnected`, `terminated` |

The existing generic `api.request` record remains. The domain events provide
the execution-specific security facts and do not replace generic request
auditing.

### Common fields

Execution events use the existing first-class `AuditEvent` fields:

- `userID` and `username`: actor identity and username snapshot when known.
- `apiKeyID`: the credential used by the initiating request, when applicable.
- `organizationID`: the VM's organization, not merely the user's selected
  organization.
- `resourceType`: `vms`, matching the current API-path resource convention.
- `resourceID`: canonical VM UUID string.
- `action`: `vm:runCommand` or `vm:exec`.
- `sourceIP`: initiating request address when known.
- `adminBypass`: whether the platform administrator policy determined the
  request.
- `status`: HTTP status for request events; absent on later lifecycle events.

An unauthenticated request cannot name a verified actor. Such an event retains
the source IP and VM target while leaving identity fields empty rather than
inventing an identity.

### Metadata

Metadata remains a string-to-string object. The defined keys are:

- `argv`: the exact accepted argv encoded as a JSON array string.
- `outcome`: one of the event-specific values above.
- `correlationID`: command execution UUID or interactive session ID.
- `phase`: the lifecycle phase (`requested`, `completed`, `started`, or `ended`).
- `exitCode`: decimal process exit code when the agent reports one.
- `reason`: bounded normalized terminal or refusal reason when available.
- `correctsOutcome`: the earlier outcome corrected by a late terminal fact.

Metadata must not include environment variables, working directory, stdin,
stdout, stderr, output truncation buffers, WebSocket frames, or a session
transcript. Output recording is outside STR-84 and remains off.

## Architecture

### Event construction

A focused `VMGuestExecutionAudit` component centralizes metadata encoding,
outcome naming, reason bounding, and `AuditRecord` construction. The audit
middleware separately recognizes guest-execution route shapes so their generic
request facts can use the same fail-open delivery policy. Neither boundary owns
command or session state. Callers decide that a lifecycle transition happened
and pass an immutable snapshot to the component.

Central construction prevents middleware, command services, and the session
manager from drifting on event names or privacy exclusions. It also gives tests
one boundary at which to prove that prohibited fields cannot enter metadata.

### Request events

`AuditMiddleware` continues to run outside authorization and remains the
authoritative record for rejected or invalid API requests. The two domain
request facts are accepted-only because that is the point at which a durable
command ID or interactive session ID exists. They add exact argv, canonical VM
identity, and correlation that generic middleware cannot know without copying
execution-domain parsing into the authorization boundary.

The command controller emits `vm.command.requested` after the execution and
payload transaction commits and before dispatch. The exec controller emits
`vm.exec.requested` after the pending session is minted. Both use the bounded
`recordFailOpen` queue. Audit delivery remains outside both acceptance
transitions and cannot roll either one back.

### Captured command lifecycle

`VMCommandExecution` gains the immutable audit snapshot that is not already
durable: username, API-key ID, VM organization, source IP, and administrator
policy flag. Existing `actorID` remains the durable user identity, and
`VMCommandPayload.command` remains the source of exact argv. A forward migration
adds nullable fields for historical rows and an explicit non-null default for
the administrator flag.

The command controller persists the execution, payload, and audit snapshot in
its existing transaction before dispatch. The request event remains an
ordinary `AuditService` delivery and is not part of that transaction because
delivery is deliberately fail-open.

Every terminal path converges on a command transition that reports whether it
changed durable state:

- normal agent exit records `exited` and `exitCode`, including non-zero codes;
- definitive dispatch failure and abnormal guest close record `failed`;
- the deadline sweep records `timed_out` only for rows it claims;
- persistence retries and duplicate terminal frames emit nothing unless they
  perform a new durable transition.

Audit delivery happens after the command transaction commits. A transition is
not rolled back when an audit backend fails.

Guest-execution generic request facts and domain facts always enter the bounded
background queue, even when the deployment enables synchronous delivery for
ordinary audit events. This keeps database and SIEM availability outside
command dispatch and session teardown. Generic refusal facts omit raw
validation error text because it can echo prohibited request fields. The
database backend persists each fact's durable transition timestamp, so
concurrent queue drains cannot reorder a timeout and its later correction by
insert time.

The current command model permits a late exit to replace a timeout failure with
the actual result. That produces another `vm.command.completed` event with
`correctsOutcome=timed_out`. This is the sole normal exception to the one
request/one completion shape, and preserves both facts in an append-only trail.

### Interactive session lifecycle

The VM exec controller builds an immutable audit context containing actor,
organization, VM, argv, source, and administrator-policy information. The
pending and attached session snapshots retain it. Sandbox sessions continue to
use the shared manager without VM audit context and do not emit VM event types.

Session transitions occur under the manager's existing lock, but audit delivery
occurs after releasing it:

- the first valid owning-agent start frame marks the session started and
  returns the context for `vm.exec.started`;
- terminal removal atomically removes the session and returns its context once;
- repeated start, exit, close, or browser-close callbacks find no eligible
  transition and emit nothing;
- a frame from a non-owning agent cannot change state or produce an event.

Normal exit includes the exit code. Start delivery failure, abnormal agent
close, browser/operator termination, agent disconnect, and same-agent reconnect
cleanup use the normalized end outcomes above. An accepted pending session that
expires without attachment has no start or end event because no process was
sent to the guest.

Interactive state remains in memory. An abrupt control-plane process loss can
therefore leave a start event without a later end event; fail-open delivery and
the existing non-durable interactive bridge make that an explicit limitation
of this issue rather than a hidden guarantee.

## Audit Query API

Both audit list endpoints gain optional `resourceType` and `resourceID` query
parameters. When both are supplied, both predicates apply. The organization
endpoint continues to force the path organization regardless of query input.

OpenAPI documents the filters, and generated TypeScript types are regenerated
from the schema. A migration adds an index on
`audit_events(resource_type, resource_id, created_at)` for newest-first VM
history queries.

## Audit UI

The existing system-administrator audit page adds all five event types to its
filter catalog and sends VM filters as `resourceType=vms` plus the canonical VM
UUID.

The page supports two ways to select a VM:

1. paste a VM UUID into a filter field;
2. click a VM resource cell in the event table.

This avoids relying on `useVMs`, which is scoped to the currently selected
organization while the audit page spans the deployment.

Execution events render:

- a friendly event label while retaining the raw event type;
- a truncated JSON argv beneath the event, preserving argument boundaries;
- an outcome badge and exit code in the status area;
- expandable details containing full argv, correlation ID, reason, phase, and
  correction information.

Historical events and malformed metadata render an unavailable marker instead
of throwing. No output field exists for the UI to reveal.

## Failure Handling

The feature uses `AuditService.recordFailOpen`, including its bounded queue and
best-effort backend semantics:

- disabled audit or omitted backends do not block execution;
- count or byte saturation may shed an event and logs the running shed total
  and reason;
- database, Loki, log, or webhook failures do not change an HTTP response,
  command status, or session lifecycle;
- audit errors never cause a lifecycle retry that could execute a command
  again.

Lifecycle idempotence is enforced by the command database transition and the
interactive manager's locked state transition, not by assuming audit delivery
is exactly once. External consumers must continue to tolerate duplicate
delivery by configured backends.

## Test Strategy

Implementation follows red-green-refactor cycles at each boundary.

### Control-plane request tests

- Authorization and validation refusals remain visible as generic
  `api.request` events and do not produce an accepted domain request fact.
- Successful command and exec requests record `outcome=accepted` with exact
  argv and their command/session correlation ID.
- VM organization attribution comes from the target VM.

### Captured command tests

- Normal exit, non-zero exit, dispatch failure, guest close, and timeout emit
  the matching completion metadata after the durable transition.
- Duplicate frames and repeated sweeps do not add completion events.
- A late exit after timeout appends a correction and preserves the earlier
  timeout.
- Completion retains the actor snapshot and exact argv even if the user record
  changes after submission.

### Interactive manager tests

- The first owning-agent start emits once; a duplicate or wrong-agent start
  does not.
- Exit, start failure, browser disconnect, agent disconnect, and reconnect
  cleanup each emit at most one end event.
- A terminal callback racing another terminal callback produces one end fact.
- Pending expiration produces neither a false start nor a false end.
- Sandbox exec continues without VM audit events.

### Privacy tests

Tests use distinctive environment, working-directory, stdin, stdout, and
stderr sentinels and assert that no persisted event metadata contains them.
Assertions inspect decoded metadata rather than searching implementation text.

### Query and web tests

- The API applies resource type and resource ID filters together and preserves
  organization scoping and pagination totals.
- The web API serializes both filters.
- Clicking a VM resource activates and clears the VM filter.
- Execution rows render argv, outcome, exit code, and incomplete metadata
  safely.

## Documentation and Validation

`docs/deployment/audit-logging.md` will document the event catalog, fail-open
behavior, VM filtering, metadata contract, and explicit output exclusion.

Validation includes focused Swift tests for audit logging, command execution,
and guest exec; web unit tests; OpenAPI type generation; strict Swift
formatting; the web production build; and `git diff --check`. Database-backed
test results will be reported separately if a local PostgreSQL service is not
available.

## Out of Scope

- Recording interactive output, stdin, environment variables, or transcripts.
- Making the existing audit service fail closed or exactly once.
- Persisting interactive session state across control-plane process loss.
- Adding sandbox execution audit events.
- Replacing the existing audit backends or retention policy.
