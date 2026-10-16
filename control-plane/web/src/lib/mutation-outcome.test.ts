import { describe, expect, it } from "vitest";
import { mutationOutcome } from "./mutation-outcome";
import type { ResourceConditions } from "@/types/api";

const conditions = (overrides: Partial<ResourceConditions> = {}): ResourceConditions => ({
  targetGeneration: 3,
  observedGeneration: 0,
  converged: false,
  ...overrides,
});
const failure = (sinceGeneration: number) => ({ sinceGeneration, reason: "placement failed" });

describe("accepted mutation verdict", () => {
  it("settles an unobserved retry when metadata advanced before failure", () => {
    expect(mutationOutcome(conditions({ degraded: failure(3) }), 2))
      .toEqual({ done: true, error: "placement failed" });
  });
  it("preserves an older success when a later mutation fails", () => {
    expect(mutationOutcome(conditions({ observedGeneration: 2, degraded: failure(3) }), 2))
      .toEqual({ done: true });
  });
  it("does not apply historical failure to a newer target", () => {
    expect(mutationOutcome(conditions({ degraded: failure(1) }), 3)).toEqual({ done: false });
  });
  it("keeps an unobserved target pending before any failure", () => {
    expect(mutationOutcome(conditions(), 2)).toEqual({ done: false });
  });
  it("retains exact-generation failure precedence", () => {
    expect(mutationOutcome(conditions({ observedGeneration: 3, degraded: failure(3) }), 3))
      .toEqual({ done: true, error: "placement failed" });
  });
  it("settles convergence and observed supersession", () => {
    expect(mutationOutcome(conditions({ observedGeneration: 3, converged: true }), 3))
      .toEqual({ done: true });
    expect(mutationOutcome(conditions({ observedGeneration: 2 }), 2)).toEqual({ done: true });
  });
});
