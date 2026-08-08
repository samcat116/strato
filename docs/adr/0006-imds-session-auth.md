# ADR 0006: The instance metadata service is IMDSv2-only, in EC2's spelling

- **Status**: Accepted
- **Date**: 2026-08-08
- **Deciders**: Sam Schmitt
- **Scope**: the agent-side metadata listener (STR-56) and the renderers built
  on it (STR-60, STR-62, STR-65)

## Summary

Reads from `169.254.169.254` require a session token, minted by
`PUT /latest/api/token` with an `X-aws-ec2-metadata-token-ttl-seconds` header
and presented as `X-aws-ec2-metadata-token`. There is no unauthenticated mode
and no flag to enable one. The header names are **EC2's**, not
`X-strato-metadata-token-*` as STR-56 was originally written. Each token is
bound to the instance it was minted for and is refused when presented by
another.

## Context

`169.254.169.254` is unauthenticated by construction in the original AWS design:
any process inside the guest can read it, and so can any request-forging bug
that lets an attacker aim a URL. That is the whole SSRF class, and
`control-plane/Sources/App/Services/SSRFGuard.swift` already spends real effort
blocking the mirror image of it on the control-plane side. Building the hole
facing the other way would be strange.

AWS's IMDSv2 answers this without a credential distribution problem. The
protection is not the token's secrecy — the guest can always mint one — it is
the **shape of the mint**: a `PUT` carrying a header the attacker must be able
to set. An SSRF primitive that can only make the server fetch a URL cannot do
either. AWS shipped IMDSv1 optional and spent years unwinding it. There is no
compatibility debt in Strato yet, so there is nothing to unwind and no reason to
create any.

STR-56 specified Strato-prefixed header names, on the reasonable instinct that
this is our service and not EC2's.

## Decision

### IMDSv2 is mandatory

No unauthenticated read path exists, and no configuration turns one on. The
config knob (`metadata_service`) turns the whole listener off; it cannot weaken
it.

### The header names are EC2's

`X-aws-ec2-metadata-token-ttl-seconds` and `X-aws-ec2-metadata-token`, with
EC2's `1..21600` TTL bounds.

The security property STR-56 asked for is a property of the *shape* of the
request — a `PUT` with a mandatory custom header — and holds identically
whatever that header is called. What only EC2's spelling additionally buys is
that unmodified guest tooling can complete the handshake at all: cloud-init's
Ec2 datasource knows one pair of names, and a Strato-prefixed pair would have
made the service unreachable from every stock image while inconveniencing no
attacker. The point of adopting `169.254.169.254` and `fd00:ec2::254` in the
first place was that guests already probe them; adopting the addresses and then
refusing the protocol would have thrown that away.

The cost is a shape obligation on STR-65: an EC2-named handshake sets the
expectation that what is behind it is EC2-shaped. That is where the EC2
renderer was going anyway.

### A session is bound to one instance

A token records the `vmId` it was minted for. Every request re-derives the
caller from its source address (see
[ADR 0003](./0003-imds-chassis-namespace.md)) and the token must agree.
Presented by any other instance — itself a perfectly legitimate caller — it is
refused.

### Tokens are stored as digests

Sessions are keyed by `SHA256(token)`. Nothing retains the token itself.

## Consequences

- **Stealing a neighbour's token buys nothing.** Without the binding, a token
  would be a bearer credential for *the metadata service*, and one guest that
  could read another's memory, logs, or environment would inherit its identity.
  With it, the token is only usable from the address it was minted from.
- **There is no constant-time comparison anywhere, and none is needed.** The
  lookup is a dictionary hit on a digest of a value the caller already supplied,
  so no secret is ever compared against attacker input. This is a design that
  avoids the problem rather than a mitigation of it, which matters because the
  repository has no constant-time helper to reach for. A heap dump yields
  digests.
- **Guest tooling works; guest tooling finds little.** cloud-init's Ec2
  datasource can now complete the handshake, and will get 404 for most of the
  tree until STR-65. Nothing depends on this yet — Strato still writes a NoCloud
  seed ISO, and `datasource_list` puts NoCloud first — but the partial tree is
  reachable and will look like a broken EC2 rather than a deliberate subset
  until STR-65 lands.
- **A guest can mint without limit**, so sessions are capped per instance and
  swept on mint. The cap evicts the soonest-expiring, so a loop costs a bounded
  amount and never evicts a well-behaved guest's newest token.
- **Hop-limit and mandatory-v2 are fleet-wide, not per instance.** AWS exposes
  both per instance; Strato's only per-workload lever remains `metadataEnabled`,
  which is per network (issue #1013 / STR-185).

## Alternatives considered

### Strato-prefixed header names, as STR-56 specified

Rejected: identical security, and it makes the service unusable from every
unmodified guest image. The names would have to be delivered to the guest by
vendor data — which is served *by the service the guest cannot yet talk to*.

### Accepting both spellings

Rejected as the worst of both. Two names to document, two to test, two for a
future deprecation, and the Strato-prefixed one would be used by nothing. If a
Strato-specific surface is ever needed it belongs on a Strato-specific *path*
(`/strato/v1/...`, which STR-62 already introduces), not on a second name for
the same header.

### Binding a session to the source address rather than to the instance

Rejected: an instance whose address changes mid-lease would silently lose its
session, and the identity that matters is the instance. The address is only how
the listener recognizes it.
