import { act, cleanup, renderHook } from "@testing-library/react";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import type { Terminal } from "@xterm/xterm";
import { useConsole } from "./use-console";

class Socket {
  static OPEN = 1;
  static instances: Socket[] = [];
  readyState = 1;
  binaryType = "";
  onmessage: ((event: { data: unknown }) => void) | null = null;
  onclose: ((event: { reason: string }) => void) | null = null;
  onopen: (() => void) | null = null;
  onerror: (() => void) | null = null;
  send = vi.fn();
  close = vi.fn();
  constructor(public url: string) { Socket.instances.push(this); }
}
function terminal() {
  let input: ((text: string) => void) | undefined;
  const decoder = new TextDecoder();
  let output = "";
  const value = { write: vi.fn((chunk: string | Uint8Array) => {
    output += typeof chunk === "string" ? chunk : decoder.decode(chunk, { stream: true });
  }), onData: (fn: (text: string) => void) => {
    input = fn; return { dispose: vi.fn() };
  } };
  return { value: value as unknown as Terminal, write: value.write,
    output: () => output, type: (text: string) => input?.(text) };
}
beforeEach(() => { Socket.instances = []; vi.stubGlobal("WebSocket", Socket); });
afterEach(() => { cleanup(); vi.unstubAllGlobals(); });

it("split UTF-8 survives serial WebSocket frames", () => {
  const { result } = renderHook(() => useConsole({ vmId: "a" }));
  const term = terminal();
  act(() => result.current.connect(term.value));
  const ws = Socket.instances[0];
  const first = new ArrayBuffer(1);
  const second = new ArrayBuffer(2);
  new Uint8Array(first).set([0xe2]);
  new Uint8Array(second).set([0x82, 0xac]);
  act(() => {
    ws.onmessage?.({ data: first });
    ws.onmessage?.({ data: second });
  });
  expect(term.output()).toBe("€");
});

it("an old close cannot disable a replacement console", () => {
  const { result } = renderHook(() => useConsole({ vmId: "a" }));
  act(() => result.current.connect(terminal().value));
  const old = Socket.instances[0];
  const staleClose = old.onclose;
  act(() => result.current.disconnect());
  const nextTerm = terminal();
  act(() => result.current.connect(nextTerm.value));
  const current = Socket.instances[1];
  act(() => current.onmessage?.({ data: "ready" }));
  act(() => staleClose?.({ reason: "old connection closed" }));
  act(() => nextTerm.type("x"));
  expect(result.current.isConnected).toBe(true);
  expect(current.send).toHaveBeenCalledOnce();
});
