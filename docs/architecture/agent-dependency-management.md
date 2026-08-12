# Agent dependency management

Strato treats host software health as a continuously observed input to new
placement. It does not treat the agent process as an init system.

## Ownership boundary

The statically compiled dependency registry assigns every module one ownership
mode:

- `observeOnly`: an operator or external orchestrator owns configuration and
  lifecycle. Strato inspects, reports, and gates affected features. It never
  enables, starts, or restarts the service.
- `ensureRunning`: Strato may ask the declared low-level supervisor to enable,
  start, or restart the service. Cooldown, exponential backoff, and a bounded
  restart budget apply.
- `reconcile`: Strato owns desired configuration and lifecycle. Reconciliation
  is level-triggered and idempotent.

Systemd remains the process supervisor for ordinary host services. Ceph daemon
lifecycle remains with cephadm. The generic systemd adapter must not start or
stop individual MON, MGR, or OSD units. Operator-managed FRR begins as
`observeOnly`; Strato may own it only when site configuration explicitly makes
Strato authoritative for the FRR configuration.

Module construction may derive desired state and an allowed ownership mode from
typed configuration. The initial SPIRE, libvirt, and OVN/OVS registry is fixed
to `observeOnly`. Configuration cannot load a plugin, supply an executable, or
provide shell text. Host commands come from fixed module allowlists and use
absolute executables, argument arrays, timeouts, and output limits.

## Observation and gating

The agent manager validates the dependency graph at startup. It runs independent
checks concurrently and waits for dependencies before their dependants. Each
observation reports supervisor state, installed and daemon versions,
compatibility, functional state, timestamps, a structured failure, failure and
repair counters, and the affected capabilities.

Checks run outside the heartbeat path. Registration includes the initial
snapshot, and regular heartbeats carry the latest cache. This preserves agent
liveness if a host command is slow while keeping dependency transitions bounded
by the observation interval.

The control plane persists the latest snapshot. An observation older than 60
seconds is not authoritative for new placement. Two consecutive functional
failures are required to move from degraded to unhealthy, and recovery is
confirmed before returning to healthy. Missing units or binaries, inactive or
failed supervisors, and incompatible versions are categorical when the module
reports them as required for functional availability. Supervisor state remains
diagnostic metadata when an external process passes the module's functional
probe.

Gating is feature-scoped:

- libvirt gates new QEMU placement and QEMU-backed volume placement;
- OVN/OVS gates overlay networking, sandbox NICs, and the per-network resolver;
- SPIRE reports workload-identity readiness;
- future FRR health gates dynamic routing only;
- future Ceph client health gates Ceph-backed volumes only.

A dependency transition never deletes, stops, or migrates a running workload.
It only changes admission of new work that needs the affected feature.

## Initial modules and rollout

The initial registry observes SPIRE, libvirt, and OVN/OVS. SPIRE combines its
systemd unit with the current Workload API X.509 SVID and warns before expiry.
A successful SVID fetch is authoritative when SPIRE runs outside systemd and
the local unit is confirmed absent or disabled; a disabled unit remains visible
as supervisor metadata without withdrawing workload identity. A failed systemd
inspection does not prove external ownership. An enabled inactive or failed
unit remains a functional failure even while the agent holds a cached SVID.
Definitive load failures such as a masked unit, an invalid setting, or a unit
load error are categorical. A failed or malformed systemd inspection remains
unknown rather than being treated as missing or failed.
Libvirt discovers `virtqemud.socket` or `libvirtd.socket` and reuses the bounded
daemon-version probe, including the 11.5.0 compatibility floor. A reachable
externally supervised daemon remains usable, but a known non-active local unit
is a functional failure. OVN/OVS checks
the package units and versions, OVN NB and local OVSDB reads, `br-int`, and the
ovn-controller southbound connection.

This delivery makes fresh dependency health authoritative for affected new
placements but passes `allowRemediation: false` to the manager, even if a future
module is accidentally registered with broader ownership. Controlled repair is
enabled one dependency at a time only after the observation data shows that its
policy is safe.

Ceph adds two different module families rather than pretending every dependency
is a unit. Client hosts check version, configuration, keyring, cluster
reachability, and a bounded RBD operation. Member and controller hosts observe
`ceph status`, `ceph orch status`, and daemon inventory, while cluster-wide
desired-state reconciliation stays in the storage controller and cephadm.
