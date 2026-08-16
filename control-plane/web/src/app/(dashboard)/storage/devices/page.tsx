"use client";

import { useState } from "react";
import { StorageDeviceInventory } from "@/components/storage-devices/storage-device-inventory";
import {
  useAgents,
  useSetStorageDeviceOsdEligibility,
  useSites,
  useStorageDevices,
} from "@/lib/hooks";

export default function StorageDevicesPage() {
  const [siteId, setSiteId] = useState<string>();
  const sites = useSites();
  const agents = useAgents();
  const devices = useStorageDevices({ siteId });
  const mutation = useSetStorageDeviceOsdEligibility();

  return (
    <div className="mx-auto max-w-7xl space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Storage Devices</h1>
        <p className="text-muted-foreground">
          Inspect agent-reported physical disks and select safe disks for future Ceph OSD provisioning.
        </p>
      </div>
      <StorageDeviceInventory
        devices={devices.data ?? []}
        sites={(sites.data ?? []).map((site) => ({ id: site.id, name: site.name }))}
        agents={(agents.data ?? []).flatMap((agent) => {
          if (!agent.siteId) return [];
          return [{ id: agent.id, siteId: agent.siteId, name: agent.name }];
        })}
        selectedSiteId={siteId}
        onSiteChange={setSiteId}
        isLoading={devices.isLoading || sites.isLoading || agents.isLoading}
        error={(devices.error ?? sites.error ?? agents.error) as Error | null}
        mutationError={mutation.error as Error | null}
        mutationPending={mutation.isPending}
        onRetry={() => void Promise.all([devices.refetch(), sites.refetch(), agents.refetch()])}
        onSetOsdEligibility={(deviceId, osdEligible) => mutation.mutateAsync({ deviceId, osdEligible }).then(() => undefined)}
      />
    </div>
  );
}
