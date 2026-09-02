import { afterEach, describe, expect, it, vi } from "vitest";
import { formatDuration, formatRelative } from "@/lib/format-time";

describe("time formatting", () => {
  afterEach(() => vi.useRealTimers());

  it("formats compact durations", () => {
    expect(formatDuration(0)).toBe("0s");
    expect(formatDuration(90)).toBe("1m 30s");
    expect(formatDuration(5_400)).toBe("1h 30m");
    expect(formatDuration(93_600)).toBe("1d 2h");
  });

  it("formats past and future timestamps relative to now", () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-09-01T12:00:00Z"));
    expect(formatRelative("2026-09-01T11:56:00Z")).toBe("4m ago");
    expect(formatRelative("2026-09-01T14:00:00Z")).toBe("in 2h");
  });
});
