import { describe, expect, it } from "vitest";
import { logRefetchInterval } from "./use-resource-logs";

describe("logRefetchInterval", () => {
  it("stops network polling while the viewer is paused", () => {
    expect(logRefetchInterval(true)).toBe(5000);
    expect(logRefetchInterval(false)).toBe(false);
  });
});
