import { useQuery, keepPreviousData } from "@tanstack/react-query";
import { hierarchyApi } from "@/lib/api/hierarchy";
import type { HierarchySearchResponse, OrganizationHierarchy } from "@/types/api";

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

export function useHierarchySearch(
  organizationId: string | undefined,
  query: string
) {
  const trimmed = query.trim();
  return useQuery<HierarchySearchResponse>({
    queryKey: ["hierarchy", "search", organizationId, trimmed],
    queryFn: ({ signal }) =>
      organizationId
        ? hierarchyApi.search(organizationId, trimmed, undefined, signal)
        : Promise.reject("No organization ID"),
    enabled: !!organizationId && trimmed.length > 0,
    placeholderData: keepPreviousData,
  });
}
