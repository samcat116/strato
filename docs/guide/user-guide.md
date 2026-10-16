# User guide

Use this path when an operator has already installed Strato. If you are also
setting up the platform, start with [Getting started](./getting-started.md).

## Sign in and select a project

Sign in with your passkey, or the identity provider your operator configured.
Use the URL supplied by your operator: WebAuthn configuration must match the
browser origin. For login failures, see [WebAuthn debugging](../debugging/webauthn.md).

Workloads belong to a project inside an organization, optionally under folders.
Create or select a project in the header switcher before creating a VM or
sandbox. Your role and inherited guardrails determine which actions and
resources you can see. Ask an administrator for the required access; see
[IAM and permissions](../deployment/iam.md) for the model and configuration.

## Prepare and create a workload

For a VM, use the [first VM checklist](./getting-started.md#create-your-first-vm):
a ready image with compatible artifacts, an online agent with capacity, and a
network for each interface. Agent enrollment and site networking are operator
tasks. Image import and network creation require the corresponding permissions.

For disposable OCI-based workloads, see [sandboxes](../architecture/sandboxes.md)
for the supported lifecycle and constraints. Sandboxes require a Linux
Firecracker agent; an OCI image alone does not supply a hypervisor.

Creation and lifecycle actions are asynchronous. The UI follows the target
generation until the agent reports convergence or an error. A successful API
acceptance is not evidence of a booted guest. Use the displayed conditions and
[logs](../deployment/logging.md) when a workload fails to converge.

## Connect and provision

- [Instance metadata and bootstrap](./instance-metadata.md) explains cloud-init,
  metadata access, and compatibility choices.
- [Graphics consoles](./graphics-console.md) covers the optional graphical
  console; enable it at VM creation.
- [Windows guests](./windows-guests.md) covers firmware, TPM, and image requirements.
- [CLI setup](./getting-started.md#install-the-cli) covers sign-in and shell usage.
  [API reference](../api-reference.md) is the entry point for integrations.

SSH reachability depends on the network, routing, and security groups configured
for your VM. A console opening successfully does not prove external network
access. Ask the operator to check [networking](../architecture/networking.md)
when addresses exist but connections fail.

## Understand the limits

The [documentation map](../documentation.md) separates current behavior from
proposals, gated features, and cutover procedures. A design document is not a
promise that a feature is enabled on your installation. Operators should confirm
the deployed version, host capabilities, and local validation evidence.
