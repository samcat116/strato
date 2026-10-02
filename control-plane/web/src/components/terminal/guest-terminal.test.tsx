import React from "react";
import type { ActionCheckItem } from "@/types/api";
import type { GuestTerminalProps } from "./guest-terminal";

interface TestTerminal {
  write: ReturnType<typeof vi.fn>; dispose: ReturnType<typeof vi.fn>;
  data?: (data: string) => void; resize?: (size: { cols: number; rows: number }) => void;
}
import { act, fireEvent, render, screen, waitFor, cleanup } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  vmExec: vi.fn(), sandboxExec: vi.fn(), terminals: [] as TestTerminal[],
  vm: { id: "vm-1", name: "Test VM", status: "Running", guestAgentEnabled: true, conditions: {}, createdAt: "2026-01-01", updatedAt: "2026-01-01" },
  allowed: true,
}));
vi.mock("@/lib/api/vms", () => ({ vmsApi: { exec: mocks.vmExec } }));
vi.mock("@/lib/api/sandboxes", () => ({ sandboxesApi: { exec: mocks.sandboxExec } }));
vi.mock("@xterm/xterm", () => ({ Terminal: class {
  rows = 24; cols = 80; write = vi.fn(); reset = vi.fn(); dispose = vi.fn();
  data?: (data: string) => void; resize?: (size: { cols: number; rows: number }) => void;
  constructor() { mocks.terminals.push(this); }
  open() {} loadAddon() {}
  onData(fn: (data: string) => void) { this.data = fn; return { dispose: vi.fn() }; }
  onResize(fn: (size: { cols: number; rows: number }) => void) { this.resize = fn; return { dispose: vi.fn() }; }
} }));
vi.mock("@xterm/addon-fit", () => ({ FitAddon: class { fit() {} } }));
vi.mock("@/lib/hooks", () => ({
  useVM: () => ({ data: mocks.vm }), useInvalidateVMs: () => vi.fn(),
  usePermissions: (checks: ActionCheckItem[]) => {
    expect(checks).toEqual([{ key: "exec", action: "vm:exec", node: { type: "virtual_machine", id: mocks.vm.id } }]);
    return { permissions: { exec: mocks.allowed } };
  },
}));
vi.mock("@/components/vms/vm-exec-sessions-card", () => ({ VMExecSessionsCard: () => null }));
vi.mock("@/components/vms", () => Object.fromEntries([
  "VMStatusBadge", "VMActions", "LogViewer", "VMVolumesCard", "VMNetworkCard", "VMSnapshotsCard", "VMMetadataCard", "VMIdentityCard",
].map(name => [name, () => null])));
vi.mock("next/dynamic", () => ({ default: () => (props: GuestTerminalProps) => props.resourceKind ? <GuestTerminal {...props} /> : <div>Serial console</div> }));
import { GuestTerminal } from "./guest-terminal";
import { SandboxTerminal } from "./sandbox-terminal";
import { VMDetailPage } from "@/components/vms/vm-detail-page";

