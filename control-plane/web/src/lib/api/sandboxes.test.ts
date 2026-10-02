import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { api } from "./client";
import { sandboxesApi } from "./sandboxes";

vi.mock("./client", () => ({ api: { get: vi.fn(), post: vi.fn() } }));
const get = vi.mocked(api.get);
const post = vi.mocked(api.post);

describe("sandbox exec wake", () => {
  beforeEach(() => { vi.useFakeTimers(); get.mockReset(); post.mockReset(); });
  afterEach(() => vi.useRealTimers());

  it("waits for confirmed restore before requesting a session", async () => {
    post.mockResolvedValueOnce({ targetGeneration: 4 }).mockResolvedValueOnce({ websocketPath: "/attach" });
    get.mockResolvedValueOnce({ status: "Suspended", conditions: { targetGeneration: 4, converged: false } })
      .mockResolvedValueOnce({ status: "Running", conditions: { targetGeneration: 4, converged: true } });
    const result = sandboxesApi.exec("sandbox", { command: ["true"] });
    await vi.advanceTimersByTimeAsync(100);
    expect(post).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(100);
    await expect(result).resolves.toEqual({ websocketPath: "/attach" });
    expect(post).toHaveBeenCalledTimes(2);
  });

  it("does not start the command when a different generation supersedes wake", async () => {
    post.mockResolvedValueOnce({ targetGeneration: 4 });
    get.mockResolvedValueOnce({ status: "Running", conditions: { targetGeneration: 5, converged: true } });
    const result = expect(sandboxesApi.exec("sandbox", { command: ["true"] })).rejects.toThrow("superseded");
    await vi.advanceTimersByTimeAsync(100);
    await result;
    expect(post).toHaveBeenCalledTimes(1);
  });

  it("bounds a pending restore without claiming exec success", async () => {
    post.mockResolvedValueOnce({ targetGeneration: 4 });
    get.mockResolvedValue({ status: "Suspended", conditions: { targetGeneration: 4, converged: false } });
    const result = expect(sandboxesApi.exec("sandbox", { command: ["true"] })).rejects.toThrow("still pending");
    await vi.advanceTimersByTimeAsync(30_000);
    await result;
    expect(post).toHaveBeenCalledTimes(1);
  });
});
