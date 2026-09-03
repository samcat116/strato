import { useQuery } from "@tanstack/react-query";
import { organizationsApi } from "@/lib/api/organizations";

export function useOrganizationMembers(orgId: string) {
  return useQuery({
    queryKey: ["organization-members", orgId],
    queryFn: ({ signal }) => organizationsApi.listMembers(orgId, signal),
    enabled: !!orgId,
  });
}
