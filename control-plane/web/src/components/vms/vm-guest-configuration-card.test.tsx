import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { VM } from "@/types/api";
import { VMGuestConfigurationCard } from "./vm-guest-configuration-card";

const mocks = vi.hoisted(() => ({
  allowed: true,
  read: vi.fn(),
  replace: vi.fn(),
  watch: vi.fn(),
}));
vi.mock("@/lib/hooks/use-permissions", () => ({ usePermissions: () => ({ permissions: { configure: mocks.allowed } }) }));
vi.mock("@/lib/api/vms", () => ({ vmsApi: { guestConfiguration: mocks.read, replaceGuestConfiguration: mocks.replace } }));
vi.mock("@/lib/stores/mutations-store", () => ({
  useMutationsStore: (selector: (value: { watch: typeof mocks.watch }) => unknown) => selector({ watch: mocks.watch }),
  acceptedMutation: (value: unknown) => value,
  acceptedSnapshotMutation: (value: unknown) => value,
}));
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }));

afterEach(() => cleanup());

const vm = { id: "vm-id", name: "test-vm", guestAgentEnabled: true } as VM;
const guestConfig = {
  packages: [{ name: "curl", state: "present" }],
  files: [{ path: "/etc/app.conf", content: "STR92_SECRET_SENTINEL", mode: "0600" }],
  services: [{ name: "sshd.service", enabled: true }],
  sysctls: [],
};
function mount() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  render(<QueryClientProvider client={client}><VMGuestConfigurationCard vm={vm} /></QueryClientProvider>);
  return client;
}

beforeEach(() => {
  mocks.allowed = true;
  mocks.read.mockReset().mockResolvedValue({ vmId: vm.id, desiredGeneration: 4, guestConfig });
  mocks.replace.mockReset();
  mocks.watch.mockReset();
});

describe("guest configuration editor", () => {
  it("fails closed without a deliberate grant", () => {
    mocks.allowed = false;
    mount();
    expect(screen.queryByRole("button", { name: "Edit configuration" })).not.toBeInTheDocument();
    expect(mocks.read).not.toHaveBeenCalled();
  });

  it("shows desired state as unconfirmed and keeps file content out of status", async () => {
    mount();
    expect(await screen.findByText("Desired generation 4")).toBeInTheDocument();
    expect(screen.getByText(/Observed guest configuration is unavailable/)).toBeInTheDocument();
    expect(screen.getByText(/Service sshd.service: desired enabled at boot/)).toBeInTheDocument();
    expect(screen.queryByText("STR92_SECRET_SENTINEL")).not.toBeInTheDocument();
  });

  it("rejects invalid JSON inline without sending a request or echoing input", async () => {
    mount();
    const edit = await screen.findByRole("button", { name: "Edit configuration" });
    await waitFor(() => expect(edit).toBeEnabled());
    fireEvent.click(edit);
    fireEvent.change(screen.getByLabelText("Configuration JSON"), { target: { value: "STR92_SECRET_SENTINEL{" } });
    fireEvent.click(screen.getByRole("button", { name: "Save desired configuration" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Enter valid JSON");
    expect(screen.getByRole("alert")).not.toHaveTextContent("STR92_SECRET_SENTINEL");
    expect(mocks.replace).not.toHaveBeenCalled();
  });

  it("keeps a dirty editor unchanged when polling returns newer desired state", async () => {
    const client = mount();
    const edit = await screen.findByRole("button", { name: "Edit configuration" });
    await waitFor(() => expect(edit).toBeEnabled());
    fireEvent.click(edit);
    fireEvent.change(screen.getByLabelText("Configuration JSON"), { target: { value: "null" } });
    await act(async () => {
      client.setQueryData(["vm-guest-config", vm.id], { vmId: vm.id, desiredGeneration: 5, guestConfig: null });
    });
    expect(screen.getByLabelText("Configuration JSON")).toHaveValue("null");
  });

  it("does not watch a no-op as a converging mutation", async () => {
    mocks.replace.mockResolvedValue(vm);
    mount();
    const edit = await screen.findByRole("button", { name: "Edit configuration" });
    await waitFor(() => expect(edit).toBeEnabled());
    fireEvent.click(edit);
    fireEvent.click(screen.getByRole("button", { name: "Save desired configuration" }));
    await waitFor(() => expect(mocks.replace).toHaveBeenCalledOnce());
    await waitFor(() => expect(screen.queryByLabelText("Configuration JSON")).not.toBeInTheDocument());
    expect(mocks.watch).not.toHaveBeenCalled();
  });

  it("preserves the idempotency key and dirty input after a lost response", async () => {
    mocks.replace.mockRejectedValueOnce(new TypeError("Failed to fetch")).mockResolvedValueOnce({ resource: vm, mutationId: "mutation-id", targetGeneration: 5 });
    mount();
    const edit = await screen.findByRole("button", { name: "Edit configuration" });
    await waitFor(() => expect(edit).toBeEnabled());
    fireEvent.click(edit);
    fireEvent.change(screen.getByLabelText("Configuration JSON"), { target: { value: "null" } });
    fireEvent.click(screen.getByRole("button", { name: "Save desired configuration" }));
    expect(await screen.findByRole("alert")).toBeInTheDocument();
    expect(screen.getByLabelText("Configuration JSON")).toHaveValue("null");
    fireEvent.click(screen.getByRole("button", { name: "Save desired configuration" }));
    await waitFor(() => expect(mocks.watch).toHaveBeenCalledOnce());
    expect(mocks.replace.mock.calls[0][2]).toEqual(mocks.replace.mock.calls[1][2]);
    expect(mocks.replace.mock.calls[0][1]).toEqual({ guestConfig: null });
  });
});
