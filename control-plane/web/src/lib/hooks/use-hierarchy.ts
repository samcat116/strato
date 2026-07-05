import { useQuery, keepPreviousData } from "@tanstack/react-query";
import { hierarchyApi } from "@/lib/api/hierarchy";

export function useHierarchy(organizationId: string | undefined) {
  return useQuery({
    queryKey: ["hierarchy", organizationId],
    queryFn: () =>
      organizationId
        ? hierarchyApi.get(organizationId)
        : Promise.reject("No organization ID"),
    enabled: !!organizationId,
  });
}

export function useHierarchySearch(
  organizationId: string | undefined,
  query: string
) {
  const trimmed = query.trim();
  return useQuery({
    queryKey: ["hierarchy", "search", organizationId, trimmed],
    queryFn: () =>
      organizationId
        ? hierarchyApi.search(organizationId, trimmed)
        : Promise.reject("No organization ID"),
    enabled: !!organizationId && trimmed.length > 0,
    placeholderData: keepPreviousData,
  });
}
