import { describe, expect, it } from "vitest";
import type { StorageDevice } from "@/types/api";
import {
  formatDeviceSize,
  formatDeviceUses,
  groupStorageDevices,
  osdSelectionWarning,
  storageDeviceStatus,
} from "./storage-device-model";

function device(overrides: Partial<StorageDevice> = {}): StorageDevice {
  return {
    id: "device-1",
    agentId: "agent-1",
    siteId: "site-1",
    devicePath: "/dev/sdb",
    sizeBytes: 1_000_000_000_000,
    rotational: false,
    uses: [],
    role: "unassigned",
    state: "available",
    present: true,
    osdEligible: false,
    canMarkOsdEligible: true,
    ...overrides,
  };
}

describe("storage device view model", () => {
  it("groups by site and agent with stable name and device ordering", () => {
    const groups = groupStorageDevices(
      [
        device({ id: "z", siteId: "site-b", agentId: "agent-b", devicePath: "/dev/sdc" }),
        device({ id: "b", devicePath: "/dev/sdb", present: false }),
        device({ id: "a", devicePath: "/dev/sda" }),
      ],
      [
        { id: "site-b", name: "Zulu" },
        { id: "site-1", name: "Alpha" },
      ],
      [
        { id: "agent-b", siteId: "site-b", name: "node-z" },
        { id: "agent-1", siteId: "site-1", name: "node-a" },
      ],
    );

    expect(groups.map((group) => group.siteName)).toEqual(["Alpha", "Zulu"]);
    expect(groups[0].agents[0].devices.map((item) => item.id)).toEqual(["a", "b"]);
  });

  it("formats size, observed uses, and missing status for operators", () => {
    expect(formatDeviceSize(1_000_000_000_000)).toBe("1.00 TB");
    expect(formatDeviceSize(4_096)).toBe("4.10 KB");
    expect(formatDeviceUses(["mounted", "lvmPhysicalVolume", "childDevice"])).toBe(
      "Mounted, LVM physical volume, Child device",
    );
    expect(storageDeviceStatus(device({ present: false, state: "faulted" }))).toBe("Missing");
    expect(storageDeviceStatus(device({ state: "inUse" }))).toBe("In use");
  });

  it("uses the approved warning for future OSD selection", () => {
    expect(osdSelectionWarning).toBe(
      "Future Ceph OSD provisioning may erase all data on this disk. This selection does not format or modify the disk now.",
    );
  });
});
