import { describe, expect, it } from "vitest";
import { guestAgentReachability } from "./vm-guest-agent-card";
import type { VM } from "@/types/api";

const now = Date.parse("2026-10-02T12:00:00Z");
const vm = { guestAgentEnabled: true, status: "Running" } as VM;
describe("Strato guest agent status", () => {
  it("does not infer reachability from opt-in or QGA", () => {
    expect(guestAgentReachability({ ...vm, qgaAvailable: true }, now)).toBe("Unknown");
    expect(guestAgentReachability({ ...vm, guestAgentEnabled: false }, now)).toBe("Not enabled");
    expect(guestAgentReachability({ ...vm, status: "Shutdown" }, now)).toBe("Not running");
  });
  it("expires probe observations and rejects invalid timestamps", () => {
    for (const checkedAt of ["2026-10-02T11:58:30Z", "invalid", "2026-10-02T12:00:10Z"]) {
      expect(guestAgentReachability({ ...vm, guestAgentObservation: { reachable: true, checkedAt } }, now)).toBe("Unknown");
    }
  });
  it("shows positive and negative recent observations separately", () => {
    for (const reachable of [false, true]) {
      expect(guestAgentReachability({ ...vm, guestAgentObservation: { reachable, checkedAt: "2026-10-02T11:59:59Z" } }, now))
        .toBe(reachable ? "Reachable" : "Unreachable");
    }
  });
});
