# Identity and Access Management
This document describes the IAM architecture and objects for Strato.

The top level IAM object is an organization. This is where SSO and users are stored at. Within an org, there are projects. A project is a grouping of cloud resources. Projects can be organized within an organization in OUs.

## SSO (OIDC) authorization mapping

Each organization can configure OIDC providers for single sign-on. Beyond authentication, a provider can map ID-token claims onto Strato's authorization model:

- **`groupsClaim`** — the name of the ID-token claim holding group/role values (e.g. `groups` or `roles`). Accepts an array of strings or a single string. Unset disables claim mapping.
- **`groupMappings`** — a list of `{claimValue, groupID}` pairs mapping IdP claim values to Strato groups. Mapped groups are IdP-managed: on every OIDC login the user is added to mapped groups whose claim value is present in the token and removed from mapped groups whose claim values are absent. Groups not listed in any mapping (manually managed or SCIM-provisioned) are never touched.
- **`adminClaimValues`** — claim values that grant the organization `admin` role. When set, the IdP is authoritative for the org role on every login: a matching value promotes to admin, no match sets the user to the default role. The organization's last admin is never demoted this way, so a misconfigured IdP cannot lock the org out. When unset, org roles are never changed by OIDC logins.
- **`defaultRole`** — the org role given to just-in-time provisioned users (`member` or `admin`, default `member`).

### SCIM and OIDC convergence

When both SCIM provisioning and OIDC login are configured for the same IdP, the two identity paths converge on one user record: an OIDC login whose `sub` matches a SCIM user's `externalId` links to (rather than duplicates) the SCIM-provisioned user. Because subjects are only unique per issuer and SCIM mappings don't record their IdP, this `sub` match applies only in organizations with a single OIDC provider; with several providers, identities converge via matching verified email instead. Users deactivated via SCIM (`active: false`) are denied OIDC login.
