# Documentation map

Choose a path for the task you are doing. Existing page URLs remain the
canonical references; this map brings the guides and specialized procedures
together without moving them.

| Goal | Entry point |
| --- | --- |
| Understand the platform | [What is Strato?](./guide/what-is-strato.md) |
| Install and prepare a first VM | [Getting started](./guide/getting-started.md) |
| Use an existing installation | [User guide](./guide/user-guide.md) |
| Configure and operate Strato | [Deployment and operations](./deployment/overview.md) |
| Develop and validate changes | [Developer guide](./development/overview.md) |
| Integrate with the API | [API reference](./api-reference.md) |
| Understand subsystem design | [Architecture overview](./architecture/overview.md) |

## User tasks

[CLI installation and login](./guide/getting-started.md#install-the-cli),
[instance metadata](./guide/instance-metadata.md),
[graphics consoles](./guide/graphics-console.md), and
[Windows guests](./guide/windows-guests.md) cover workload access and provisioning.

## Operator tasks

The [deployment overview](./deployment/overview.md) indexes Compose, Kubernetes,
agent enrollment, IAM, health, rate limiting, logging, audit, Shared Signals,
and observability. Additional procedures:

| Procedure | Scope |
| --- | --- |
| [Host memory profile](./deployment/host-memory-profile.md) | Explicit opt-in host policy and prerequisite validation |
| [Membership role cutover](./deployment/membership-role-cutover.md) | Version-specific membership migration |
| [Credential restriction cutover](./runbooks/credential-restriction-cutover.md) | Inventory before the credential-model migration |
| [VM boot-volume cutover](./operations/vm-boot-volume-cutover.md) | Inventory before the managed boot-disk migration |
| [Volume replica cutover](./operations/volume-replica-cutover.md) | Inventory before the volume-placement migration |
| [QEMU block policy benchmark](./operations/qemu-block-policy-benchmark.md) | Acceptance matrix; does not claim measured benchmark results |

Cutover documents are version-specific procedures, not steps for every fresh
installation. Confirm the deployed version and preflight conditions before
using them. Their commands have effects beyond reading documentation.

## Developer references

- [Local development](./development/local-development.md) and
  [E2E testing](./development/e2e-testing.md)
- [Code review](./development/code-review.md)
- [Kubernetes troubleshooting](./development/troubleshooting-k8s.md) and
  [WebAuthn debugging](./debugging/webauthn.md)
- [Mutation idempotency](./architecture/idempotency.md)
- [Architecture subsystem index](./architecture/overview.md#document-index)

## Implementation and validation status

This documentation follows repository `main`. Published images, releases, and
an installed deployment can be at different revisions. Read each page's status
and prerequisite notes before treating it as enabled behavior. Code present in
`main` does not by itself establish production acceptance.

- [Distributed storage](./architecture/distributed-storage.md) is a proposal
  with partial implementation; use [storage](./architecture/storage.md) for
  the current backend contract.
- [Guest identity](./architecture/guest-identity.md) distinguishes the shipped
  VM principal/JWT path from proposed guest X.509 and Workload API delivery.
- [Resource classes](./architecture/resource-classes-contract.md) and
  [burstable runtime](./architecture/burstable-runtime.md) describe guarded
  implementation and rollout gates, not generally enabled burstable placement.
- [Sandbox suspension](./architecture/sandbox-suspension.md) records opt-in
  behavior and its pending real-VM acceptance.
- [Authorization edge audit](./architecture/authorization-edge-audit.md) is a
  point-in-time assessment, not a complete current security guarantee.

## Architecture decisions

| ADR | Decision |
| --- | --- |
| [0001](./adr/0001-declarative-agent-protocol.md) | Declarative agent protocol |
| [0002](./adr/0002-ceph-for-distributed-block-storage.md) | Ceph for distributed block storage |
| [0003](./adr/0003-imds-chassis-namespace.md) | IMDS chassis namespace |
| [0004](./adr/0004-cedar-for-authorization.md) | Cedar authorization |
| [0005](./adr/0005-agent-drives-libvirt-not-qemu.md) | Agent drives libvirt |
| [0006](./adr/0006-imds-session-auth.md) | IMDS session authentication |
| [0007](./adr/0007-coredns-per-chassis-namespace.md) | CoreDNS per chassis (superseded) |
| [0008](./adr/0008-resolver-in-host-namespace.md) | Resolver in the host namespace |
| [0009](./adr/0009-current-schema-baseline.md) | Current schema baseline |
| [0010](./adr/0010-layer-network-acls-with-ovn-tiers.md) | Layer network ACLs with OVN tiers |

Repository automation instructions under `docs/agents/` are intentionally
excluded from the published site. Contributors should read the root `AGENTS.md`
for those entry points.
