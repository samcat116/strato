import { describe, expect, it } from "vitest";
import {
  auditResultsAreCurrent,
  canonicalVMFilter,
} from "@/components/audit/audit-event-model";

describe("audit VM filtering", () => {
  it("normalizes pasted UUIDs to the persisted canonical form", () => {
    expect(canonicalVMFilter(" 7c265a66-b4db-4eb1-82a7-91bf7fc30ae1 ")).toBe(
      "7C265A66-B4DB-4EB1-82A7-91BF7FC30AE1"
    );
  });

  it("does not send partial or malformed UUIDs", () => {
    expect(canonicalVMFilter("7c265a66-b4db")).toBeUndefined();
    expect(canonicalVMFilter("not-a-vm")).toBeUndefined();
  });

  it("never presents cached rows under a new filter or page", () => {
    expect(auditResultsAreCurrent(false, false)).toBe(true);
    expect(auditResultsAreCurrent(true, false)).toBe(false);
    expect(auditResultsAreCurrent(false, true)).toBe(false);
  });
});