class Socket {
  static OPEN = 1;
  static instances: Socket[] = [];
  readyState = 1; binaryType = "";
  onopen: (() => void) | null = null;
  onmessage: ((event: { data: unknown }) => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: ((event: { reason: string }) => void) | null = null;
  send = vi.fn(); close = vi.fn();
  constructor(public url: string) { Socket.instances.push(this); }
  frame(data: unknown) { act(() => this.onmessage?.({ data: typeof data === "object" && !(data instanceof ArrayBuffer) ? JSON.stringify(data) : data })); }
}
const session = { websocketPath: "/api/vms/vm-1/exec/session-1/attach" };
const terminal = () => mocks.terminals.at(-1)!;
const socket = () => Socket.instances.at(-1)!;
async function connected() {
  await waitFor(() => expect(Socket.instances.length).toBeGreaterThan(0));
  socket().frame({ type: "ready" });
  expect(screen.getByText("Connected")).toBeVisible();
}
beforeEach(() => {
  vi.stubGlobal("WebSocket", Socket);
  vi.stubGlobal("ResizeObserver", class { observe() {} disconnect() {} });
  mocks.vm = { id: "vm-1", name: "Test VM", status: "Running", guestAgentEnabled: true, conditions: {}, createdAt: "2026-01-01", updatedAt: "2026-01-01" };
  mocks.allowed = true; mocks.terminals.length = 0; Socket.instances.length = 0;
  mocks.vmExec.mockReset().mockResolvedValue(session);
  mocks.sandboxExec.mockReset().mockResolvedValue(session);
});
afterEach(() => { cleanup(); vi.unstubAllGlobals(); });

describe("VM exec UI", () => {
  it("gates exec independently from recorded commands, preserves console and handles repeated tab closure", async () => {
    render(<VMDetailPage id="vm-1" />);
    const exec = screen.getByRole("tab", { name: "Exec" });
    expect(screen.getByRole("tab", { name: "Console" })).toBeEnabled();
    fireEvent.mouseDown(exec, { button: 0, ctrlKey: false });
    await connected();
    expect(mocks.vmExec).toHaveBeenCalledWith("vm-1", { command: ["/bin/sh"], tty: true, rows: 24, cols: 80 });
    for (let i = 0; i < 2; i++) {
      const previous = socket();
      fireEvent.mouseDown(screen.getByRole("tab", { name: "Overview" }), { button: 0, ctrlKey: false });
      expect(previous.close).toHaveBeenCalled();
      expect(terminal().dispose).toHaveBeenCalled();
      fireEvent.mouseDown(exec, { button: 0, ctrlKey: false });
      await waitFor(() => expect(mocks.vmExec).toHaveBeenCalledTimes(i + 2));
      await connected();
    }
  });
  it("hides the entry point when vm:exec is denied", () => {
    mocks.allowed = false;
    render(<VMDetailPage id="vm-1" />);
    expect(screen.queryByRole("tab", { name: "Exec" })).toBeNull();
    expect(mocks.vmExec).not.toHaveBeenCalled();
  });
  it.each([
    ["Stopped", true, "VM is not running"],
    ["Running", false, "Strato guest agent channel is disabled"],
  ])("explains %s / enabled=%s without minting", (status, enabled, text) => {
    mocks.vm.status = status; mocks.vm.guestAgentEnabled = enabled;
    render(<VMDetailPage id="vm-1" />);
    fireEvent.mouseDown(screen.getByRole("tab", { name: "Exec" }), { button: 0, ctrlKey: false });
    expect(screen.getByRole("status")).toHaveTextContent(text);
    expect(mocks.vmExec).not.toHaveBeenCalled();
  });
  it.each([
    ["VM vm-1 has no guest agent", "Install and start"],
    ["guest agent not responding for VM vm-1: timeout", "Check the Strato guest agent service"],
  ])("renders actionable frame failure %s and allows retry", async (message, remedy) => {
    render(<GuestTerminal resourceId="vm-1" resourceKind="vm" />);
    await waitFor(() => expect(Socket.instances).toHaveLength(1));
    socket().frame({ type: "error", message });
    expect(screen.getByRole("alert")).toHaveTextContent(remedy);
    expect(socket().close).toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: "Run" }));
    await waitFor(() => expect(mocks.vmExec).toHaveBeenCalledTimes(2));
    await connected();
  });
  it("relays binary input, output and resize only after ready; retries disconnect with a new POST", async () => {
    render(<GuestTerminal resourceId="vm-1" resourceKind="vm" />);
    await waitFor(() => expect(Socket.instances).toHaveLength(1));
    terminal().data?.("before"); expect(socket().send).not.toHaveBeenCalled();
    await connected();
    terminal().data?.("echo hi\r"); terminal().resize?.({ cols: 100, rows: 30 });
    expect(socket().send.mock.calls[0][0]).toEqual(new TextEncoder().encode("echo hi\r"));
    expect(socket().send).toHaveBeenCalledWith(JSON.stringify({ type: "resize", cols: 100, rows: 30 }));
    const output = new Uint8Array([104, 105]); socket().frame(output.buffer);
    expect(terminal().write).toHaveBeenCalledWith(output);
    act(() => socket().onclose?.({ reason: "network interrupted" }));
    expect(screen.getByText("Disconnected")).toBeVisible();
    expect(mocks.vmExec).toHaveBeenCalledTimes(1);
    fireEvent.click(screen.getByRole("button", { name: "Run" }));
    await waitFor(() => expect(mocks.vmExec).toHaveBeenCalledTimes(2));
    await connected();
    socket().frame({ type: "exit", exitCode: 7 });
    expect(screen.getByText("Exited (7)")).toBeVisible();
  });
  it.each([false, true])("ignores a late POST after navigation (reject=%s)", async (reject) => {
    let finish!: (value: typeof session | Error) => void;
    mocks.vmExec.mockImplementationOnce(() => new Promise((resolve, fail) => { finish = (value) => reject ? fail(value) : resolve(value); }));
    const view = render(<GuestTerminal resourceId="vm-1" resourceKind="vm" />);
    const oldTerm = terminal();
    view.unmount(); const writes = oldTerm.write.mock.calls.length;
    await act(async () => finish(reject ? new Error("late failure") : session));
    expect(Socket.instances).toHaveLength(0);
    expect(oldTerm.write).toHaveBeenCalledTimes(writes);
  });
  it("closes the old socket when navigating to a different resource", async () => {
    const view = render(<GuestTerminal resourceId="vm-1" resourceKind="vm" />);
    await connected(); const oldSocket = socket();
    view.rerender(<GuestTerminal resourceId="vm-2" resourceKind="vm" />);
    expect(oldSocket.close).toHaveBeenCalled();
    expect(oldSocket.onmessage).toBeNull();
    await waitFor(() => expect(mocks.vmExec).toHaveBeenLastCalledWith("vm-2", expect.anything()));
  });
  it("shows mint authorization failures and can retry without opening a socket", async () => {
    mocks.vmExec.mockRejectedValueOnce(new Error("You do not have permission to exec into this VM"));
    render(<GuestTerminal resourceId="vm-1" resourceKind="vm" />);
    await waitFor(() => expect(screen.getByRole("alert")).toHaveTextContent("permission"));
    expect(Socket.instances).toHaveLength(0);
    fireEvent.click(screen.getByRole("button", { name: "Run" }));
    await connected();
  });
  it("tears down a live terminal if permission is revoked or the VM stops", async () => {
    const view = render(<VMDetailPage id="vm-1" />);
    fireEvent.mouseDown(screen.getByRole("tab", { name: "Exec" }), { button: 0, ctrlKey: false });
    await connected(); const oldSocket = socket();
    mocks.vm.status = "Stopped";
    view.rerender(<VMDetailPage id="vm-1" />);
    expect(oldSocket.close).toHaveBeenCalled();
    expect(screen.getByRole("status")).toHaveTextContent("VM is not running");
    mocks.allowed = false;
    view.rerender(<VMDetailPage id="vm-1" />);
    expect(screen.queryByRole("tab", { name: "Exec" })).toBeNull();
  });
  it("keeps the sandbox route working", async () => {
    render(<SandboxTerminal sandboxId="sandbox-1" />);
    await connected();
    expect(mocks.sandboxExec).toHaveBeenCalledWith("sandbox-1", expect.anything());
    expect(mocks.vmExec).not.toHaveBeenCalled();
  });
});
