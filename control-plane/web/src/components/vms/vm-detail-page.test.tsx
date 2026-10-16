import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { VM } from "@/types/api";
import { VMDetailPage } from "./vm-detail-page";

const mocks = vi.hoisted(() => ({ vm: {} as VM }));
vi.mock("@/lib/hooks", () => ({
  useVM: () => ({ data: mocks.vm, isLoading: false, error: null, refetch: vi.fn() }),
  useInvalidateVMs: () => vi.fn(),
  usePermissions: () => ({ permissions: { exec: false } }),
}));
vi.mock("next/dynamic", () => ({ default: () => function Terminal() {
  return <div data-testid="serial-console" />;
} }));
vi.mock("@/components/vms", () => ({
  VMStatusBadge: () => null, VMActions: () => null, LogViewer: () => null,
  VMVolumesCard: () => null, VMNetworkCard: () => null, VMSnapshotsCard: () => null,
  VMMetadataCard: () => null, VMIdentityCard: () => null,
}));
vi.mock("@/components/workloads/convergence-failure-alert", () => ({ ConvergenceFailureAlert: () => null }));
vi.mock("./vm-guest-configuration-card", () => ({ VMGuestConfigurationCard: () => null }));
vi.mock("./vm-exec-sessions-card", () => ({ VMExecSessionsCard: () => null }));
vi.mock("./vm-guest-agent-card", () => ({ VMGuestAgentCard: () => null }));

function show(backend: VM["hypervisorType"], status: VM["status"] = "Running") {
  mocks.vm = { id: "vm-1", name: "Test VM", hypervisorType: backend, status, cpu: 1,
    memory: 1024, metadataEnabled: false, guestAgentEnabled: false, graphicsConsole: false,
    createdAt: "2026-10-16T00:00:00Z", updatedAt: "2026-10-16T00:00:00Z" } as VM;
  render(<VMDetailPage id="vm-1" />);
}

describe("VM serial console availability", () => {
  afterEach(cleanup);
  it("does not offer an unsupported Apple console even while running", () => {
    show("apple_virtualization");
    const open = screen.getByRole("button", { name: "Open console" });
    expect(open).toBeDisabled();
    expect(open).toHaveAttribute("title", "Serial console is not supported by Apple Virtualization.");
    expect(screen.getByRole("tab", { name: /Console/ })).toBeDisabled();
    fireEvent.click(open);
    expect(screen.queryByTestId("serial-console")).not.toBeInTheDocument();
  });
  it.each(["qemu", "firecracker"] as const)("keeps the running %s console available", (backend) => {
    show(backend);
    fireEvent.click(screen.getByRole("button", { name: "Open console" }));
    expect(screen.getByTestId("serial-console")).toBeInTheDocument();
  });
  it("requires a running supported VM before opening its console", () => {
    show("qemu", "Shutdown");
    expect(screen.getByRole("button", { name: "Open console" })).toBeDisabled();
  });
});
