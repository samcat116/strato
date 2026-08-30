import { useQuery } from "@tanstack/react-query";
import { hierarchyApi } from "@/lib/api/hierarchy";
import type { OrganizationHierarchy } from "@/types/api";

export function useHierarchy(organizationId: string | undefined) {
  return useQuery<OrganizationHierarchy>({
    queryKey: ["hierarchy", organizationId],
    queryFn: ({ signal }) =>
      organizationId
        ? hierarchyApi.get(organizationId, signal)
        : Promise.reject("No organization ID"),
    enabled: !!organizationId,
  });
}
