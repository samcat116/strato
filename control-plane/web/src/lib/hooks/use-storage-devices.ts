import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  storageDevicesApi,
  type StorageDeviceFilters,
} from "@/lib/api/storage-devices";
import { useOrganization } from "@/providers";

export function useStorageDevices(filters: Omit<StorageDeviceFilters, "organizationId"> = {}) {
  const { currentOrg, isLoading: orgLoading } = useOrganization();
  const resolved = {
    organizationId: currentOrg?.id,
    siteId: filters.siteId,
    agentId: filters.agentId,
  };

  return useQuery({
    queryKey: ["storage-devices", resolved],
    queryFn: ({ signal }) => storageDevicesApi.list(resolved, signal),
    enabled: !orgLoading,
    refetchInterval: 10_000,
  });
}

export function useSetStorageDeviceOsdEligibility() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ deviceId, osdEligible }: { deviceId: string; osdEligible: boolean }) =>
      storageDevicesApi.setOsdEligibility(deviceId, osdEligible),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["storage-devices"] });
    },
  });
}
