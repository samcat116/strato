import { act, renderHook } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ApiError } from "@/lib/api/client";
import { useAcceptedMutation } from "./use-accepted-mutation";

const mocks = vi.hoisted(() => ({
  watch: vi.fn(),
  acceptedMutation: vi.fn((accepted) => accepted),
}));

vi.mock("@/lib/stores/mutations-store", () => ({
  acceptedMutation: mocks.acceptedMutation,
  acceptedSnapshotMutation: vi.fn((accepted) => accepted),
  useMutationsStore: (selector: (state: { watch: typeof mocks.watch }) => unknown) =>
    selector({ watch: mocks.watch }),
}));
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }));

describe("useAcceptedMutation idempotency", () => {
  beforeEach(() => {
    mocks.watch.mockReset();
    mocks.acceptedMutation.mockClear();
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("shares one key and request across two submit events in the same flight", async () => {
    const randomUUID = vi.fn().mockReturnValue("one-form-key");
    vi.stubGlobal("crypto", { randomUUID });
    let finish: ((value: {
      resource: { id: string };
      mutationId: string;
      targetGeneration: number;
    }) => void) | undefined;
    const request = vi.fn(
      () =>
        new Promise<{
          resource: { id: string };
          mutationId: string;
          targetGeneration: number;
        }>((resolve) => { finish = resolve; })
    );
    const { result } = renderHook(() => useAcceptedMutation());
    const options = {
      intentKey: "POST:/api/vms:db",
      request,
      watch: {
        kind: "create" as const,
        resourceKind: "virtual_machine" as const,
        resourceName: "db",
      },
      errorMessage: "Create failed",
    };

    let first: Promise<void> | undefined;
    let second: Promise<void> | undefined;
    act(() => {
      first = result.current.run(options);
      second = result.current.run(options);
    });

    expect(first).toBe(second);
    expect(request).toHaveBeenCalledOnce();
    expect(request).toHaveBeenCalledWith("one-form-key");
    expect(randomUUID).toHaveBeenCalledOnce();

    await act(async () => {
      finish?.({
        resource: { id: "vm-id" },
        mutationId: "mutation-id",
        targetGeneration: 1,
      });
      await first;
    });
    expect(mocks.watch).toHaveBeenCalledOnce();
  });

  it("keeps the key when a transport failure leaves the outcome ambiguous", async () => {
    const randomUUID = vi.fn().mockReturnValue("ambiguous-key");
    vi.stubGlobal("crypto", { randomUUID });
    const accepted = {
      resource: { id: "vm-id" },
      mutationId: "mutation-id",
      targetGeneration: 1,
    };
    const request = vi.fn()
      .mockRejectedValueOnce(new TypeError("Failed to fetch"))
      .mockResolvedValueOnce(accepted);
    const { result } = renderHook(() => useAcceptedMutation());
    const options = {
      intentKey: "POST:/api/vms:db",
      request,
      watch: {
        kind: "create" as const,
        resourceKind: "virtual_machine" as const,
        resourceName: "db",
      },
      errorMessage: "Create failed",
    };

    await act(async () => { await result.current.run(options); });
    await act(async () => { await result.current.run(options); });

    expect(request).toHaveBeenNthCalledWith(1, "ambiguous-key");
    expect(request).toHaveBeenNthCalledWith(2, "ambiguous-key");
    expect(randomUUID).toHaveBeenCalledOnce();
    expect(mocks.watch).toHaveBeenCalledOnce();
  });

  it("keeps the key when a server error leaves the outcome ambiguous", async () => {
    const randomUUID = vi.fn().mockReturnValue("server-error-key");
    vi.stubGlobal("crypto", { randomUUID });
    const accepted = {
      resource: { id: "vm-id" },
      mutationId: "mutation-id",
      targetGeneration: 1,
    };
    const request = vi.fn()
      .mockRejectedValueOnce(new ApiError(503, "Service unavailable"))
      .mockResolvedValueOnce(accepted);
    const { result } = renderHook(() => useAcceptedMutation());
    const options = {
      intentKey: "POST:/api/vms:db",
      request,
      watch: {
        kind: "create" as const,
        resourceKind: "virtual_machine" as const,
        resourceName: "db",
      },
      errorMessage: "Create failed",
    };

    await act(async () => { await result.current.run(options); });
    await act(async () => { await result.current.run(options); });

    expect(request).toHaveBeenNthCalledWith(1, "server-error-key");
    expect(request).toHaveBeenNthCalledWith(2, "server-error-key");
    expect(randomUUID).toHaveBeenCalledOnce();
  });

  it("generates a key without randomUUID on plaintext deployments", async () => {
    const randomUUID = vi.fn(() => {
      throw new DOMException("A secure context is required", "SecurityError");
    });
    const getRandomValues = vi.fn((bytes: Uint8Array) => {
      bytes.set(Array.from({ length: 16 }, (_, index) => index));
      return bytes;
    });
    vi.stubGlobal("crypto", { randomUUID, getRandomValues });
    const request = vi.fn().mockResolvedValue({
      resource: { id: "vm-id" },
      mutationId: "mutation-id",
      targetGeneration: 1,
    });
    const { result } = renderHook(() => useAcceptedMutation());

    await act(async () => {
      await result.current.run({
        intentKey: "POST:/api/vms:db",
        request,
        watch: {
          kind: "create",
          resourceKind: "virtual_machine",
          resourceName: "db",
        },
        errorMessage: "Create failed",
      });
    });

    expect(request).toHaveBeenCalledWith("00010203-0405-4607-8809-0a0b0c0d0e0f");
    expect(randomUUID).toHaveBeenCalledOnce();
    expect(getRandomValues).toHaveBeenCalledOnce();
  });

  it("rotates the key after a definitive response or an intent change", async () => {
    const randomUUID = vi.fn()
      .mockReturnValueOnce("first-key")
      .mockReturnValueOnce("second-key")
      .mockReturnValueOnce("third-key");
    vi.stubGlobal("crypto", { randomUUID });
    const accepted = {
      resource: { id: "vm-id" },
      mutationId: "mutation-id",
      targetGeneration: 1,
    };
    const request = vi.fn()
      .mockRejectedValueOnce(new TypeError("Failed to fetch"))
      .mockRejectedValueOnce(new ApiError(422, "different request"))
      .mockResolvedValueOnce(accepted);
    const { result } = renderHook(() => useAcceptedMutation());
    const base = {
      request,
      watch: {
        kind: "create" as const,
        resourceKind: "virtual_machine" as const,
        resourceName: "db",
      },
      errorMessage: "Create failed",
    };

    await act(async () => {
      await result.current.run({ ...base, intentKey: "POST:/api/vms:db" });
    });
    await act(async () => {
      await result.current.run({ ...base, intentKey: "POST:/api/vms:db-2" });
    });
    await act(async () => {
      await result.current.run({ ...base, intentKey: "POST:/api/vms:db-2" });
    });

    expect(request).toHaveBeenNthCalledWith(1, "first-key");
    expect(request).toHaveBeenNthCalledWith(2, "second-key");
    expect(request).toHaveBeenNthCalledWith(3, "third-key");
  });
});
