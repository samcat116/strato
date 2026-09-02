import { describe, expect, it } from "vitest";
import { ApiError } from "@/lib/api/client";
import { errorMessage } from "@/lib/errors";

describe("errorMessage", () => {
  it("uses a caller-specific forbidden message", () => {
    expect(
      errorMessage(new ApiError(403, "Forbidden"), "Failed", {
        forbidden: "Administrator access is required.",
      })
    ).toBe("Administrator access is required.");
  });

  it("keeps useful error and string messages", () => {
    expect(errorMessage(new Error("Details"), "Failed")).toBe("Details");
    expect(errorMessage("Details", "Failed")).toBe("Details");
  });

  it("maps known backend errors and falls back for unknown values", () => {
    expect(errorMessage(new Error("Agent not found: agent-1"), "Failed")).toBe(
      "The hypervisor host for this VM is no longer registered."
    );
    expect(errorMessage(null, "Failed")).toBe("Failed");
  });
});
