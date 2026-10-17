import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { VM } from "@/types/api";
import { VMSnapshotsCard } from "./vm-snapshots-card";

vi.mock("@/lib/hooks", () => ({
  useVMSnapshots: () => ({ data: [], isLoading: false, error: null }),
}));
vi.mock("@/lib/hooks/use-accepted-mutation", () => ({
  useAcceptedMutation: () => ({ isLoading: false, busyKey: null, run: vi.fn() }),
}));

function show(hypervisorType: VM["hypervisorType"], status: VM["status"]) {
  const vm = { id: "vm-1", name: "Test VM", hypervisorType, status } as VM;
  render(<VMSnapshotsCard vm={vm} />);
}

describe("VM checkpoint availability", () => {
  afterEach(cleanup);

  it.each(["Running", "Paused"] as const)("disables Apple checkpoints while %s", (status) => {
    show("apple_virtualization", status);
    const checkpoint = screen.getByRole("button", { name: "Checkpoint" });
    expect(checkpoint).toBeDisabled();
    expect(checkpoint).toHaveAttribute("title", "Checkpoints are not supported by Apple Virtualization.");
    expect(screen.getByText("Checkpoints are not supported by Apple Virtualization.")).toBeInTheDocument();
    fireEvent.click(checkpoint);
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
  });

  it.each([["qemu", "Running"], ["firecracker", "Paused"]] as const)(
    "allows %s checkpoints while %s", (backend, status) => {
      show(backend, status);
      const checkpoint = screen.getByRole("button", { name: "Checkpoint" });
      expect(checkpoint).toBeEnabled();
      fireEvent.click(checkpoint);
      expect(screen.getByRole("dialog")).toBeInTheDocument();
    });

  it("keeps stopped VM checkpoints disabled with a power-state explanation", () => {
    show("qemu", "Shutdown");
    expect(screen.getByRole("button", { name: "Checkpoint" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "Checkpoint" })).toHaveAttribute(
      "title", "The VM must be running or paused to be checkpointed");
  });
});
