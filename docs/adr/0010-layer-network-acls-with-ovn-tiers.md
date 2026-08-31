# ADR 0010: Layer network ACLs and security groups with OVN tiers

- **Status**: Accepted
- **Date**: 2026-08-30
- **Deciders**: Sam Schmitt
- **Scope**: STR-33 network ACL realization on OVN logical switches
- **Affects**: security-group ACL realization and every topology-authority agent

## Context

Strato security groups are stateful NIC policy. Their OVN ACLs attach to port
groups: rule allows use priority 1002 and the site-wide default deny uses 1001.
Platform traffic has higher-priority carve-outs for DHCP, IPv6 control traffic,
metadata, and the per-network resolver.

Network ACLs are a second policy boundary attached to a tenant logical switch.
They have separately ordered ingress and egress rules, can allow or deny, and
default-deny unmatched IP traffic. A packet must satisfy both the network ACL
and any security groups on its port.

OVN chooses one verdict from the highest-priority matching ACL across both the
switch and its port groups. A priority band alone therefore cannot compose the
two policies:

- Put network ACLs above security groups and a terminal network `allow` bypasses
  the security-group default deny.
- Put them below security groups and a security-group allow bypasses a network
  deny.
- Give them equal priority and OVN explicitly leaves the winning row undefined.

OVN supports four ACL tiers. Evaluation starts at tier 0 and moves forward when
no rule supplies a verdict or when a rule uses `pass`.

## Decision

Strato assigns ACL ownership to three tiers:

| Tier | Owner | Verdicts |
| --- | --- | --- |
| 0 | Platform services | Terminal allows and the per-instance metadata deny |
| 1 | Network ACL | `drop` for deny; `pass` for allow; implicit default drop |
| 2 | Security group | Stateful `allow-related` rules and the NIC default drop |

Network rule numbers are API order, not OVN priority. Valid numbers are
1–32766 and lower numbers win. The agent maps a rule number to
`32767 - ruleNumber`; priority 0 is reserved for the implicit default deny in
each direction. The database enforces uniqueness per ACL, direction, and rule
number.

An API `allow` deliberately becomes OVN `pass`, not OVN `allow`. `pass` is the
stateless positive verdict for the network layer and continues to tier 2, where
the NIC still has to satisfy its security group. A terminal switch `allow`
would turn the network ACL into an override and open ports the security group
denied.

Platform traffic stays in tier 0. This makes DHCP, IPv6 neighbor and multicast
control traffic, metadata, and the Strato resolver non-filterable by a tenant
network ACL, matching the service exemptions already established by security
groups. The per-instance metadata kill switch remains a higher-priority tier-0
drop, so an operator can still disable metadata for one workload.

Only the site's live overlay topology authority writes switch ACLs. Wire v53 is
an exact control-plane/agent cutover, so STR-33 does not restore a version-derived
`supportsNetworkACLs` flag removed with the lockstep protocol. Existing networks
have no ACL row and are unaffected until an operator explicitly creates one.

## Convergence and rollout

The authority first rewrites every managed security-group port group with the
new tier-aware builder revision. It does not attach any network ACL until all
planned groups are observed at that revision; otherwise an old tier-0
security-group allow could bypass tier 1 during a partial upgrade.

Each network ACL has its own generation and is replaced as a complete rule set.
Mixed allow/deny sets cannot use the security-group strategy of creating every
new row before deleting every old row: contradictory equal-priority verdicts
would coexist and OVN could choose either. Replacement is staged to fail closed:

1. Attach temporary priority-32767 drops in both directions, above every user
   rule.
2. Remove old positive verdicts, then old drops.
3. Attach the new implicit defaults, explicit drops, and positive verdicts.
4. Remove the temporary guards and stamp the switch.

A failed transaction window can deny traffic that the finished policy permits,
but an old higher-priority positive verdict cannot outrank the replacement
guard and permit traffic the new policy blocks. Guards carry their own managed
row kind, so a retry reuses them instead of accumulating duplicates and cannot
mistake a leftover guard for a complete same-sized policy. Generation and
builder stamps make the next level-triggered sync repeat an incomplete
replacement. Teardown considers only ACLs attached to the target switch with
Strato's managed network-ACL external IDs.

ACL deletion also advances the owning logical network's generation in the same
database transaction. That durable outer generation prevents an older desired
network payload from resurrecting a policy after the agent has removed its last
generation-stamped ACL row.

## OVN stateful-return boundary

The network rules themselves never create connection-tracking state: positive
verdicts use `pass`, and both directions must be represented explicitly. OVN,
however, documents that return traffic admitted by an existing
`allow-related` security-group flow cannot be changed by another ACL. Therefore
the direct-switch backend cannot reproduce AWS's independent stateless return
filter bit for bit while it shares OVN's ACL pipeline with stateful security
groups.

STR-33 still provides deterministic ordered filtering for new packets in both
directions and composes both policy layers without allowing one positive rule to
bypass the other. The API and documentation must not claim that changing a
network ACL retroactively blocks packets in an already established
security-group connection. Closing that backend gap requires enforcement before
OVN's stateful ACL shortcut (or a different data-plane primitive), not another
priority assignment.

## Consequences

- Network ACL and security-group positive rules form an AND policy for new
  flows.
- The issue's API action remains `allow`, while OVN realization uses `pass` as
  an implementation detail.
- Creating an empty network ACL intentionally makes the network default-deny;
  existing networks do not receive one automatically.
- Tier changes force a builder-revision rewrite of all managed security-group
  ACLs before network ACL enforcement begins.
- Service traffic remains available without asking tenants to reproduce
  infrastructure carve-outs in every ACL.
- The OVN established-return limitation is explicit rather than hidden behind
  an AWS-equivalence claim.
