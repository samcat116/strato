import { useOrganization } from "@/providers";
import { usePermissions } from "./use-permissions";

/**
 * Resolves the current organization plus whether the viewer may manage its
 * membership-scoped resources (groups, roles, policies). Shared by the
 * dedicated Access pages so each one doesn't re-derive the org id + can-i check.
 */
export function useCurrentOrgAccess() {
  const { currentOrg, isLoading: isOrgLoading } = useOrganization();
  const orgId = currentOrg?.id ?? "";

  const { permissions, isLoading: isPermissionsLoading } = usePermissions(
    orgId
      ? [
          {
            key: "manage_members",
            resourceType: "organization",
            resourceId: orgId,
            permission: "manage_members",
          },
        ]
      : []
  );

  return {
    orgId,
    canManage: permissions.manage_members ?? false,
    isLoading: isOrgLoading || (!!orgId && isPermissionsLoading),
  };
}
