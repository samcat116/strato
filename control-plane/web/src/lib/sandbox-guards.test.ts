import { describe, expect, it } from "vitest";
import type { Sandbox, SandboxStatus } from "@/types/api";
import { sandboxCanBeSnapshotted } from "./sandbox-guards";

type SnapshotAdmissionSandbox = Pick<
  Sandbox,
  "status" | "hypervisorId" | "conditions"
>;

function sandbox(
  status: SandboxStatus,
  hypervisorId: string | undefined,
  observedGeneration: number
): SnapshotAdmissionSandbox {
  return {
    status,
    hypervisorId,
    conditions: {
      converged: observedGeneration > 0,
      targetGeneration: 1,
      observedGeneration,
    },
  };
}

describe("sandboxCanBeSnapshotted", () => {
  it("rejects a newly created cold sandbox before placement and confirmation", () => {
    expect(sandboxCanBeSnapshotted(sandbox("Stopped", undefined, 0))).toBe(false);
  });

  it("requires both placement and an observed generation", () => {
    expect(sandboxCanBeSnapshotted(sandbox("Stopped", "agent-1", 0))).toBe(
      false
    );
    expect(sandboxCanBeSnapshotted(sandbox("Stopped", undefined, 1))).toBe(false);
  });

  it.each(["Running", "Stopped", "Exited"] satisfies SandboxStatus[])(
    "accepts a placed and confirmed sandbox in %s",
    (status) => {
      expect(
        sandboxCanBeSnapshotted(sandbox(status, "agent-1", 1))
      ).toBe(true);
    }
  );

  it.each(["Starting", "Stopping", "Error", "Unknown"] satisfies SandboxStatus[])(
    "rejects the transitional or uncertain %s state",
    (status) => {
      expect(
        sandboxCanBeSnapshotted(sandbox(status, "agent-1", 1))
      ).toBe(false);
    }
  );
});
