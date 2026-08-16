import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { StorageDevice } from "@/types/api";
import { StorageDeviceInventory } from "./storage-device-inventory";

const permissionState = vi.hoisted(() => ({ values: {} as Record<string, boolean> }));

vi.mock("@/lib/hooks/use-permissions", () => ({
  usePermissions: () => ({ permissions: permissionState.values, isLoading: false }),
}));

function device(overrides: Partial<StorageDevice> = {}): StorageDevice {
  return {
    id: "device-1",
    agentId: "agent-1",
    siteId: "site-1",
    identityKind: "wwn",
    identityValue: "5000cca1",
    devicePath: "/dev/sdb",
    sizeBytes: 1_000_000_000_000,
    model: "Fast Disk",
    serial: "SERIAL-1",
    wwn: "0x5000CCA1",
    rotational: false,
    uses: [],
    role: "unassigned",
    state: "available",
    present: true,
    lastSeenAt: "2026-08-16T17:00:00Z",
    osdEligible: false,
    canMarkOsdEligible: true,
    ...overrides,
  };
}

const sites = [
  { id: "site-1", name: "Portland" },
  { id: "site-2", name: "Seattle" },
];
const agents = [
  { id: "agent-1", siteId: "site-1", name: "node-a" },
  { id: "agent-2", siteId: "site-2", name: "node-b" },
];

describe("storage device inventory", () => {
  afterEach(cleanup);

  beforeEach(() => {
    permissionState.values = { "manage:agent-1": true, "manage:agent-2": true };
  });

  it("renders every reported fact grouped under site and agent", () => {
    render(
      <StorageDeviceInventory
        devices={[
          device({ uses: ["mounted", "filesystem"], rotational: true }),
          device({ id: "device-2", siteId: "site-2", agentId: "agent-2", devicePath: "/dev/sdc", present: false }),
        ]}
        sites={sites}
        agents={agents}
        onSetOsdEligibility={vi.fn()}
      />,
    );

    expect(screen.getByText("Portland")).toBeInTheDocument();
    expect(screen.getByText("node-a")).toBeInTheDocument();
    expect(screen.getByText("Seattle")).toBeInTheDocument();
    expect(screen.getByText("/dev/sdb")).toBeInTheDocument();
    expect(screen.getAllByText("1.00 TB")).toHaveLength(2);
    expect(screen.getAllByText(/Fast Disk/)).toHaveLength(2);
    expect(screen.getAllByText(/SERIAL-1/)).toHaveLength(2);
    expect(screen.getAllByText(/5000CCA1/)).toHaveLength(2);
    expect(screen.getByText(/HDD/)).toBeInTheDocument();
    expect(screen.getByText("Mounted, Filesystem")).toBeInTheDocument();
    expect(screen.getByText("Missing")).toBeInTheDocument();
  });

  it("filters the rendered inventory by site", () => {
    render(
      <StorageDeviceInventory
        devices={[device(), device({ id: "device-2", siteId: "site-2", agentId: "agent-2" })]}
        sites={sites}
        agents={agents}
        selectedSiteId="site-1"
        onSiteChange={vi.fn()}
        onSetOsdEligibility={vi.fn()}
      />,
    );
    expect(screen.getByRole("heading", { name: "Portland" })).toBeInTheDocument();
    expect(screen.queryByRole("heading", { name: "Seattle" })).not.toBeInTheDocument();
  });

  it("confirms a safe false-to-true transition with the data-loss warning", async () => {
    const setEligibility = vi.fn().mockResolvedValue(undefined);
    render(
      <StorageDeviceInventory devices={[device()]} sites={sites} agents={agents} onSetOsdEligibility={setEligibility} />,
    );

    fireEvent.click(screen.getByRole("switch", { name: "OSD eligibility for /dev/sdb" }));
    expect(screen.getByText(/Future Ceph OSD provisioning may erase all data/)).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Mark OSD-eligible" }));
    expect(setEligibility).toHaveBeenCalledOnce();
    expect(setEligibility).toHaveBeenCalledWith("device-1", true);
  });

  it("shows server blockers and leaves unsafe unselected controls disabled", () => {
    render(
      <StorageDeviceInventory
        devices={[device({ canMarkOsdEligible: false, osdEligibilityBlockedReason: "inUse", state: "inUse", uses: ["mounted"] })]}
        sites={sites}
        agents={agents}
        onSetOsdEligibility={vi.fn()}
      />,
    );
    expect(screen.getByRole("switch")).toBeDisabled();
    expect(screen.getByText("The device is already in use.")).toBeInTheDocument();
  });

  it("disables a selected disk directly even when it is now unsafe", () => {
    const setEligibility = vi.fn();
    render(
      <StorageDeviceInventory
        devices={[device({ osdEligible: true, role: "osd", present: false, canMarkOsdEligible: false, osdEligibilityBlockedReason: "notPresent" })]}
        sites={sites}
        agents={agents}
        onSetOsdEligibility={setEligibility}
      />,
    );
    const control = screen.getByRole("switch");
    expect(control).toBeEnabled();
    expect(control).toHaveAttribute("aria-checked", "true");
    fireEvent.click(control);
    expect(setEligibility).toHaveBeenCalledWith("device-1", false);
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
  });

  it("shows state without mutation controls when agent manage is denied", () => {
    permissionState.values = { "manage:agent-1": false };
    render(
      <StorageDeviceInventory devices={[device()]} sites={sites} agents={agents} onSetOsdEligibility={vi.fn()} />,
    );
    expect(screen.getByRole("switch")).toBeDisabled();
    expect(screen.getByText("Read-only access")).toBeInTheDocument();
  });

  it("renders loading, empty, fetch-error, and mutation-error states", () => {
    const { rerender } = render(
      <StorageDeviceInventory devices={[]} sites={sites} agents={agents} isLoading onSetOsdEligibility={vi.fn()} />,
    );
    expect(screen.getByRole("status", { name: "Loading storage devices" })).toBeInTheDocument();

    rerender(<StorageDeviceInventory devices={[]} sites={sites} agents={agents} error={new Error("Inventory unavailable")} onSetOsdEligibility={vi.fn()} />);
    expect(screen.getByText("Inventory unavailable")).toBeInTheDocument();

    rerender(<StorageDeviceInventory devices={[]} sites={sites} agents={agents} mutationError={new Error("The device observation is older than 60 seconds.")} onSetOsdEligibility={vi.fn()} />);
    expect(screen.getByText("The device observation is older than 60 seconds.")).toBeInTheDocument();
    expect(screen.getByText("No storage devices reported.")).toBeInTheDocument();
  });
});
