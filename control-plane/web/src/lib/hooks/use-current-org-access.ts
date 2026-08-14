import { useOrganization } from "@/providers";
import { usePermissions } from "./use-permissions";

/**
 * Resolves the current organization plus whether the viewer may manage its
 * membership-scoped resources (groups, roles, policies). Shared by the
 * dedicated Access pages so each one doesn't re-derive the org id + can-i check.
 */
export function useCurrentOrgAccess() {
  const {
    currentOrg,
    isLoading: isOrgLoading,
    error: organizationError,
    refresh: refreshOrganizations,
  } = useOrganization();
  const orgId = currentOrg?.id ?? "";

  const {
    permissions,
    isLoading: isPermissionsLoading,
    error: permissionsError,
    refetch: refetchPermissions,
  } = usePermissions(
    orgId
      ? [
          {
            key: "update_org",
            action: "org:update",
            node: { type: "organization", id: orgId },
          },
        ]
      : []
  );

  return {
    orgId,
    canManage: permissions.update_org ?? false,
    isLoading: isOrgLoading || (!!orgId && isPermissionsLoading),
    error: organizationError ?? permissionsError,
    retry: async () => {
      await refreshOrganizations();
      if (orgId) await refetchPermissions();
    },
  };
}
