import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import FleetRunPage from "./page";

const { api } = vi.hoisted(() => ({ api: vi.fn() }));
vi.mock("@/lib/api/client", () => ({ apiClient: api }));
const preview = {
  id: "fleet-1", command: ["/usr/bin/id"], confirmed: false, complete: false,
  deadline: "2026-10-02T00:10:00Z",
  entries: [{ vmID: "vm-1", name: "worker", state: "ready" },
    { vmID: "vm-2", name: "denied", state: "skipped", reason: "Not authorized" }],
  operations: [],
};
function mount() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  render(<QueryClientProvider client={client}><FleetRunPage /></QueryClientProvider>);
}

afterEach(cleanup);
beforeEach(() => api.mockReset());

describe("Fleet command confirmation", () => {
  it("resolves without dispatch and confirms only the displayed exact list", async () => {
    api.mockResolvedValueOnce(preview)
      .mockResolvedValueOnce({ ...preview, confirmed: true, complete: true })
      .mockResolvedValue({ ...preview, confirmed: true, complete: true });
    mount();
    fireEvent.change(screen.getByLabelText("Selector"), { target: { value: "project=p1" } });
    fireEvent.click(screen.getByText("Resolve targets"));
    await screen.findByText("worker · vm-1");
    expect(api).toHaveBeenCalledTimes(1);
    expect(screen.getByText("Not authorized")).toBeInTheDocument();
    fireEvent.click(screen.getByText("Confirm and run on these VMs"));
    await waitFor(() => expect(api).toHaveBeenCalledWith("/api/vm-fleet-runs/fleet-1/confirm", {
      method: "POST", body: JSON.stringify({ vmIDs: ["vm-1", "vm-2"] }),
    }));
    await screen.findByText(/Complete/);
  });

  it("invalidates confirmation when command input changes and refuses malformed argv", async () => {
    api.mockResolvedValue(preview);
    mount();
    fireEvent.click(screen.getByText("Resolve targets"));
    await screen.findByText("Confirm and run on these VMs");
    fireEvent.change(screen.getByLabelText("Command arguments"), { target: { value: '"bad"' } });
    expect(screen.queryByText("Confirm and run on these VMs")).not.toBeInTheDocument();
    fireEvent.click(screen.getByText("Resolve targets"));
    await screen.findByRole("alert");
    expect(api).toHaveBeenCalledTimes(1);
  });

  it("reloads interrupted runs without confirmation or dispatch and shows partial output", async () => {
    api.mockResolvedValue({ ...preview, confirmed: true, complete: true,
      entries: [{ vmID: "vm-1", name: "worker", state: "dispatched", operationID: "op-1" }],
      operations: [{ id: "op-1", status: "succeeded", result: {
        stdout: "captured stdout", stderr: "captured stderr", exitCode: 7, truncated: true,
      } }],
    });
    mount();
    fireEvent.change(screen.getByLabelText("Saved fleet run ID"), { target: { value: "fleet-1" } });
    fireEvent.click(screen.getByText("Load results"));
    await screen.findByText("captured stdout");
    expect(screen.getByText("succeeded · Exit 7")).toBeInTheDocument();
    expect(screen.getByText("captured stderr")).toBeInTheDocument();
    expect(screen.getByText("Load full captured output")).toBeInTheDocument();
    expect(api.mock.calls.every((call) => call.length === 1)).toBe(true);
    expect(screen.queryByText("Confirm and run on these VMs")).not.toBeInTheDocument();
  });
});
