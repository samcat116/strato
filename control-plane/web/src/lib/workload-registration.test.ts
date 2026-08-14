import { describe, expect, it } from "vitest";
import type { WorkloadRegistration } from "@/lib/api/platform-services";
import { workloadRegistrationDeletionMessage } from "./workload-registration";

describe("workloadRegistrationDeletionMessage", () => {
  it("warns that a VM identity is permanently revoked and not recreated", () => {
    const registration: WorkloadRegistration = {
      id: "registration-1",
      spiffeId: "spiffe://example.test/vm/1",
      kind: "workload",
      vmId: "vm-1",
      displayName: "checkout-api",
    };

    const message = workloadRegistrationDeletionMessage(registration);

    expect(message).toContain("checkout-api");
    expect(message).toContain("vm-1");
    expect(message).toContain("permanently revokes");
    expect(message).toContain("will not be recreated");
  });

  it("identifies non-VM registrations by SPIFFE ID and label", () => {
    const registration: WorkloadRegistration = {
      id: "registration-2",
      spiffeId: "spiffe://example.test/service/payments",
      kind: "service_account",
      displayName: "payments",
    };

    const message = workloadRegistrationDeletionMessage(registration);

    expect(message).toContain(registration.spiffeId);
    expect(message).toContain("payments");
    expect(message).toContain("cannot be undone");
  });
});
