import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { afterEach, describe, expect, it, vi } from "vitest";
import { VMExecSessionsCard } from "./vm-exec-sessions-card";

const mocks = vi.hoisted(() => ({ get: vi.fn(), post: vi.fn(), allowed: false }));
vi.mock("@/lib/api/client", () => ({ api: { get: mocks.get, post: mocks.post } }));
vi.mock("@/lib/hooks", () => ({ usePermissions: () => ({ permissions: { terminate: mocks.allowed } }) }));
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }));

const live = { sessionId: "session-1", userId: "user-1", username: "alice", attachedAt: "2026-10-02T00:00:00Z", lastActivityAt: "2026-10-02T00:00:00Z", terminationRequested: false };
function show() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } });
  render(<QueryClientProvider client={client}><VMExecSessionsCard vmId="vm-1" /></QueryClientProvider>);
  return client;
}

describe("Live VM exec sessions", () => {
  afterEach(() => { cleanup(); vi.clearAllMocks(); mocks.allowed = false; });
  it("shows attached identity to readers and hides termination without exec permission", async () => {
    mocks.get.mockResolvedValue([live]);
    const client = show();
    expect(await screen.findByText("alice")).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Terminate" })).not.toBeInTheDocument();
    expect(mocks.get).toHaveBeenCalledWith("/api/vms/vm-1/exec-sessions", undefined, expect.any(AbortSignal));
    client.clear();
  });
  it("requests authorized termination and shows pending state after refetch", async () => {
    mocks.allowed = true;
    mocks.get.mockResolvedValueOnce([live]).mockResolvedValue([{ ...live, terminationRequested: true }]);
    mocks.post.mockResolvedValue(undefined);
    const client = show();
    fireEvent.click(await screen.findByRole("button", { name: "Terminate" }));
    await waitFor(() => expect(mocks.post).toHaveBeenCalledWith("/api/vms/vm-1/exec-sessions/session-1/terminate"));
    expect(await screen.findByText("Termination pending")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Terminate" })).toBeDisabled();
    client.clear();
  });
  it("distinguishes unavailable presence from an empty session list", async () => {
    mocks.get.mockRejectedValue(new Error("unavailable"));
    const client = show();
    expect(await screen.findByRole("alert")).toHaveTextContent("Could not load live sessions");
    expect(screen.queryByText("No attached sessions.")).not.toBeInTheDocument();
    client.clear();
  });
});
