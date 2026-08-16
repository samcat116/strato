import type { StorageDevice } from "@/types/api";

export interface StorageSiteSummary {
  id: string;
  name: string;
}

export interface StorageAgentSummary {
  id: string;
  siteId: string;
  name: string;
}

export interface StorageAgentGroup {
  agentId: string;
  agentName: string;
  devices: StorageDevice[];
}

export interface StorageSiteGroup {
  siteId: string;
  siteName: string;
  agents: StorageAgentGroup[];
}

export const osdSelectionWarning =
  "Future Ceph OSD provisioning may erase all data on this disk. This selection does not format or modify the disk now.";

export function groupStorageDevices(
  devices: StorageDevice[],
  sites: StorageSiteSummary[],
  agents: StorageAgentSummary[],
): StorageSiteGroup[] {
  const siteNames = new Map(sites.map((site) => [site.id, site.name]));
  const agentNames = new Map(agents.map((agent) => [agent.id, agent.name]));
  const grouped = new Map<string, Map<string, StorageDevice[]>>();

  for (const device of devices) {
    const site = grouped.get(device.siteId) ?? new Map<string, StorageDevice[]>();
    const agent = site.get(device.agentId) ?? [];
    agent.push(device);
    site.set(device.agentId, agent);
    grouped.set(device.siteId, site);
  }

  return [...grouped.entries()]
    .map(([siteId, agentMap]) => ({
      siteId,
      siteName: siteNames.get(siteId) ?? "Unknown site",
      agents: [...agentMap.entries()]
        .map(([agentId, agentDevices]) => ({
          agentId,
          agentName: agentNames.get(agentId) ?? "Unknown agent",
          devices: [...agentDevices].sort(compareDevices),
        }))
        .sort((left, right) =>
          compareText(left.agentName, right.agentName) || compareText(left.agentId, right.agentId),
        ),
    }))
    .sort((left, right) =>
      compareText(left.siteName, right.siteName) || compareText(left.siteId, right.siteId),
    );
}

function compareDevices(left: StorageDevice, right: StorageDevice): number {
  if (left.present !== right.present) return left.present ? -1 : 1;
  return compareText(left.devicePath, right.devicePath) || compareText(left.id, right.id);
}

function compareText(left: string, right: string): number {
  return left.localeCompare(right, undefined, { numeric: true, sensitivity: "base" });
}

export function formatDeviceSize(bytes: number): string {
  const units = ["B", "KB", "MB", "GB", "TB", "PB"];
  let value = Math.max(0, bytes);
  let unit = 0;
  while (value >= 1_000 && unit < units.length - 1) {
    value /= 1_000;
    unit += 1;
  }
  return unit === 0 ? `${value} B` : `${value.toFixed(2)} ${units[unit]}`;
}

const useLabels: Record<StorageDevice["uses"][number], string> = {
  childDevice: "Child device",
  partitionTable: "Partition table",
  filesystem: "Filesystem",
  mounted: "Mounted",
  swap: "Swap",
  lvmPhysicalVolume: "LVM physical volume",
  readOnly: "Read only",
};

export function formatDeviceUses(uses: StorageDevice["uses"]): string {
  return uses.length === 0 ? "None" : uses.map((use) => useLabels[use]).join(", ");
}

export function storageDeviceStatus(device: StorageDevice): string {
  if (!device.present) return "Missing";
  switch (device.state) {
    case "available": return "Available";
    case "inUse": return "In use";
    case "draining": return "Draining";
    case "faulted": return "Faulted";
  }
}
