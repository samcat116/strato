import { cleanup, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { Agent } from "@/types/api";
import { AgentDetailPage } from "./agent-detail-page";

const agent: Agent = {
  id: "node-1", name: "Node 1", hostname: "hypervisor-1", version: "main-test",
  status: "online", administrativelyOffline: false, isOnline: true,
  resources: {
    totalCPU: 12, availableCPU: 12,
    totalMemory: 16384, availableMemory: 16384,
    totalDisk: 500000, availableDisk: 400000, physicalFreeDisk: 400000,
  },
  hypervisors: [
    { type: "qemu", available: true, accelerated: true, supportsSnapshots: true },
    { type: "apple_virtualization", available: true, accelerated: true, supportsSnapshots: false },
    {
      type: "firecracker", available: false, accelerated: false,
      supportsSnapshots: true, unavailabilityReason: "Firecracker binary not found",
    },
  ],
  sandboxCapable: false, sandboxNetworkingCapable: false,
  tpmCapable: false, resolverCapable: false, metadataServiceCapable: false,
  dependencyObservations: [], siteId: "site-1", updateAvailable: false, autoUpdate: false,
};

vi.mock("@/lib/hooks", () => ({
  useAgent: () => ({ data: agent, isLoading: false, error: null, refetch: vi.fn() }),
  useVMs: () => ({ data: [] }),
}));
vi.mock("@/components/agents/agent-update-action", () => ({ AgentUpdateAction: () => null }));
vi.mock("@/components/agents/agent-auto-update", () => ({ AgentAutoUpdateCard: () => null }));
vi.mock("@/components/agents/agent-workload-safety", () => ({ AgentWorkloadSafetyCard: () => null }));
vi.mock("@/components/agents/agent-host-info-card", () => ({ AgentHostInfoCard: () => null }));
vi.mock("@/components/agents/agent-force-offline-action", () => ({ AgentForceOfflineAction: () => null }));

describe("AgentDetailPage", () => {
  afterEach(cleanup);

  it("renders backend names and flat snapshot support only for available hypervisors", () => {
    render(<AgentDetailPage agentId={agent.id} />);

    expect(screen.getByText("Apple Virtualization")).toBeVisible();
    expect(screen.queryByText("Apple Virtualization snapshots")).toBeNull();
    expect(screen.getByText("QEMU snapshots")).toBeVisible();
    expect(screen.queryByText("Firecracker snapshots")).toBeNull();
    expect(screen.getByRole("heading", { name: "Node 1" })).toBeVisible();
  });
});
